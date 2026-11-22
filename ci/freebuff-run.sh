#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# ci/freebuff-run.sh — run one Freebuff task headlessly
#
#   ci/freebuff-run.sh <project_dir> <prompt_file> <result_file>
#
# Freebuff (https://freebuff.com, the free ad-supported Codebuff agent) is the
# fallback while Claude is out of quota (lib/ai-provider.sh). It is a TUI with no
# print mode, so it is driven through tmux: start it in a detached session, paste
# the prompt, press Enter, and watch the pane for the states that need a key
# press. Completion is the agent writing <result_file> (absolute, OUTSIDE the
# repo) whose last line is FREEBUFF-DONE.
#
# Exit: 0 = done (result file complete), 1 = ran but did not finish and the tree
# changed, 4 = Freebuff unavailable (not installed, not logged in, allowance used
# up, servers unreachable, or no result and no change). The reason for a 4 is
# the last line of <result_file>.reason. Only short progress lines go to stdout;
# the full pane goes to $FREEBUFF_PANE_LOG (default <result_file>.pane), which is
# a withheld log: it contains the app's code.
#
# Knobs: FREEBUFF_TIMEOUT_MIN (60), FREEBUFF_TIMEOUT_SEC (overrides the former),
# FREEBUFF_MAX_CONTINUES (6), FREEBUFF_POLL_SEC (10), FREEBUFF_READY_MAX_SEC (120),
# FREEBUFF_UNREACHABLE_MAX_SEC (300), AUTOFIX_FREEBUFF_BIN (freebuff).
###############################################################################

PROJECT="${1:?usage: freebuff-run.sh <project_dir> <prompt_file> <result_file>}"
PROMPT_FILE="${2:?prompt file required}"
RESULT="${3:?result file required}"
TIMEOUT_SEC="${FREEBUFF_TIMEOUT_SEC:-$(( ${FREEBUFF_TIMEOUT_MIN:-60} * 60 ))}"
MAX_CONTINUES="${FREEBUFF_MAX_CONTINUES:-6}"
POLL="${FREEBUFF_POLL_SEC:-10}"
READY_MAX="${FREEBUFF_READY_MAX_SEC:-120}"
UNREACHABLE_MAX="${FREEBUFF_UNREACHABLE_MAX_SEC:-300}"
FB_BIN="${AUTOFIX_FREEBUFF_BIN:-freebuff}"
PANE_LOG="${FREEBUFF_PANE_LOG:-$RESULT.pane}"
SENTINEL="FREEBUFF-DONE"

say() { echo "[freebuff-run] $*"; }
unavailable() { echo "$*" >> "$RESULT.reason"; say "unavailable: $*"; exit 4; }

case "$RESULT" in /*) ;; *) unavailable "result file must be an absolute path" ;; esac
PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd -P)" || unavailable "no project dir"
case "$(cd "$(dirname "$RESULT")" && pwd -P)/" in
    "$PROJECT"/*) unavailable "result file must be outside the repo (it would be committed)" ;;
esac
rm -f "$RESULT" "$RESULT.reason"

# ── A scrubbed environment ───────────────────────────────────────────────────
# The app's code goes to a third-party, ad-funded service. The agent gets no
# credential but its own: no GitHub/Bitbucket access, no Claude key, no signing
# keys, no mail password, no SSH agent. Done in this process, because a tmux
# session inherits the tmux SERVER's environment — hence the private server
# (-L) below, started from this scrubbed one. Repo .agents files and mcp.json
# are untrusted input: never --trust-agents, and the env switch for it is dropped.
unset GH_TOKEN GITHUB_TOKEN APP_REPO_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN \
      CLAUDE_CODE_OAUTH_TOKEN SSH_AUTH_SOCK CODEBUFF_TRUST_AGENT_DIRS CODEBUFF_GITHUB_TOKEN TMUX
for v in $(compgen -e); do
    case "$v" in
        CODEBUFF_API_KEY) ;;
        BITBUCKET_*|*_KEYSTORE_*|AUTOFIX_MAIL_*|ACTIONS_*|*_TOKEN|*_SECRET|*_PASSWORD|*_PASS) unset "$v" ;;
    esac
done

command -v tmux >/dev/null 2>&1 || unavailable "tmux not installed"
command -v "$FB_BIN" >/dev/null 2>&1 || unavailable "freebuff not installed"
if [[ -n "${FREEBUFF_CONFIG_DIR:-}" && "$FREEBUFF_CONFIG_DIR" != /* ]]; then
    unavailable "FREEBUFF_CONFIG_DIR must be absolute"
fi
if [[ -z "${CODEBUFF_API_KEY:-}" && ! -s "${FREEBUFF_CONFIG_DIR:-$HOME/.config/manicode}/credentials.json" ]]; then
    unavailable "not logged in (no credentials.json and no CODEBUFF_API_KEY)"
fi

# ── tmux ─────────────────────────────────────────────────────────────────────
SOCK="autofix-fb-$$-$RANDOM"
T=(tmux -L "$SOCK" -f /dev/null)
S="fb"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fbrun.XXXXXX"); chmod 700 "$WORK"
finish() {
    "${T[@]}" capture-pane -p -J -t "$S" -S -5000 > "$PANE_LOG" 2>/dev/null || true
    "${T[@]}" kill-server >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap finish EXIT

head_start=$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null || echo "")
tree_changed() {
    [[ "$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null || echo "")" != "$head_start" ]] && return 0
    [[ -n "$(git -C "$PROJECT" status --porcelain -- . ':(exclude).autofix-logs' 2>/dev/null)" ]]
}
pane()      { "${T[@]}" capture-pane -p -J -t "$S" 2>/dev/null; }
pane_all()  { "${T[@]}" capture-pane -p -J -t "$S" -S -5000 2>/dev/null; }
count()     { pane_all | grep -cF -- "$1"; }
send_line() { "${T[@]}" send-keys -t "$S" -l "$1"; sleep 1; "${T[@]}" send-keys -t "$S" Enter; }
done_ok()   { [[ -f "$RESULT" ]] && [[ "$(grep -v '^[[:space:]]*$' "$RESULT" | tail -1 | tr -d '[:space:]')" == "$SENTINEL" ]]; }

# Strings from the freebuff 0.2.x TUI.
LOGIN_RE='Press ENTER to login|Open this URL (in your browser )?to log ?in|Not logged in'
ALLOWANCE_RE="doesn't cover an hour of|less than an hour left|daily allowance|[Oo]ut of hours"
UNREACHABLE_RE="Can't reach (Freebuff|Codebuff)"
READY_TXT='enter a coding task or / for commands'

# The wrapper keeps the pane alive after freebuff exits, so its last screen is
# still there to capture and the exit is detectable.
printf -v cmd '%q; echo "[freebuff exited rc=$?]"; sleep 86400' "$FB_BIN"
"${T[@]}" new-session -d -s "$S" -x 220 -y 60 -c "$PROJECT" "$cmd" \
    || unavailable "could not start tmux"
say "started (session $SOCK)"

# ── Wait for the input prompt ────────────────────────────────────────────────
waited=0 t0=$SECONDS
while :; do
    [[ $waited -ge $READY_MAX ]] && unavailable "freebuff did not show its prompt within ${READY_MAX}s"
    [[ $((SECONDS - t0)) -ge $TIMEOUT_SEC ]] && unavailable "still waiting in line after ${TIMEOUT_SEC}s"
    p=$(pane)
    # Waiting in line for capacity is not a failure; only the overall timeout ends it.
    echo "$p" | grep -qF 'in line' || waited=$((waited + 1))
    if echo "$p" | grep -qE "$LOGIN_RE";     then unavailable "not logged in (login screen shown)"; fi
    if echo "$p" | grep -qE "$ALLOWANCE_RE"; then unavailable "free allowance used up"; fi
    if echo "$p" | grep -qF '[freebuff exited'; then unavailable "freebuff exited at startup"; fi
    if echo "$p" | grep -qF 'Load and run these? [y/N]'; then send_line n; sleep 2; continue; fi
    if echo "$p" | grep -qF 'Take over'; then "${T[@]}" send-keys -t "$S" Enter; sleep 3; continue; fi
    echo "$p" | grep -qF "$READY_TXT" && break
    sleep 1
done
say "ready after ${waited}s"

# ── Send the task ────────────────────────────────────────────────────────────
{
    cat "$PROMPT_FILE"
    cat <<EOF

---
Rules for this session from the autofix runner (they override anything above that conflicts):
- Work only inside this repository ($PROJECT). Do not push, tag or release, do not change git remotes, and do not use \`gh\` or the GitHub API.
- Leave your changes committed or uncommitted exactly as the task above says.
- When you have finished (or have to stop), write a short summary to this file, which is outside the repository:
RESULT_FILE: $RESULT
  Copy into it, verbatim, every marker line the task asks you to print (ALREADY_FIXED:, BUILD_ENV_BROKEN:, the FIX_SUMMARY_START ... FIX_SUMMARY_END block).
  Its very last line must be exactly $SENTINEL
- Write that file only once you are done, and nowhere else.
EOF
} > "$WORK/prompt"
"${T[@]}" load-buffer -b task "$WORK/prompt"
"${T[@]}" paste-buffer -p -d -b task -t "$S"
sleep 3
"${T[@]}" send-keys -t "$S" Enter
sleep 3

# Counted over the whole history, so a notice is acted on once per new
# appearance — and text that arrived with the pasted prompt is the baseline,
# not an event.
n_ended=$(count 'free session ended'); n_takeover=$(count 'Take over'); n_released=$(count 'was released')
continues=0 unreach_since=0 start=$SECONDS
CONTINUE_MSG="Continue the same task from where you stopped. Check git status first and do not redo finished work. When done, write $RESULT as instructed, with the last line exactly $SENTINEL"

while :; do
    if done_ok; then say "done in $(( (SECONDS - start) / 60 )) min"; exit 0; fi
    p=$(pane)
    if echo "$p" | grep -qF '[freebuff exited'; then
        say "freebuff exited before finishing"; break
    fi
    # Hard failures are only read from the bottom of the screen (status and input
    # area), not from the chat, where the issue text itself is shown.
    bottom=$(echo "$p" | grep -v '^[[:space:]]*$' | tail -12)
    if echo "$bottom" | grep -qE "$LOGIN_RE";     then unavailable "logged out during the run"; fi
    if echo "$bottom" | grep -qE "$ALLOWANCE_RE"; then unavailable "free allowance used up"; fi
    if echo "$bottom" | grep -qE "$UNREACHABLE_RE"; then
        [[ $unreach_since -eq 0 ]] && unreach_since=$SECONDS
        [[ $((SECONDS - unreach_since)) -ge $UNREACHABLE_MAX ]] && unavailable "can't reach Freebuff's servers for ${UNREACHABLE_MAX}s"
    else
        unreach_since=0
    fi
    c=$(count 'free session ended')
    if [[ $c -gt $n_ended ]]; then
        n_ended=$c
        if [[ $continues -ge $MAX_CONTINUES ]]; then say "free session ended $c times; giving up"; break; fi
        continues=$((continues + 1)); say "free session ended; continue #$continues"
        send_line "$CONTINUE_MSG"; sleep 5
    fi
    c=$(count 'Take over');    [[ $c -gt $n_takeover ]] && { n_takeover=$c; say "take over"; "${T[@]}" send-keys -t "$S" Enter; sleep 3; }
    c=$(count 'was released'); [[ $c -gt $n_released ]] && { n_released=$c; say "session released"; "${T[@]}" send-keys -t "$S" Enter; sleep 3; }
    if [[ $((SECONDS - start)) -ge $TIMEOUT_SEC ]]; then say "timed out after ${TIMEOUT_SEC}s"; break; fi
    sleep "$POLL"
done

# Did not finish. A changed tree means the agent worked and failed (a normal
# failed attempt); an untouched one means it never got going (no AI available).
if tree_changed; then exit 1; fi
unavailable "no result and no change in the repo (timed out or stopped)"
