#!/usr/bin/env bash
###############################################################################
# lib/ai-provider.sh — which AI agent runs a fix: Claude, or Freebuff while
# Claude is out of quota. Sourced by worker.sh (and ci/release-app.sh).
#
# Before this, a Claude usage limit read exactly like a bad fix: claude exited
# non-zero, the attempt counted, all MAX_RETRIES were burned in seconds and the
# issue was labelled autofix-stuck for a fault no code change could reach.
#
# Now a limit message is recognised, its reset time is stored in
# $AUTOFIX_STATE_DIR/claude-blocked-until, and fixes run on Freebuff (the free,
# ad-supported Codebuff agent, driven through tmux by ci/freebuff-run.sh) until
# that time has passed. Then Claude is tried again; a successful run clears the
# state. Every switch is logged as an `AI-PROVIDER:` line (a public status line:
# it carries limit text and timestamps only, never prompt or model output) and
# appended to $AUTOFIX_STATE_DIR/provider-switch.log.
#
# Knobs (all optional; the test ones exist so tests/test-ai-fallback.sh can run
# offline against fakes and a fixed clock):
#   AUTOFIX_STATE_DIR    state dir (default ~/.autofix-agent-state)
#   AUTOFIX_FALLBACK     freebuff (default) | none
#   AUTOFIX_NOW          epoch seconds to use as "now" (tests)
#   AUTOFIX_CLAUDE_BIN   claude binary (default: claude)
#   AUTOFIX_FREEBUFF_RUN Freebuff driver (default: $AGENT_DIR/ci/freebuff-run.sh)
###############################################################################

AI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${AGENT_DIR:=$(dirname "$AI_LIB_DIR")}"
AUTOFIX_STATE_DIR="${AUTOFIX_STATE_DIR:-$HOME/.autofix-agent-state}"
AUTOFIX_FALLBACK="${AUTOFIX_FALLBACK:-freebuff}"
AUTOFIX_CLAUDE_BIN="${AUTOFIX_CLAUDE_BIN:-claude}"
AUTOFIX_FREEBUFF_RUN="${AUTOFIX_FREEBUFF_RUN:-$AGENT_DIR/ci/freebuff-run.sh}"
AI_BLOCKED_FILE="$AUTOFIX_STATE_DIR/claude-blocked-until"
AI_SWITCH_LOG="$AUTOFIX_STATE_DIR/provider-switch.log"

# Set by the caller (worker.sh attempt_fix) for gated apps: extra claude flags,
# and an `env ...` prefix that keeps the agent away from GitHub.
AI_CLAUDE_ARGS=()
AI_AGENT_ENV=()
# Outputs of run_fix_agent, for the caller's log lines.
AI_AGENT_USED=""
AI_UNAVAILABLE_REASON=""
AI_BLOCKED_UNTIL=""

ai_now() { echo "${AUTOFIX_NOW:-$(date +%s)}"; }

# One line in the run log (worker.sh's log() when present, so the line carries
# the timestamp/slug prefix ci/status-lines.sh matches) and in the switch log.
ai_log() {
    local msg="AI-PROVIDER: $*"
    if declare -F log >/dev/null; then log "$msg"; else echo "$msg"; fi
    mkdir -p "$AUTOFIX_STATE_DIR" 2>/dev/null || return 0
    printf '%s\t%s\t%s\n' "$(date -u -d "@$(ai_now)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${APP_SLUG:--}" "$*" >> "$AI_SWITCH_LOG" 2>/dev/null || true
}

# claude_limit_reason <output> — prints the limit text and returns 0 when the
# output is a quota / usage-limit / credit / rate-limit message. Only the last
# 3000 bytes count and only specific phrases match, so a fix whose output merely
# talks about "limit" (a rate limiter in the app, say) never triggers a switch.
# What is printed is the matched phrase plus the rest of its line, capped and
# reduced to printable characters: it ends up in a public status line.
claude_limit_reason() {
    printf '%s' "$1" | python3 -I -c '
import re, sys
tail = sys.stdin.buffer.read()[-3000:].decode("utf-8", "replace")
pat = re.compile(
    r"(you.?ve hit your\b[^\n]{0,40}?\blimit"
    r"|\b(?:usage|5-hour|five-hour|weekly|session|daily|opus|sonnet)\s+limit\s+(?:reached|exceeded)"
    r"|claude ai usage limit reached"
    r"|limit will reset at"
    r"|you.?re out of (?:extra )?usage"
    r"|credit balance is too low"
    r"|\brate_limit_error\b"
    r"|\boverloaded_error\b"
    r"|API Error:\s*(?:429|529)\b"
    r"|\b429 Too Many Requests\b)", re.I)
# The first match on the last line that has one: the notice itself, not the
# JSON error type trailing behind it.
for line in reversed(tail.splitlines()):
    m = pat.search(line)
    if m:
        break
else:
    sys.exit(1)
text = line[m.start():][:160]
print("".join(c for c in text if c.isprintable()).strip())
'
}

# parse_reset_time <text> — the ISO-8601 UTC minute at which Claude is usable
# again: the next occurrence of the stated reset time after now, plus one minute
# of slack. Unparseable -> now + 1 hour (Claude is simply tried again then).
parse_reset_time() {
    python3 -I - "$1" "$(ai_now)" <<'PY'
import datetime as dt, re, sys
from zoneinfo import ZoneInfo
text, now_ts = sys.argv[1], int(sys.argv[2])
now = dt.datetime.fromtimestamp(now_ts, dt.timezone.utc)
MONTHS = {m: i for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], 1)}

def out(t):
    t = (t + dt.timedelta(minutes=1)).astimezone(dt.timezone.utc)
    if t.second or t.microsecond:          # round up to the whole minute
        t = t.replace(second=0, microsecond=0) + dt.timedelta(minutes=1)
    print(t.strftime("%Y-%m-%dT%H:%MZ"))
    sys.exit(0)

def parse():
    m = re.search(r"\|(\d{9,11})\b", text)               # "Claude AI usage limit reached|<epoch>"
    if m:
        t = dt.datetime.fromtimestamp(int(m.group(1)), dt.timezone.utc)
        return t if now < t < now + dt.timedelta(days=8) else None
    m = re.search(r"try again in\s+(\d+)\s*(second|sec|minute|min|hour|hr)s?\b", text, re.I)
    if m:
        n, unit = int(m.group(1)), m.group(2).lower()
        secs = n * (3600 if unit.startswith("h") else 60 if unit.startswith("m") else 1)
        return now + dt.timedelta(seconds=secs)
    ms = list(re.finditer(r"resets?\s+(?:at\s+|on\s+)?(?P<spec>[^\n()·∙|]{1,40}?)\s*"
                          r"(?:\((?P<tz>[A-Za-z_/+\-0-9]+)\))?\s*(?:$|[\n.·∙|])", text, re.I | re.M))
    if not ms:
        return None
    spec, tzname = ms[-1].group("spec").strip().lower(), ms[-1].group("tz")
    try:
        tz = ZoneInfo(tzname) if tzname else None
    except Exception:
        tz = None
    if tz is None:
        tz = dt.datetime.now().astimezone().tzinfo     # Claude prints the process's local zone
    tm = re.search(r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*$", spec)
    if not tm:
        return None
    hh, mm, ap = int(tm.group(1)), int(tm.group(2) or 0), tm.group(3)
    if ap:
        if not 1 <= hh <= 12:
            return None
        hh = hh % 12 + (12 if ap == "pm" else 0)
    if hh > 23 or mm > 59:
        return None
    local_now = now.astimezone(tz)
    base = local_now.replace(hour=hh, minute=mm, second=0, microsecond=0)
    month = day = None
    for w in spec[:tm.start()].replace(",", " ").split():
        if w[:3] in MONTHS and month is None:
            month = MONTHS[w[:3]]
        elif w.isdigit() and 1 <= int(w) <= 31:
            day = int(w)
        elif w not in ("at", "today", "on"):
            return None
    if month and day:
        try:
            cand = base.replace(month=month, day=day)
        except ValueError:
            return None
        if cand < local_now - dt.timedelta(days=1):    # "Jan 2" seen on Dec 31
            cand = cand.replace(year=cand.year + 1)
    else:
        cand = base if base > local_now else base + dt.timedelta(days=1)
    if cand - local_now > dt.timedelta(days=8):
        return None
    return cand

t = parse()
out(t if t is not None and t > now else now + dt.timedelta(hours=1) - dt.timedelta(minutes=1))
PY
}

ai_iso_to_epoch() {
    python3 -I -c 'import datetime as dt,sys
print(int(dt.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%MZ").replace(tzinfo=dt.timezone.utc).timestamp()))' "$1" 2>/dev/null
}

# The stored blocked-until, if any (prints it; empty when there is no state).
ai_blocked_until() { [[ -s "$AI_BLOCKED_FILE" ]] && head -1 "$AI_BLOCKED_FILE" | tr -d '[:space:]'; return 0; }

# 0 = Claude may be used (no state, or its reset time has passed). Never invokes
# Claude: /release uses it to decide whether to try at all.
claude_available() {
    local until ep
    until=$(ai_blocked_until)
    [[ -z "$until" ]] && return 0
    ep=$(ai_iso_to_epoch "$until") || return 0      # unreadable state: try Claude
    [[ -z "$ep" ]] && return 0
    AI_BLOCKED_UNTIL="$until"
    [[ "$(ai_now)" -ge "$ep" ]]
}

# record_claude_limit <reason> — store the reset time; keep a later one already
# recorded (another app's run in the same state dir may have seen a longer limit).
record_claude_limit() {
    local reason="$1" until cur cur_ep new_ep
    until=$(parse_reset_time "$reason")
    cur=$(ai_blocked_until)
    if [[ -n "$cur" ]]; then
        cur_ep=$(ai_iso_to_epoch "$cur" || echo 0); new_ep=$(ai_iso_to_epoch "$until" || echo 0)
        [[ "${cur_ep:-0}" -gt "${new_ep:-0}" ]] && until="$cur"
    fi
    mkdir -p "$AUTOFIX_STATE_DIR"
    printf '%s\n' "$until" > "$AI_BLOCKED_FILE.tmp.$$" && mv -f "$AI_BLOCKED_FILE.tmp.$$" "$AI_BLOCKED_FILE"
    AI_BLOCKED_UNTIL="$until"
}

# Claude, exactly as worker.sh ran it before (CLAUDE_PROMPT_MODE stdin|arg, the
# gate flags and env). Output goes to the task log, the out file and stdout.
_ai_run_claude() {
    local prompt="$1" task_log="$2" out_file="$3" mode="$4"
    # Claude has no use for the fallback's credential. A separate `env` in front:
    # AI_AGENT_ENV ends in VAR=value words, after which env takes no more options.
    local envp=(env -u CODEBUFF_API_KEY ${AI_AGENT_ENV[@]+"${AI_AGENT_ENV[@]}"})
    if [[ "$mode" == "stdin" ]]; then
        echo "$prompt" | "${envp[@]}" "$AUTOFIX_CLAUDE_BIN" --dangerously-skip-permissions \
            ${AI_CLAUDE_ARGS[@]+"${AI_CLAUDE_ARGS[@]}"} 2>&1 | tee -a "$task_log" "$out_file"
        return "${PIPESTATUS[1]}"
    fi
    "${envp[@]}" "$AUTOFIX_CLAUDE_BIN" --dangerously-skip-permissions \
        ${AI_CLAUDE_ARGS[@]+"${AI_CLAUDE_ARGS[@]}"} -p "$prompt" 2>&1 | tee -a "$task_log" "$out_file"
    return "${PIPESTATUS[0]}"
}

# Freebuff through ci/freebuff-run.sh. Returns 0 / 1 / 4 like run_fix_agent.
_ai_run_freebuff() {
    local prompt="$1" task_log="$2" out_file="$3"
    if [[ "$AUTOFIX_FALLBACK" == "none" ]]; then
        AI_UNAVAILABLE_REASON="fallback disabled (AUTOFIX_FALLBACK=none)"
        return 4
    fi
    if [[ ! -x "$AUTOFIX_FREEBUFF_RUN" ]]; then
        AI_UNAVAILABLE_REASON="Freebuff driver not found"
        return 4
    fi
    AI_AGENT_USED="Freebuff"
    # The prompt and the result live outside the repo: a result file inside the
    # tree would be committed by `git add -A` as part of the fix.
    local d rc=0
    d=$(mktemp -d "${TMPDIR:-/tmp}/autofix-fb.XXXXXX")
    chmod 700 "$d"
    printf '%s\n' "$prompt" > "$d/prompt.txt"
    if declare -F log >/dev/null; then log "Invoking Freebuff..."; fi
    FREEBUFF_PANE_LOG="${task_log}.freebuff-pane" \
        ${AI_AGENT_ENV[@]+"${AI_AGENT_ENV[@]}"} "$AUTOFIX_FREEBUFF_RUN" "$PWD" "$d/prompt.txt" "$d/result.txt" \
        >> "$task_log" 2>&1 || rc=$?
    if [[ -f "$d/result.txt" ]]; then
        cat "$d/result.txt" > "$out_file"
        # The task log is where FIX_SUMMARY is extracted from, as with Claude's output.
        cat "$d/result.txt" >> "$task_log"
    else
        : > "$out_file"
    fi
    if [[ $rc -eq 4 ]]; then
        AI_UNAVAILABLE_REASON=$(tail -1 "$d/result.txt.reason" 2>/dev/null | cut -c1-200)
        [[ -z "$AI_UNAVAILABLE_REASON" ]] && AI_UNAVAILABLE_REASON="Freebuff unavailable"
    fi
    rm -rf "$d"
    [[ $rc -eq 0 || $rc -eq 4 ]] && return $rc
    return 1
}

# run_fix_agent <prompt> <task_log> <out_file> [stdin|arg]
# The one entry point for a fix session; run in the project dir, on the task's
# starting commit. Returns 0 = agent finished, 1 = agent ran and failed,
# 4 = NO AI AVAILABLE (Claude limited and the fallback unavailable). The agent's
# output (Claude's, or Freebuff's result file) is in <out_file> either way, so
# ALREADY_FIXED: / BUILD_ENV_BROKEN: scanning works for both.
run_fix_agent() {
    local prompt="$1" task_log="$2" out_file="$3" mode="${4:-${CLAUDE_PROMPT_MODE:-arg}}"
    AI_AGENT_USED="" AI_UNAVAILABLE_REASON="" AI_BLOCKED_UNTIL=""
    : > "$out_file"

    local stale=""
    if ! claude_available; then
        ai_log "Claude blocked until $AI_BLOCKED_UNTIL; using Freebuff"
        _ai_run_freebuff "$prompt" "$task_log" "$out_file"
        return $?
    fi
    stale=$(ai_blocked_until)
    [[ -n "$stale" ]] && ai_log "Claude block until $stale has passed; trying Claude again"

    local head_before rc=0 reason out_size
    head_before=$(git rev-parse HEAD 2>/dev/null || echo "")
    AI_AGENT_USED="Claude"
    if declare -F log >/dev/null; then log "Invoking Claude CLI..."; fi
    _ai_run_claude "$prompt" "$task_log" "$out_file" "$mode" || rc=$?

    # A limit is believed when the run failed, or when its whole output is short
    # (the limit notice IS the output): a long successful session that discusses
    # usage limits is not one.
    out_size=$(wc -c < "$out_file")
    if { [[ $rc -ne 0 ]] || [[ $out_size -le 3000 ]]; } \
        && reason=$(claude_limit_reason "$(tail -c 3000 "$out_file")"); then
        record_claude_limit "$reason"
        ai_log "Claude limit hit ($reason); Claude blocked until $AI_BLOCKED_UNTIL; using Freebuff"
        # Whatever Claude got done before the limit is unverified: the fallback starts
        # from the task's commit, like any retry. -e: the task log lives in
        # .autofix-logs, which not every app repo gitignores. Not -x: ignored build
        # caches are worth keeping.
        if [[ -n "$head_before" ]]; then
            git reset --hard "$head_before" >/dev/null 2>&1 || true
            git clean -fd -e .autofix-logs >/dev/null 2>&1 || true
        fi
        : > "$out_file"
        _ai_run_freebuff "$prompt" "$task_log" "$out_file"
        return $?
    fi

    if [[ -n "$stale" && $rc -eq 0 ]]; then
        rm -f "$AI_BLOCKED_FILE"
        ai_log "Claude reset passed; back to Claude"
    fi
    [[ $rc -eq 0 ]] && return 0
    return 1
}
