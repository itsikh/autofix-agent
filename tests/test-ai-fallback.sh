#!/usr/bin/env bash
# Offline test for lib/ai-provider.sh and ci/freebuff-run.sh: limit detection,
# reset parsing, the Claude -> Freebuff switch and back, and the scrubbed
# environment Freebuff runs in. Fake `claude`, a fake freebuff-run and a fake
# freebuff TUI (driven through real tmux), a temp git repo and a fixed clock
# (AUTOFIX_NOW). No network, no real agent.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAKE="$T/fake"; mkdir -p "$FAKE"
export TZ=UTC
fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null; then pass "$name"; else fail "$name"; fi; }
epoch() { date -u -d "$1" +%s; }
nott() { ! "$@"; }

export AUTOFIX_STATE_DIR="$T/state" AUTOFIX_NOW="$(epoch 2026-11-22T20:00:00Z)"
export AUTOFIX_CLAUDE_BIN="$FAKE/claude" AUTOFIX_FREEBUFF_RUN="$FAKE/freebuff-run"
APP_SLUG="testapp"
RUNLOG="$T/run.log"
log() { echo "[$(date "+%Y-%m-%d %H:%M:%S")] [$APP_SLUG] $*" >> "$RUNLOG"; }
# shellcheck source=../lib/ai-provider.sh
source "$ROOT/lib/ai-provider.sh"

# ── claude_limit_reason ──────────────────────────────────────────────────────
for msg in "You've hit your weekly limit · resets 5pm (UTC)" \
           "You've hit your session limit · resets 3:45am (UTC)" \
           "Claude AI usage limit reached|1795453200" \
           "Credit balance is too low" \
           'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"Number of requests has exceeded your rate limit"}}' \
           'API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}' \
           "Weekly limit reached ∙ resets Nov 23, 5pm (America/New_York)"; do
    check "limit detected: ${msg:0:50}" claude_limit_reason "some output
$msg"
done
r=$(claude_limit_reason "API Error: 429 {\"type\":\"rate_limit_error\"}")
check "429 reason is the notice, not the JSON type" test "${r:0:14}" = "API Error: 429"
for msg in "Added a rate limit to the login screen (limit: 5/min); tests pass." \
           "Fixed the session limit check so the counter resets at midnight." \
           "FIX_SUMMARY_START
The daily limit reached state no longer crashes the widget.
FIX_SUMMARY_END"; do
    check "normal output not a limit: $(echo "${msg:0:40}" | head -1)" nott claude_limit_reason "$msg"
done
long="You've hit your weekly limit · resets 5pm (UTC)
$(head -c 4000 /dev/zero | tr '\0' 'x')
done"
check "limit text outside the last 3000 bytes is ignored" nott claude_limit_reason "$long"

# ── parse_reset_time (now = 2026-11-22 20:00Z) ───────────────────────────────
pr() { local want="$1" text="$2"; local got; got=$(parse_reset_time "$text")
       if [[ "$got" == "$want" ]]; then pass "reset '$text' -> $got"; else fail "reset '$text' -> $got (want $want)"; fi; }
pr 2026-11-23T17:01Z "You've hit your weekly limit · resets 5pm (UTC)"   # 5pm already passed today -> tomorrow
pr 2026-11-22T21:01Z "You've hit your session limit · resets 9pm (UTC)"  # later today
pr 2026-11-23T03:46Z "You've hit your session limit · resets 3:45am (UTC)"
pr 2026-11-23T22:01Z "You've hit your weekly limit · resets Nov 23, 5pm (America/New_York)"
pr 2026-11-23T01:01Z "You've hit your session limit · resets 8pm (America/New_York)"  # 20:00 NY = 01:00Z
pr 2026-11-23T17:01Z "Claude AI usage limit reached|$(epoch 2026-11-23T17:00:00Z)"
pr 2026-11-22T20:31Z "rate_limit_error: please try again in 30 minutes"
pr 2026-11-22T22:01Z "overloaded, try again in 2 hours"
pr 2026-11-22T21:00Z "Credit balance is too low"                           # unparseable -> now + 1h
pr 2026-11-22T21:00Z "Claude AI usage limit reached|1700000000"            # epoch in the past -> now + 1h
AUTOFIX_NOW=$(epoch 2026-12-31T23:30:00Z) pr 2027-01-01T00:16Z "resets 12:15am (UTC)"  # day + year rollover
AUTOFIX_NOW=$(epoch 2026-12-31T23:30:00Z) pr 2027-01-02T17:01Z "resets Jan 2, 5pm (UTC)"

# ── Fakes for run_fix_agent ──────────────────────────────────────────────────
# claude: mode from $FAKE/claude-mode. Counts calls. "limit" first edits and
# commits (so the test can see the tree reset), then prints a limit notice.
cat > "$FAKE/claude" <<'EOF'
#!/usr/bin/env bash
echo x >> "$(dirname "$0")/claude-calls"
case "$(cat "$(dirname "$0")/claude-mode")" in
  limit) echo partial > claude-partial.txt; git add -A; git -c user.email=t@t -c user.name=t commit -qm partial
         echo "You've hit your weekly limit · resets 5pm (UTC)"; exit 1 ;;
  ok)    echo fixed >> app.txt; echo "Done. FIX_SUMMARY_START fixed FIX_SUMMARY_END"; exit 0 ;;
  fail)  echo "something broke"; exit 1 ;;
esac
EOF
# freebuff-run: records the tree it started on and the env; result body and exit
# code from files.
cat > "$FAKE/freebuff-run" <<'EOF'
#!/usr/bin/env bash
F="$(dirname "$0")"; echo x >> "$F/fb-calls"
{ git -C "$1" rev-parse HEAD; git -C "$1" status --porcelain; } > "$F/fb-start-tree"
rc=$(cat "$F/fb-rc" 2>/dev/null || echo 0)
if [[ $rc == 4 ]]; then echo "free allowance used up" > "$3.reason"; exit 4; fi
echo fb >> "$1/app.txt"
{ cat "$F/fb-body" 2>/dev/null; echo FREEBUFF-DONE; } > "$3"
exit "$rc"
EOF
chmod +x "$FAKE/claude" "$FAKE/freebuff-run"
calls() { [[ -f "$FAKE/$1" ]] && wc -l < "$FAKE/$1" || echo 0; }

R="$T/repo"; git init -q "$R"; cd "$R" || exit 1
echo base > app.txt; git add -A; git -c user.email=t@t -c user.name=t commit -qm base
base=$(git rev-parse HEAD)
TL="$T/task.log" OUT="$T/out.txt"
reset_repo() { git reset -q --hard "$base"; git clean -qfd; }

# 1. First limit: state written, tree reset to the task's commit, Freebuff used.
echo limit > "$FAKE/claude-mode"; echo "FIX_SUMMARY_START
fb fixed it
FIX_SUMMARY_END" > "$FAKE/fb-body"
rc=0; run_fix_agent "the prompt" "$TL" "$OUT" arg >/dev/null || rc=$?
check "first limit: rc 0" test "$rc" = 0
check "first limit: agent is Freebuff" test "$AI_AGENT_USED" = Freebuff
check "first limit: blocked-until written" test "$(cat "$AUTOFIX_STATE_DIR/claude-blocked-until")" = 2026-11-23T17:01Z
check "first limit: Freebuff started on the task commit, clean tree" test "$(cat "$FAKE/fb-start-tree")" = "$base"
check "first limit: Claude's partial file gone" test ! -e claude-partial.txt
check "first limit: Freebuff result in out file" grep -q "fb fixed it" "$OUT"
check "first limit: result appended to task log (FIX_SUMMARY source)" grep -q "fb fixed it" "$TL"
check "first limit: switch logged" grep -q "AI-PROVIDER: Claude limit hit (You've hit your weekly limit · resets 5pm (UTC)); Claude blocked until 2026-11-23T17:01Z; using Freebuff" "$RUNLOG"
check "first limit: switch log written" grep -q "using Freebuff" "$AUTOFIX_STATE_DIR/provider-switch.log"
reset_repo

# 2. While blocked Claude is not invoked.
c_before=$(calls claude-calls); echo ok > "$FAKE/claude-mode"
AUTOFIX_NOW=$(epoch 2026-11-23T10:00:00Z)
rc=0; run_fix_agent "the prompt" "$TL" "$OUT" stdin >/dev/null || rc=$?
check "blocked: rc 0 via Freebuff" test "$rc/$AI_AGENT_USED" = 0/Freebuff
check "blocked: Claude not invoked" test "$(calls claude-calls)" = "$c_before"
check "blocked: logged" grep -q "AI-PROVIDER: Claude blocked until 2026-11-23T17:01Z; using Freebuff" "$RUNLOG"
check "blocked: claude_available is false" nott claude_available
reset_repo

# 3. Markers from the Freebuff result reach the out file.
echo "ALREADY_FIXED: fixed in v1.2" > "$FAKE/fb-body"
run_fix_agent "p" "$TL" "$OUT" arg >/dev/null; check "ALREADY_FIXED propagates from Freebuff" grep -q "^ALREADY_FIXED: fixed in v1.2" "$OUT"
echo "BUILD_ENV_BROKEN: no JDK" > "$FAKE/fb-body"
run_fix_agent "p" "$TL" "$OUT" arg >/dev/null; check "BUILD_ENV_BROKEN propagates from Freebuff" grep -q "^BUILD_ENV_BROKEN: no JDK" "$OUT"
: > "$FAKE/fb-body"; reset_repo

# 4. Fallback unavailable while blocked -> 4; fallback=none -> 4.
echo 4 > "$FAKE/fb-rc"
rc=0; run_fix_agent "p" "$TL" "$OUT" arg >/dev/null || rc=$?
check "blocked + Freebuff unavailable: rc 4" test "$rc" = 4
check "blocked + Freebuff unavailable: reason passed on" test "$AI_UNAVAILABLE_REASON" = "free allowance used up"
rm -f "$FAKE/fb-rc"
rc=0; AUTOFIX_FALLBACK=none run_fix_agent "p" "$TL" "$OUT" arg >/dev/null || rc=$?
check "blocked + AUTOFIX_FALLBACK=none: rc 4" test "$rc" = 4
check "fallback=none reason" test "$AI_UNAVAILABLE_REASON" = "fallback disabled (AUTOFIX_FALLBACK=none)"
f_before=$(calls fb-calls)
AUTOFIX_FALLBACK=none run_fix_agent "p" "$TL" "$OUT" arg
check "fallback=none: Freebuff not invoked" test "$(calls fb-calls)" = "$f_before"
reset_repo

# 5. After the reset Claude is tried again; success clears the state.
AUTOFIX_NOW=$(epoch 2026-11-23T17:05:00Z)
check "after reset: claude_available" claude_available
c_before=$(calls claude-calls); echo ok > "$FAKE/claude-mode"
rc=0; run_fix_agent "p" "$TL" "$OUT" arg >/dev/null || rc=$?
check "after reset: Claude ran" test "$rc/$AI_AGENT_USED/$(calls claude-calls)" = "0/Claude/$((c_before + 1))"
check "after reset: state cleared" test ! -e "$AUTOFIX_STATE_DIR/claude-blocked-until"
check "after reset: back to Claude logged" grep -q "AI-PROVIDER: Claude reset passed; back to Claude" "$RUNLOG"
reset_repo

# 6. Claude limited, fallback fails for quota -> 4 (state still recorded).
echo limit > "$FAKE/claude-mode"; echo 4 > "$FAKE/fb-rc"
rc=0; run_fix_agent "p" "$TL" "$OUT" arg >/dev/null || rc=$?
check "limit + fallback unavailable: rc 4" test "$rc" = 4
check "limit + fallback unavailable: state written" test -s "$AUTOFIX_STATE_DIR/claude-blocked-until"
rm -f "$FAKE/fb-rc" "$AUTOFIX_STATE_DIR/claude-blocked-until"; reset_repo

# 7. Claude limited, AUTOFIX_FALLBACK=none -> 4.
rc=0; AUTOFIX_FALLBACK=none run_fix_agent "p" "$TL" "$OUT" arg >/dev/null || rc=$?
check "limit + fallback=none: rc 4" test "$rc" = 4
rm -f "$AUTOFIX_STATE_DIR/claude-blocked-until"; reset_repo

# 8. A plain Claude failure is a failed attempt, not a switch.
echo fail > "$FAKE/claude-mode"; f_before=$(calls fb-calls)
rc=0; run_fix_agent "p" "$TL" "$OUT" arg >/dev/null || rc=$?
check "plain Claude failure: rc 1, no switch" test "$rc/$(calls fb-calls)" = "1/$f_before"
check "plain Claude failure: no state" test ! -e "$AUTOFIX_STATE_DIR/claude-blocked-until"
reset_repo

# 9. Status line format: AI-PROVIDER lines pass ci/status-lines.sh, unchanged.
lines=$(bash "$ROOT/ci/status-lines.sh" "$RUNLOG")
check "status lines include AI-PROVIDER" grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}\] \[testapp\] AI-PROVIDER: Claude limit hit \(.*\); Claude blocked until 2026-11-23T17:01Z; using Freebuff$' <<< "$lines"
check "status lines carry no prompt text" nott grep -q "the prompt" <<< "$lines"

# ── ci/freebuff-run.sh against a fake freebuff TUI in real tmux ──────────────
if ! command -v tmux >/dev/null; then
    fail "tmux not installed — freebuff-run.sh tests skipped"
else
FB="$T/fb"; mkdir -p "$FB/bin"
cat > "$FB/bin/freebuff" <<'EOF'
#!/usr/bin/env bash
env > "$FAKE_FB_DIR/env.txt"
mode=$(cat "$FAKE_FB_DIR/mode")
if [[ $mode == login ]]; then echo "Press ENTER to login..."; sleep 600; fi
echo "enter a coding task or / for commands"
res=""
while IFS= read -r line; do
  line=${line%$'\r'}
  case "$line" in *"RESULT_FILE: "*) res="${line##*RESULT_FILE: }" ;; esac
  [[ "$line" == *"nowhere else."* ]] && break
done
read -r _   # the Enter that submits the pasted prompt
case "$mode" in
  ended) echo "Your free session ended, so the agent stopped here. Send a message to start a new session and continue."
         while IFS= read -r line; do [[ "$line" == *"Continue the same task"* ]] && break; done ;;
  hang) sleep 600 ;;
  hangchange) echo changed >> app.txt; sleep 600 ;;
esac
echo fb >> app.txt
printf 'ALREADY_FIXED: nope\nFREEBUFF-DONE\n' > "$res"
sleep 600
EOF
chmod +x "$FB/bin/freebuff"
cd "$R" || exit 1
fbrun() { # mode -> rc
    echo "$1" > "$FB/mode"; rm -f "$FB/env.txt" "$FB/result" "$FB/result.reason"
    echo "Fix the bug" > "$FB/prompt"
    local rc=0
    PATH="$FB/bin:$PATH" FAKE_FB_DIR="$FB" AUTOFIX_FREEBUFF_BIN=freebuff CODEBUFF_API_KEY=cb-key \
    FREEBUFF_POLL_SEC=1 FREEBUFF_READY_MAX_SEC=15 FREEBUFF_TIMEOUT_SEC="${TMO:-40}" FREEBUFF_PANE_LOG="$FB/pane.log" \
    GH_TOKEN=gh-secret GITHUB_TOKEN=gh-secret2 APP_REPO_TOKEN=app-secret ANTHROPIC_API_KEY=ant-secret \
    CLAUDE_CODE_OAUTH_TOKEN=oauth-secret BITBUCKET_SSH_KEY=bb-secret MYLOCK_KEYSTORE_BASE64=ks-secret \
    AUTOFIX_MAIL_PASS=mail-secret SSH_AUTH_SOCK=/tmp/agent.sock CODEBUFF_TRUST_AGENT_DIRS=1 \
        bash "$ROOT/ci/freebuff-run.sh" "$R" "$FB/prompt" "$FB/result" > "$FB/run.out" 2>&1 || rc=$?
    echo "$rc"
}
rc=$(fbrun ok)
check "freebuff-run ok: rc 0" test "$rc" = 0
check "freebuff-run ok: result has sentinel and marker" grep -q "^ALREADY_FIXED: nope" "$FB/result"
check "freebuff-run ok: pane captured" test -s "$FB/pane.log"
check "freebuff-run ok: freebuff saw its own key" grep -q '^CODEBUFF_API_KEY=cb-key$' "$FB/env.txt"
leaked=$(grep -E '^(GH_TOKEN|GITHUB_TOKEN|APP_REPO_TOKEN|ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|BITBUCKET_SSH_KEY|MYLOCK_KEYSTORE_BASE64|AUTOFIX_MAIL_PASS|SSH_AUTH_SOCK|CODEBUFF_TRUST_AGENT_DIRS)=' "$FB/env.txt" | cut -d= -f1 | tr '\n' ' ')
check "freebuff-run: no credential reaches freebuff (${leaked:-none})" test -z "$leaked"
check "freebuff-run: no secret value anywhere in its env" bash -c '! grep -qE "secret|/tmp/agent.sock" "$1"' _ "$FB/env.txt"
check "freebuff-run: no prompt text on stdout" bash -c '! grep -q "Fix the bug" "$1"' _ "$FB/run.out"
# kill-server returns before the server has exited; allow it a few seconds.
for _ in 1 2 3 4 5; do pgrep -u "$(id -u)" -f "[a]utofix-fb-" >/dev/null || break; sleep 1; done
check "freebuff-run: tmux server gone" nott pgrep -u "$(id -u)" -f "[a]utofix-fb-"
reset_repo

rc=$(fbrun ended)
check "freebuff-run: free session ended -> continued -> rc 0" test "$rc" = 0
check "freebuff-run: continue logged" grep -q "continue #1" "$FB/run.out"
reset_repo

rc=$(fbrun login)
check "freebuff-run: login screen -> rc 4" test "$rc" = 4
check "freebuff-run: login reason" grep -q "not logged in" "$FB/result.reason"
reset_repo

rc=$(TMO=8 fbrun hang)
check "freebuff-run: timeout, no change -> rc 4" test "$rc" = 4
reset_repo
rc=$(TMO=8 fbrun hangchange)
check "freebuff-run: timeout with changes -> rc 1" test "$rc" = 1
reset_repo

rc=0; PATH="$FB/bin:$PATH" AUTOFIX_FREEBUFF_BIN=freebuff FREEBUFF_CONFIG_DIR="$T/nocreds" CODEBUFF_API_KEY= \
    bash "$ROOT/ci/freebuff-run.sh" "$R" "$FB/prompt" "$FB/result" >/dev/null 2>&1 || rc=$?
check "freebuff-run: no credentials -> rc 4" test "$rc" = 4
rc=0; CODEBUFF_API_KEY=x bash "$ROOT/ci/freebuff-run.sh" "$R" "$FB/prompt" "$R/result" >/dev/null 2>&1 || rc=$?
check "freebuff-run: result file inside the repo refused" test "$rc" = 4
fi

# ── Syntax of every script ───────────────────────────────────────────────────
bad=""
while IFS= read -r f; do bash -n "$f" 2>/dev/null || bad="$bad $f"; done \
    < <(find "$ROOT" -name '*.sh' -not -path '*/.git/*' -print)
check "bash -n on every script${bad:+ (bad:$bad)}" test -z "$bad"

echo
if [[ $fails -eq 0 ]]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
