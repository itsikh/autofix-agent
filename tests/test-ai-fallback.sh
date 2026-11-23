#!/usr/bin/env bash
# Offline test for lib/ai-provider.sh and ci/freebuff-run.sh: limit detection,
# reset parsing, the Claude -> Freebuff switch and back, and the scrubbed
# environment Freebuff runs in. Fake `claude`, a fake freebuff-run and a fake
# freebuff TUI (driven through real tmux), a temp git repo and a fixed clock
# (AUTOFIX_NOW). No network, no real agent.
set -uo pipefail
# Hermetic on an Actions runner too: nothing here may pick the real sudo or CI paths.
unset GITHUB_ACTIONS RUNNER_TEMP AUTOFIX_SECRET_FILES
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

# ── claude_limit_reason: canonical reasons only ─────────────────────────────
lr() { local want="$1" text="$2" got; got=$(claude_limit_reason "some output
$text") || got="(none)"
       if [[ "$got" == "$want" ]]; then pass "limit '${text:0:45}' -> $got"; else fail "limit '${text:0:45}' -> $got (want $want)"; fi; }
lr "weekly limit · resets 5pm (UTC)"   "You've hit your weekly limit · resets 5pm (UTC)"
lr "session limit · resets 3:45am (UTC)" "You've hit your session limit · resets 3:45am (UTC)"
lr "usage limit · resets 5pm (UTC)"    "You've hit your limit · resets 5pm (UTC)"
lr "usage limit · resets 2026-11-23T17:00Z" "Claude AI usage limit reached|1795453200"
lr "credit balance too low"            "Credit balance is too low"
lr "API rate limit (429)"              'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"Number of requests has exceeded your rate limit"}}'
lr "API overloaded (529)"              'API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'
lr "API overloaded (529)"              'API Error: {"type":"error","error":{"type":"overloaded_error"}}'
lr "weekly limit · resets Nov 23, 5pm (America/New_York)" "Weekly limit reached ∙ resets Nov 23, 5pm (America/New_York)"
lr "usage limit · resets 5pm (Europe/Berlin)" "Claude usage limit reached. Your limit will reset at 5pm (Europe/Berlin)."
# Model text never reaches the reason: a notice with junk after it.
lr "weekly limit · resets 5pm (UTC)"   "You've hit your weekly limit · resets 5pm (UTC) <script>secret-code()</script>"
# Not notices: summaries of ordinary fixes (incl. the four from review 1).
for msg in "Added a rate limit to the login screen (limit: 5/min); tests pass." \
           "Fixed the session limit check so the counter resets at midnight." \
           "Fixed the crash when the daily limit exceeded." \
           "Handle HTTP 429 Too Many Requests in ApiClient and back off." \
           "The client now catches rate_limit_error from the backend." \
           "Usage limit reached | user can retry" \
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
pr() { local want="$1" text="$2"; local got; got=$(parse_reset_time "$text" "${3:-60}")
       if [[ "$got" == "$want" ]]; then pass "reset '$text' -> $got"; else fail "reset '$text' -> $got (want $want)"; fi; }
pr 2026-11-23T17:01Z "You've hit your weekly limit · resets 5pm (UTC)"   # 5pm already passed today -> tomorrow
pr 2026-11-23T17:01Z "weekly limit · resets 5pm (UTC)"                   # the canonical form reads back
pr 2026-11-22T21:01Z "You've hit your session limit · resets 9pm (UTC)"  # later today
pr 2026-11-23T03:46Z "You've hit your session limit · resets 3:45am (UTC)"
pr 2026-11-23T22:01Z "You've hit your weekly limit · resets Nov 23, 5pm (America/New_York)"
pr 2026-11-23T01:01Z "You've hit your session limit · resets 8pm (America/New_York)"  # 20:00 NY = 01:00Z
pr 2026-11-23T17:01Z "Claude AI usage limit reached|$(epoch 2026-11-23T17:00:00Z)"
pr 2026-11-23T17:01Z "usage limit · resets 2026-11-23T17:00Z"
pr 2026-11-22T20:31Z "rate_limit_error: please try again in 30 minutes"
pr 2026-11-22T22:01Z "overloaded, try again in 2 hours"
pr 2026-11-22T21:00Z "Credit balance is too low"                           # unparseable -> now + 1h
pr 2026-11-22T20:15Z "API overloaded (529)" 15                             # transient -> now + 15 min
pr 2026-11-22T21:00Z "Claude AI usage limit reached|1700000000"            # epoch in the past -> now + 1h
AUTOFIX_NOW=$(epoch 2026-12-31T23:30:00Z) pr 2027-01-01T00:16Z "resets 12:15am (UTC)"  # day + year rollover
AUTOFIX_NOW=$(epoch 2026-12-31T23:30:00Z) pr 2027-01-02T17:01Z "resets Jan 2, 5pm (UTC)"

# ── Fakes for run_fix_agent ──────────────────────────────────────────────────
# claude: mode from $FAKE/claude-mode. Counts calls. "limit" first edits and
# commits (so the test can see the tree reset), then prints a limit notice.
cat > "$FAKE/claude" <<'EOF'
#!/usr/bin/env bash
echo x >> "$(dirname "$0")/claude-calls"
env > "$(dirname "$0")/claude-env"
case "$(cat "$(dirname "$0")/claude-mode")" in
  limit) echo partial > claude-partial.txt; git add -A; git -c user.email=t@t -c user.name=t commit -qm partial
         echo "You've hit your weekly limit · resets 5pm (UTC)"; exit 1 ;;
  ok)    echo fixed >> app.txt; echo "Done. FIX_SUMMARY_START fixed FIX_SUMMARY_END"; exit 0 ;;
  fail)  echo "something broke"; exit 1 ;;
  # rc 0, a real fix, and a summary full of limit words (review 1's samples).
  okwords) echo fixed >> app.txt; printf '%s\n' "$(cat "$(dirname "$0")/claude-text")"; exit 0 ;;
  # rc 0 and the whole output is the notice, nothing touched: a limit.
  tinylimit) echo "You've hit your session limit · resets 9pm (UTC)"; exit 0 ;;
  # rc 0, notice-shaped text, but the tree changed: a fix, not a limit.
  tinychange) echo fixed >> app.txt; echo "You've hit your session limit · resets 9pm (UTC)"; exit 0 ;;
  overload) echo 'API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'; exit 1 ;;
esac
EOF
# freebuff-run: records the tree it started on and the env; result body and exit
# code from files.
cat > "$FAKE/freebuff-run" <<'EOF'
#!/usr/bin/env bash
F="$(dirname "$0")"; echo x >> "$F/fb-calls"
{ git -C "$1" rev-parse HEAD; git -C "$1" status --porcelain; } > "$F/fb-start-tree"
env > "$F/fb-env"
[[ -f "$F/fb-notice" ]] && cp "$F/fb-notice" "$3.notice"
rc=$(cat "$F/fb-rc" 2>/dev/null || echo 0)
if [[ $rc == 4 ]]; then { cat "$F/fb-reason" 2>/dev/null || echo "free allowance used up"; } > "$3.reason"; exit 4; fi
# The agent owns .autofix-logs while it runs: plant symlinks to a runner file.
if [[ -f "$F/fb-evil-log" ]]; then
  for f in "$1"/.autofix-logs/task_*.log; do
    rm -f "$f"; for s in "" .fix_summary .freebuff-pane; do ln -sf "$F/victim-log" "$f$s"; done
  done
  mkfifo "$1/.autofix-logs/task_1.log.attempt"
fi
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
check "first limit: switch logged (canonical reason)" grep -q "AI-PROVIDER: Claude limit hit (weekly limit · resets 5pm (UTC)); Claude blocked until 2026-11-23T17:01Z; using Freebuff" "$RUNLOG"
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

# 8b. rc 0 runs are never limits unless they are tiny no-ops (review 1, finding 1).
export AUTOFIX_FB_LEDGER="$T/ledger"; AUTOFIX_NOW=$(epoch 2026-11-22T20:00:00Z)
for txt in "Fixed the crash when the daily limit exceeded." \
           "Handle HTTP 429 Too Many Requests in ApiClient" \
           "The client now catches rate_limit_error from the backend" \
           "Usage limit reached | user can retry" \
           "You've hit your weekly limit · resets 5pm (UTC)"; do
    echo okwords > "$FAKE/claude-mode"; printf '%s\nFIX_SUMMARY_START\n%s\nFIX_SUMMARY_END\n' "$txt" "$txt" > "$FAKE/claude-text"
    f_before=$(calls fb-calls); rc=0; run_fix_agent "p" "$TL" "$OUT" arg >/dev/null || rc=$?
    check "rc 0 fix mentioning '${txt:0:30}': Claude's fix kept, no switch" \
        test "$rc/$AI_AGENT_USED/$(calls fb-calls)/$(grep -c fixed app.txt)" = "0/Claude/$f_before/1"
    check "rc 0 fix mentioning '${txt:0:30}': no block" test ! -e "$AUTOFIX_STATE_DIR/claude-blocked-until"
    reset_repo
done
echo tinylimit > "$FAKE/claude-mode"
rc=0; run_fix_agent "p" "$TL" "$OUT" arg >/dev/null || rc=$?
check "rc 0 tiny no-op limit notice: switch" test "$rc/$AI_AGENT_USED" = "0/Freebuff"
check "rc 0 tiny no-op limit notice: blocked until 21:01" test "$(cat "$AUTOFIX_STATE_DIR/claude-blocked-until")" = 2026-11-22T21:01Z
rm -f "$AUTOFIX_STATE_DIR/claude-blocked-until" "$AUTOFIX_FB_LEDGER"; reset_repo
echo tinychange > "$FAKE/claude-mode"
rc=0; run_fix_agent "p" "$TL" "$OUT" arg >/dev/null || rc=$?
check "rc 0 notice text but tree changed: a fix, no switch" test "$rc/$AI_AGENT_USED" = "0/Claude"
reset_repo

# 8c. Transient overload without a reset: 15 minutes, not an hour.
echo overload > "$FAKE/claude-mode"
rc=0; run_fix_agent "p" "$TL" "$OUT" arg >/dev/null || rc=$?
check "529 without reset: blocked 15 min" test "$(cat "$AUTOFIX_STATE_DIR/claude-blocked-until")" = 2026-11-22T20:15Z
check "529: status line carries only the canonical reason" grep -q "AI-PROVIDER: Claude limit hit (API overloaded (529)); Claude blocked until 2026-11-22T20:15Z; using Freebuff" "$RUNLOG"
reset_repo

# 8d. The expired block is cleared by any Claude run without a limit notice,
#     even a failed one, and "back to Claude" is logged once.
AUTOFIX_NOW=$(epoch 2026-11-22T20:30:00Z); echo fail > "$FAKE/claude-mode"
n_back=$(grep -c "back to Claude" "$RUNLOG")
rc=0; run_fix_agent "p" "$TL" "$OUT" arg >/dev/null || rc=$?
check "expired block + failed Claude run: rc 1 (a normal failure)" test "$rc/$AI_AGENT_USED" = "1/Claude"
check "expired block + failed Claude run: block cleared" test ! -e "$AUTOFIX_STATE_DIR/claude-blocked-until"
run_fix_agent "p" "$TL" "$OUT" arg >/dev/null
check "back to Claude logged once" test "$(grep -c "back to Claude" "$RUNLOG")" = "$((n_back + 1))"
AUTOFIX_NOW=$(epoch 2026-11-22T20:00:00Z); reset_repo

# 8e. Freebuff budget: one attempt per task; a per-job wall-clock total.
echo "2026-11-23T17:01Z" > "$AUTOFIX_STATE_DIR/claude-blocked-until"; rm -f "$AUTOFIX_FB_LEDGER"
AI_TASK_KEY="#7"; f_before=$(calls fb-calls)
rc=0; run_fix_agent "p" "$TL" "$OUT" arg >/dev/null || rc=$?
check "budget: first Freebuff attempt at task #7 runs" test "$rc/$(calls fb-calls)" = "0/$((f_before + 1))"
rc=0; run_fix_agent "p" "$TL" "$OUT" arg >/dev/null || rc=$?
check "budget: second attempt at #7 -> 4, scope task, Freebuff not invoked" \
    test "$rc/$AI_NO_AI_SCOPE/$(calls fb-calls)" = "4/task/$((f_before + 1))"
AI_TASK_KEY="#8"
rc=0; run_fix_agent "p" "$TL" "$OUT" arg >/dev/null || rc=$?
check "budget: another task still gets its attempt" test "$rc/$(calls fb-calls)" = "0/$((f_before + 2))"
check "budget: driver timeout capped by the remaining budget" grep -q "^FREEBUFF_TIMEOUT_SEC=3600$" "$FAKE/fb-env"
printf 'x\t%s\n' $((85 * 60)) >> "$AUTOFIX_FB_LEDGER"; AI_TASK_KEY="#9"
run_fix_agent "p" "$TL" "$OUT" arg >/dev/null
check "budget: 5 min left -> driver timeout 300" grep -q "^FREEBUFF_TIMEOUT_SEC=[23][0-9][0-9]$" "$FAKE/fb-env"
printf 'y\t%s\n' 300 >> "$AUTOFIX_FB_LEDGER"; AI_TASK_KEY="#10"; f_before=$(calls fb-calls)
rc=0; run_fix_agent "p" "$TL" "$OUT" arg >/dev/null || rc=$?
check "budget: used up -> 4, scope job, Freebuff not invoked" test "$rc/$AI_NO_AI_SCOPE/$(calls fb-calls)" = "4/job/$f_before"
check "budget: reason names the knob" grep -q AUTOFIX_FREEBUFF_BUDGET_MIN <<< "$AI_UNAVAILABLE_REASON"
AI_TASK_KEY=""; rm -f "$AUTOFIX_FB_LEDGER"; reset_repo

# 8f. Freebuff's key reaches the driver only — not the environment of anything
#     else (builds, Claude); and driver notices become AI-PROVIDER lines.
check "key: not in this shell's exported environment" nott bash -c 'env | grep -q CODEBUFF'
AI_CODEBUFF_KEY=cb-test-key
echo "Freebuff refreshed its credentials; update the FREEBUFF_CREDENTIALS secret if runs start failing to log in" > "$FAKE/fb-notice"
run_fix_agent "p" "$TL" "$OUT" arg >/dev/null
check "key: driver gets AUTOFIX_CODEBUFF_API_KEY" grep -q "^AUTOFIX_CODEBUFF_API_KEY=cb-test-key$" "$FAKE/fb-env"
check "notice: credentials refresh logged as AI-PROVIDER line" grep -q "AI-PROVIDER: Freebuff refreshed its credentials; update the FREEBUFF_CREDENTIALS secret" "$RUNLOG"
rm -f "$FAKE/fb-notice" "$AUTOFIX_STATE_DIR/claude-blocked-until"; reset_repo
echo ok > "$FAKE/claude-mode"; run_fix_agent "p" "$TL" "$OUT" arg >/dev/null
check "key: Claude does not get it" nott grep -q "CODEBUFF" "$FAKE/claude-env"
AI_CODEBUFF_KEY=""; rm -f "$AUTOFIX_FB_LEDGER"; reset_repo
k=$(AUTOFIX_CODEBUFF_API_KEY=k1 bash -c 'source "$1/lib/ai-provider.sh"; echo "$AI_CODEBUFF_KEY"; env | grep -c CODEBUFF' _ "$ROOT")
check "key: sourcing the lib keeps it as a shell variable and drops it from env" test "$k" = "k1
0"

# 8h. After a Freebuff run (the agent owned .autofix-logs): symlinks and FIFOs it
#     planted there are gone before anything is written; the runner's later git
#     ignores fsmonitor and hooks; only the driver's fixed reasons pass.
echo "2026-11-23T17:01Z" > "$AUTOFIX_STATE_DIR/claude-blocked-until"; rm -f "$AUTOFIX_FB_LEDGER"
mkdir -p "$R/.autofix-logs"; TL2="$R/.autofix-logs/task_1.log"; echo ORIGINAL > "$FAKE/victim-log"
: > "$TL2"; touch "$FAKE/fb-evil-log"; printf 'FIX_SUMMARY_START\nagent text\nFIX_SUMMARY_END\n' > "$FAKE/fb-body"
rc=0; run_fix_agent "p" "$TL2" "$OUT" arg >/dev/null || rc=$?
check "planted log symlinks: rc 0" test "$rc" = 0
check "planted log symlinks: the runner file behind them is untouched" test "$(cat "$FAKE/victim-log")" = ORIGINAL
check "planted log symlinks: no symlink or FIFO left in .autofix-logs" test -z "$(find "$R/.autofix-logs" ! -type f ! -type d)"
check "planted log symlinks: result in a regular task log" bash -c '[[ -f "$1" && ! -L "$1" ]] && grep -q "agent text" "$1"' _ "$TL2"
rm -f "$FAKE/fb-evil-log" "$TL2"; ln -s "$FAKE/victim-log" "$TL2"
rc=0; run_fix_agent "p" "$TL2" "$OUT" arg >/dev/null || rc=$?
check "task log a symlink before the run: refused, runner file untouched" test "$rc/$(cat "$FAKE/victim-log")" = 0/ORIGINAL
check "task log a symlink before the run: replaced by a regular file" test -f "$TL2" -a ! -L "$TL2"
check "git hardened for the rest of the process" bash -c 'git config --get core.fsmonitor | grep -qx false && git config --get core.hooksPath | grep -qx /dev/null'
git config core.fsmonitor "touch $T/pwned-fsm"; git status >/dev/null 2>&1; git config --unset core.fsmonitor
check "git hardened: a planted core.fsmonitor does not run" test ! -e "$T/pwned-fsm"
reset_repo
echo 4 > "$FAKE/fb-rc"
printf 'free allowance used up\nsee http://evil.example/<b>pwn</b>\n' > "$FAKE/fb-reason"
run_fix_agent "p" "$TL" "$OUT" arg >/dev/null
check "reason: anything but a fixed driver reason -> 'Freebuff unavailable'" test "$AI_UNAVAILABLE_REASON" = "Freebuff unavailable"
echo "isolation unavailable" > "$FAKE/fb-reason"
run_fix_agent "p" "$TL" "$OUT" arg >/dev/null
check "reason: a fixed driver reason passes" test "$AI_UNAVAILABLE_REASON" = "isolation unavailable"
missing=""
while IFS= read -r r; do
    printf '%s\n' "${AI_FB_REASONS[@]}" | grep -qxF -- "$r" || missing+="[$r] "
done < <(grep -oE 'unavailable "[^"]+"' "$ROOT/ci/freebuff-run.sh" | sed -E 's/^unavailable "//; s/"$//' | sort -u)
check "every reason the driver can give is in AI_FB_REASONS${missing:+ (missing: $missing)}" test -z "$missing"
check "no driver reason carries a variable" nott grep -qE 'unavailable "[^"]*\$' "$ROOT/ci/freebuff-run.sh"
rm -f "$FAKE/fb-rc" "$FAKE/fb-reason" "$AUTOFIX_STATE_DIR/claude-blocked-until"; : > "$FAKE/fb-body"; reset_repo

# 8g. The switch log stays bounded.
for i in $(seq 1 300); do echo "old $i" >> "$AI_SWITCH_LOG"; done
ai_log "trim test"
check "switch log trimmed to $AI_SWITCH_LOG_KEEP lines" test "$(wc -l < "$AI_SWITCH_LOG")" = "$AI_SWITCH_LOG_KEEP"

# 9. Status line format: AI-PROVIDER lines pass ci/status-lines.sh, unchanged.
lines=$(bash "$ROOT/ci/status-lines.sh" "$RUNLOG")
check "status lines include AI-PROVIDER" grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}\] \[testapp\] AI-PROVIDER: Claude limit hit \(.*\); Claude blocked until 2026-11-23T17:01Z; using Freebuff$' <<< "$lines"
check "status lines carry no prompt text" nott grep -q "the prompt" <<< "$lines"

# ── ci/freebuff-run.sh against a fake freebuff TUI in real tmux ──────────────
# The fake prints the REAL freebuff 0.2.36 screens (tests/fixtures/*.pane; the
# end screen is a capture from a real run, the start screen is assembled from
# the real start-screen lines): "Enter a coding task or / for commands",
# "0/5 hours remaining", "May use data for AI training", "1h left · 12.1K (5%)".
# It finds its data dir from $0, because in user mode it runs under `env -i`.
if ! command -v tmux >/dev/null; then
    fail "tmux not installed — freebuff-run.sh tests skipped"
else
FB="$T/fb"; mkdir -p "$FB/bin" "$T/home" "$T/fbcfg"
# A user name that does not exist here (useradd is exercised; a real autofix-fb
# on this machine must not matter).
FBU="afb-test-nouser"
cp "$HERE"/fixtures/freebuff-0.2.36-*.pane "$FB/"
echo '{"token":"fake-cred-v1"}' > "$T/fbcfg/credentials.json"; echo bin > "$T/fbcfg/freebuff"
cat > "$FB/bin/freebuff" <<'FAKEFB'
#!/usr/bin/env bash
F="$(cd "$(dirname "$0")/.." && pwd)"
env > "$F/env.txt"; pwd > "$F/cwd.txt"; ls -a > "$F/cwd-ls.txt"
{ cat local.properties 2>/dev/null || echo MISSING; } > "$F/lp-during"
{ cat keystore.properties 2>/dev/null || echo MISSING; } > "$F/ks-during"
cp "$HOME/.gradle/gradle.properties" "$F/gradle-props.txt" 2>/dev/null
mode=$(cat "$F/mode")
case "$mode" in
  login) echo "Press ENTER to login..."; sleep 600 ;;
  busy)  echo " Freebuff is already running elsewhere. Take over that session?"; read -r _; clear ;;
  die)   cat "$F/freebuff-0.2.36-start.pane"; sleep 2; tmux kill-server; sleep 600 ;;
esac
cat "$F/freebuff-0.2.36-start.pane"
res=""
while IFS= read -r line; do
  line=${line%$'\r'}
  case "$line" in *"RESULT_FILE: "*) res="${line##*RESULT_FILE: }" ;; esac
  [[ "$line" == *"nowhere else."* ]] && break
done
read -r _   # the Enter that submits the pasted prompt
clear
case "$mode" in
  ended) echo "  Your free session ended, so the agent stopped here. Send a message to start a new session and continue."
         while IFS= read -r line; do [[ "$line" == *"Continue the same task"* ]] && break; done ;;
  hang) sleep 600 ;;
  hangchange) echo changed >> app.txt; sleep 600 ;;
  # The app's own code, shown in the transcript (indented), says every failure
  # string; so does the chat title in the status bar. None of it is chrome.
  appcode)
    printf '%s\n' "  • Read src/Login.kt" "  \$ grep -rn 'allowance' src" \
      '  src/Login.kt:12:  showError("Not logged in")' \
      "  src/Quota.kt:3:  // The accounts on this device share one daily allowance, and what's left today doesn't cover an hour of" \
      "  src/Sess.kt:9:  // Take over that session?" \
      "  Can't reach Freebuff servers (mock in test)" \
      " 1h left · 12.1K (5%)                                ✕ End session" \
      " Beam 1.0 · /work · /model to change · Chat: Not logged in banner shows after login, take over the..."
    sleep 6 ;;
  allowance)
    echo " The accounts on this device share one daily allowance, and what's left today doesn't cover an hour of Beam 1.0."
    sleep 600 ;;
  creds) echo '{"token":"fake-cred-v2"}' > "${FREEBUFF_CONFIG_DIR:-$HOME/.config/manicode}/credentials.json" ;;
  # What an agent could leave for the runner to execute later.
  evilgit)
    git config core.fsmonitor "touch $F/pwned-fsmonitor"
    printf '#!/bin/sh\ntouch %s/pwned-hook\n' "$F" > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
    echo "* filter=evil" > .git/info/attributes
    echo "$F/evil-common" > .git/commondir ;;
  evilgitdir) cp -a .git .git-new && rm -rf .git && mv .git-new .git ;;
  # The result is a symlink to a runner file that "looks done".
  symres) ln -s "$F/victim" "$res"; echo fb >> app.txt; sleep 600 ;;
esac
echo fb >> app.txt
cat "$F/freebuff-0.2.36-done.pane"
printf 'ALREADY_FIXED: nope\nFREEBUFF-DONE\n' > "$res"
sleep 600
FAKEFB
chmod +x "$FB/bin/freebuff"
cd "$R" || exit 1
fbrun() { # mode -> rc   (env: ISO=same|user, TAKE=yes|no, TMO, XPATH)
    echo "$1" > "$FB/mode"; rm -f "$FB/env.txt" "$FB/result" "$FB/result.reason" "$FB/result.notice" "$FB/cwd-ls.txt" \
        "$FB/lp-during" "$FB/ks-during" "$FB/gradle-props.txt"
    echo "Fix the bug" > "$FB/prompt"
    local rc=0
    # shellcheck disable=SC2086
    env -u GITHUB_ACTIONS ${XENV:-} PATH="${XPATH:+$XPATH:}$FB/bin:$PATH" HOME="$T/home" FREEBUFF_CONFIG_DIR="$T/fbcfg" \
    AUTOFIX_FREEBUFF_BIN=freebuff AUTOFIX_CODEBUFF_API_KEY=cb-key FREEBUFF_ISOLATION="${ISO:-same}" \
    FREEBUFF_TAKEOVER="${TAKE:-no}" FREEBUFF_SUDO="${SUDOCMD:-$FB/bin/sudo -n}" FREEBUFF_USER="$FBU" \
    FREEBUFF_POLL_SEC="${POLL:-1}" FREEBUFF_READY_MAX_SEC=15 FREEBUFF_TIMEOUT_SEC="${TMO:-40}" FREEBUFF_PANE_LOG="$FB/pane.log" \
    GH_TOKEN=gh-secret GITHUB_TOKEN=gh-secret2 APP_REPO_TOKEN=app-secret ANTHROPIC_API_KEY=ant-secret \
    CLAUDE_CODE_OAUTH_TOKEN=oauth-secret BITBUCKET_SSH_KEY=bb-secret MYLOCK_KEYSTORE_BASE64=ks-secret \
    AUTOFIX_MAIL_PASS=mail-secret SSH_AUTH_SOCK=/tmp/agent.sock CODEBUFF_TRUST_AGENT_DIRS=1 \
    GITHUB_ENV=/tmp/gh-env-file GITHUB_PATH=/tmp/gh-path-file GITHUB_OUTPUT=/tmp/gh-out-file \
    GITHUB_STEP_SUMMARY=/tmp/gh-sum-file RUNNER_TEMP="$T/runner-temp" ACTIONS_RUNTIME_TOKEN=act-secret \
        bash "$ROOT/ci/freebuff-run.sh" "$R" "$FB/prompt" "$FB/result" > "$FB/run.out" 2>&1 || rc=$?
    echo "$rc"
}
LEAK_RE='^(GH_TOKEN|GITHUB_TOKEN|APP_REPO_TOKEN|ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|BITBUCKET_SSH_KEY|MYLOCK_KEYSTORE_BASE64|AUTOFIX_MAIL_PASS|SSH_AUTH_SOCK|CODEBUFF_TRUST_AGENT_DIRS|GITHUB_ENV|GITHUB_PATH|GITHUB_OUTPUT|GITHUB_STEP_SUMMARY|RUNNER_TEMP|ACTIONS_[A-Z_]*|AUTOFIX_CODEBUFF_API_KEY)='
rc=$(fbrun ok)
check "freebuff-run ok (real start screen, capital E): rc 0" test "$rc" = 0
check "freebuff-run ok: result has sentinel and marker" grep -q "^ALREADY_FIXED: nope" "$FB/result"
check "freebuff-run ok: pane captured" test -s "$FB/pane.log"
check "freebuff-run ok: freebuff saw its own key as CODEBUFF_API_KEY" grep -q '^CODEBUFF_API_KEY=cb-key$' "$FB/env.txt"
leaked=$(grep -E "$LEAK_RE" "$FB/env.txt" | cut -d= -f1 | tr '\n' ' ')
check "freebuff-run: no credential or runner file var reaches freebuff (${leaked:-none})" test -z "$leaked"
check "freebuff-run: no secret value anywhere in its env" bash -c '! grep -qE "secret|/tmp/agent.sock|gh-env-file" "$1"' _ "$FB/env.txt"
check "freebuff-run: no prompt text on stdout" bash -c '! grep -q "Fix the bug" "$1"' _ "$FB/run.out"
check "freebuff-run same-user: one-line warning" test "$(grep -c "WARNING: Freebuff runs as" "$FB/run.out")" = 1
check "freebuff-run: unchanged credentials -> no notice" test ! -e "$FB/result.notice"
# kill-server returns before the server has exited; allow it up to 10 s (a loaded machine).
for _ in $(seq 1 10); do pgrep -u "$(id -u)" -f "[a]utofix-fb-" >/dev/null || break; sleep 1; done
check "freebuff-run: tmux server gone" nott pgrep -u "$(id -u)" -f "[a]utofix-fb-"
reset_repo

rc=$(fbrun appcode)
check "freebuff-run: 'Not logged in'/'daily allowance'/'Take over' in app code (transcript, chat title) -> still rc 0" test "$rc" = 0
check "freebuff-run: appcode left no reason" test ! -e "$FB/result.reason"
reset_repo

rc=$(fbrun allowance)
check "freebuff-run: allowance sentence in the chrome -> rc 4" test "$rc" = 4
check "freebuff-run: allowance reason" grep -q "free allowance used up" "$FB/result.reason"
reset_repo

rc=$(TAKE=no fbrun busy)
check "freebuff-run: session busy + FREEBUFF_TAKEOVER=no -> rc 4" test "$rc" = 4
check "freebuff-run: takeover reason (a fixed string)" grep -qx "session in use elsewhere" "$FB/result.reason"
reset_repo
rc=$(TAKE=yes fbrun busy)
check "freebuff-run: session busy + FREEBUFF_TAKEOVER=yes -> takes over -> rc 0" test "$rc" = 0
reset_repo

t_die=$SECONDS; rc=$(TMO=40 fbrun die)
el=$((SECONDS - t_die))
check "freebuff-run: tmux server died -> stops at once (rc $rc, ${el}s < 25s)" test "$rc" = 4 -a "$el" -lt 25
reset_repo

rc=$(fbrun creds)
check "freebuff-run: credentials refreshed -> rc 0" test "$rc" = 0
check "freebuff-run: credentials refresh notice (no content)" grep -qx "Freebuff refreshed its credentials; update the FREEBUFF_CREDENTIALS secret if runs start failing to log in" "$FB/result.notice"
check "freebuff-run: notice carries no credential" nott grep -q "fake-cred" "$FB/result.notice"
echo '{"token":"fake-cred-v1"}' > "$T/fbcfg/credentials.json"
reset_repo

rc=$(fbrun ended)
check "freebuff-run: free session ended -> continued -> rc 0" test "$rc" = 0
check "freebuff-run: continue logged" grep -q "continue #1" "$FB/run.out"
reset_repo

rc=$(fbrun login)
check "freebuff-run: login screen -> rc 4" test "$rc" = 4
check "freebuff-run: login reason" grep -q "not logged in" "$FB/result.reason"
reset_repo

t_h=$SECONDS; rc=$(TMO=8 fbrun hang)
el=$((SECONDS - t_h))
check "freebuff-run: timeout, no change -> rc 4" test "$rc" = 4
check "freebuff-run: one deadline from the start (${el}s <= 14s)" test "$el" -le 14
reset_repo
rc=$(TMO=8 fbrun hangchange)
check "freebuff-run: timeout with changes -> rc 1" test "$rc" = 1
reset_repo

# ── User mode (FREEBUFF_ISOLATION=user) through a fake sudo ──────────────────
# Real isolation needs root (CI: GITHUB_ACTIONS + passwordless sudo). Here a fake
# sudo logs every privileged call and emulates it as this user — useradd/chown/
# setfacl/pkill are no-ops, mount --bind is a symlink — so the plumbing is
# tested: which calls are made, the clean env -i, the secret moves and restores,
# the result copy-back, cleanup. The access denials themselves are CI-only (and
# were smoke-tested once on a VM with a real autofix-fb user).
# $FB/chown-fail holds a path: the hand-over chown of it fails (half-way, as far
# as the driver can tell).
cat > "$FB/bin/sudo" <<'FAKESUDO'
#!/usr/bin/env bash
F="$(cd "$(dirname "$0")/.." && pwd)"; echo "$*" >> "$F/sudo.log"
[[ "${1:-}" == -n ]] && shift
if [[ "${1:-}" == -u ]]; then shift 2; exec "$@"; fi
case "$1" in
  useradd|setfacl|pkill) exit 0 ;;
  chown)  [[ -f "$F/chown-fail" && "$4" == "$(cat "$F/chown-fail")" && "$3" != [0-9]* ]] && exit 1; exit 0 ;;
  mount)  rmdir "$4" && ln -s "$3" "$4" ;;
  umount) [[ "$2" == -l ]] && shift; rm -f "$2" ;;
  *) exec "$@" ;;
esac
FAKESUDO
printf '#!/bin/sh\nexit 0\n' > "$FB/bin/setfacl"; chmod +x "$FB/bin/sudo" "$FB/bin/setfacl"
mkdir -p "$T/home/.ssh" "$T/runner-temp" "$T/home/.gradle"
printf 'org.gradle.java.home=/opt/fake-jdk\norg.gradle.jvmargs=-Xmx5g\nsigning.storePassword=gp-secret\nRELEASE_KEY_PASSWORD=gp-secret\n' \
    > "$T/home/.gradle/gradle.properties"
printf 'keystore.properties\nlocal.properties\n*.jks\n.autofix-logs/\n' >> "$R/.git/info/exclude"
echo "storePassword=ks-pass" > "$R/keystore.properties"
no_fbhome() { ! ls -d /tmp/autofix-fb-home.* 2>/dev/null | grep -q .; }
rm -f "$FB/sudo.log"
rc=$(XENV="JAVA_HOME=/opt/fake-jdk ANDROID_HOME=/opt/sdk ANDROID_SDK_ROOT=/opt/sdk" ISO=user fbrun ok)
check "user mode: rc 0" test "$rc" = 0
check "user mode: result copied back to the caller's path" grep -q "^FREEBUFF-DONE$" "$FB/result"
check "user mode: announced" grep -q "isolated: running as $FBU" "$FB/run.out"
check "user mode: user created when missing" grep -q "^-n useradd --system .* $FBU$" "$FB/sudo.log"
check "user mode: runner HOME denied" grep -qx -- "-n setfacl -m u:$FBU:--- $T/home" "$FB/sudo.log"
check "user mode: ~/.ssh denied" grep -qx -- "-n setfacl -m u:$FBU:--- $T/home/.ssh" "$FB/sudo.log"
check "user mode: RUNNER_TEMP denied" grep -qx -- "-n setfacl -m u:$FBU:--- $T/runner-temp" "$FB/sudo.log"
check "user mode: project handed over and back" bash -c 'grep -qx -- "-n chown -R $3:$3 $2" "$1" && grep -qx -- "-n chown -R $(id -u):$(id -g) $2" "$1"' _ "$FB/sudo.log" "$R" "$FBU"
check "user mode: modes made usable after the chown back" grep -qx -- "-n chmod -R u+rwX $R" "$FB/sudo.log"
check "user mode: project bind-mounted and unmounted" bash -c 'grep -q "^-n mount --bind $2 /tmp/autofix-fb-home\..*/work$" "$1" && grep -q "^-n umount /tmp/autofix-fb-home\..*/work$" "$1"' _ "$FB/sudo.log" "$R"
check "user mode: tmux runs as the user under env -i" grep -q "^-n -u $FBU env -i HOME=/tmp/autofix-fb-home\..* tmux -L autofix-fb-" "$FB/sudo.log"
check "user mode: the result is read as the user" grep -q "^-n -u $FBU env -i PATH=/usr/bin:/bin sh -c" "$FB/sudo.log"
check "user mode: pkill until no process is left" bash -c 'grep -q "^-n pkill -KILL -u $2$" "$1" && grep -q "^-n pgrep -u $2$" "$1"' _ "$FB/sudo.log" "$FBU"
check "user mode: ACL denies are removed" grep -qx -- "-n setfacl -x u:$FBU $T/home" "$FB/sudo.log"
check "user mode: throwaway home removed with --one-file-system" grep -q "^-n rm -rf --one-file-system /tmp/autofix-fb-home\." "$FB/sudo.log"
check "user mode: agent works in the bind mount, not the runner's path" grep -q "^/tmp/autofix-fb-home\..*/work$" "$FB/cwd.txt"
check "user mode: keystore.properties holds placeholders during the run" grep -qx "storePassword=ci-placeholder" "$FB/ks-during"
check "user mode: keystore.properties restored" grep -qx "storePassword=ks-pass" "$R/keystore.properties"
check "user mode: HOME is the throwaway one" grep -q "^HOME=/tmp/autofix-fb-home\." "$FB/env.txt"
check "user mode: the freebuff it runs is the configured one (absolute path)" grep -q "^-n -u $FBU env -i .* new-session .*$FB/bin/freebuff" "$FB/sudo.log"
# Plus what tmux itself sets in a pane.
extra=$(grep -vE '^(HOME|PATH|LANG|TERM|SHELL|COLORTERM|TERM_PROGRAM|TERM_PROGRAM_VERSION|FREEBUFF_CONFIG_DIR|CODEBUFF_API_KEY|JAVA_HOME|ANDROID_HOME|ANDROID_SDK_ROOT|TMUX|TMUX_PANE|PWD|OLDPWD|SHLVL|_)=' "$FB/env.txt" | cut -d= -f1 | tr '\n' ' ')
check "user mode: env is minimal (env -i)${extra:+ — extra: $extra}" test -z "$extra"
check "user mode: JDK and SDK passed through" bash -c 'grep -qx JAVA_HOME=/opt/fake-jdk "$1" && grep -qx ANDROID_HOME=/opt/sdk "$1" && grep -qx ANDROID_SDK_ROOT=/opt/sdk "$1"' _ "$FB/env.txt"
check "user mode: JDK on PATH" grep -q "^PATH=/opt/fake-jdk/bin:" "$FB/env.txt"
check "user mode: gradle.properties has the runner's JDK and jvmargs" bash -c 'grep -qx org.gradle.java.home=/opt/fake-jdk "$1" && grep -qx org.gradle.jvmargs=-Xmx5g "$1"' _ "$FB/gradle-props.txt"
check "user mode: gradle.properties carries no signing key" nott grep -qiE "gp-secret|password" "$FB/gradle-props.txt"
check "user mode: key reaches freebuff from its private file" grep -q '^CODEBUFF_API_KEY=cb-key$' "$FB/env.txt"
check "user mode: config copy is its own" grep -q "^FREEBUFF_CONFIG_DIR=/tmp/autofix-fb-home\..*/.config/manicode$" "$FB/env.txt"
check "user mode: throwaway HOME removed" no_fbhome
rm -f "$R/keystore.properties"; reset_repo
mkdir -p "$T/home/bin"; cp "$FB/bin/freebuff" "$T/home/bin/freebuff"
rc=$(XPATH="$T/home/bin" ISO=user fbrun ok)
check "user mode: freebuff installed under the runner's HOME -> rc 4" test "$rc" = 4
rm -rf "$T/home/bin"; reset_repo

# ── Signing secrets in the tree (cash/mychef layout) ─────────────────────────
# clone-app.sh merges the passwords into local.properties and puts the release
# keystore in the project root, and lists both in $RUNNER_TEMP/autofix-secret-files.
LP=$'sdk.dir=/opt/sdk\nRELEASE_STORE_FILE=/w/cash-release.jks\nRELEASE_STORE_PASSWORD=lp-secret\nRELEASE_KEY_ALIAS=cash\nRELEASE_KEY_PASSWORD=lp-secret2'
secrets_layout() {
    printf '%s\n' "$LP" > "$R/local.properties"; echo "JKS-BYTES" > "$R/cash-release.jks"
    printf '%s\n' "$R/local.properties" "$R/cash-release.jks" > "$T/runner-temp/autofix-secret-files"
}
for iso in user same; do
    secrets_layout; rm -f "$FB/sudo.log"
    rc=$(ISO=$iso fbrun ok)
    check "secrets ($iso): rc 0" test "$rc" = 0
    check "secrets ($iso): local.properties keeps only sdk.dir during the run" test "$(cat "$FB/lp-during")" = "sdk.dir=/opt/sdk"
    check "secrets ($iso): release keystore out of the tree during the run" nott grep -qx cash-release.jks "$FB/cwd-ls.txt"
    check "secrets ($iso): local.properties restored byte for byte" test "$(cat "$R/local.properties")" = "$LP"
    check "secrets ($iso): release keystore restored" test "$(cat "$R/cash-release.jks" 2>/dev/null)" = JKS-BYTES
    check "secrets ($iso): nothing left in the driver's temp dir" nott bash -c 'ls -d "${TMPDIR:-/tmp}"/fbrun.* 2>/dev/null | grep -q .'
    rm -f "$R/local.properties" "$R/cash-release.jks"; reset_repo
done
rm -f "$T/runner-temp/autofix-secret-files"
# A listed file outside the project is left where it is (the HOME deny covers it).
echo "outside" > "$T/home/debug.keystore"; echo "$T/home/debug.keystore" > "$T/runner-temp/autofix-secret-files"
rc=$(ISO=user fbrun ok)
check "secrets: a listed file outside the project is not moved" test "$rc/$(cat "$T/home/debug.keystore")" = "0/outside"
rm -f "$T/runner-temp/autofix-secret-files" "$T/home/debug.keystore"; reset_repo

# ── What the agent leaves in .git is undone before the runner uses git ──────
printf '#!/bin/sh\nexit 0\n' > "$R/.git/hooks/post-merge"; chmod +x "$R/.git/hooks/post-merge"   # a legit hook
cfg_before=$(cat "$R/.git/config")
for iso in user same; do
    rm -f "$FB/pwned-fsmonitor" "$FB/pwned-hook"
    rc=$(ISO=$iso fbrun evilgit)
    check "evil .git ($iso): run still completes (rc $rc)" test "$rc" = 0
    check "evil .git ($iso): core.fsmonitor gone" test -z "$(env -u GIT_CONFIG_COUNT git -C "$R" config --get core.fsmonitor)"
    check "evil .git ($iso): .git/config is the snapshot" test "$(cat "$R/.git/config")" = "$cfg_before"
    check "evil .git ($iso): added hook removed" test ! -e "$R/.git/hooks/pre-commit"
    check "evil .git ($iso): existing hook kept" test -x "$R/.git/hooks/post-merge"
    check "evil .git ($iso): .git/info/attributes removed" test ! -e "$R/.git/info/attributes"
    check "evil .git ($iso): .git/commondir removed" test ! -e "$R/.git/commondir"
    # Without this shell's own hardening (8h exported it): the restore alone must hold.
    ( cd "$R" && env -u GIT_CONFIG_COUNT git status >/dev/null 2>&1
      env -u GIT_CONFIG_COUNT git -c user.email=t@t -c user.name=t commit -qam x >/dev/null 2>&1 )
    check "evil .git ($iso): the runner's git status/commit ran nothing" test ! -e "$FB/pwned-fsmonitor" -a ! -e "$FB/pwned-hook"
    git -C "$R" reset -q --hard "$base"; reset_repo
done
rm -f "$R/.git/hooks/post-merge"
cp -a "$R/.git" "$T/git-backup"
rc=$(ISO=user fbrun evilgitdir)
check "substitute .git: rc 4, a fixed reason" test "$rc/$(cat "$FB/result.reason" 2>/dev/null)" = "4/repository tampered by the agent"
check "substitute .git: disabled, git does not look further up" bash -c '[[ -f "$1/.git" ]] && ! git -C "$1" status >/dev/null 2>&1' _ "$R"
rm -rf "$R/.git"; cp -a "$T/git-backup" "$R/.git"; rm -rf "$T/git-backup"; reset_repo

# ── A symlinked result is refused (it would copy a runner file back) ─────────
printf 'VICTIM-SECRET\nFREEBUFF-DONE\n' > "$FB/victim"
for iso in user same; do
    rc=$(TMO=8 ISO=$iso fbrun symres)
    check "symlinked result ($iso): not done (rc $rc = 1, tree changed)" test "$rc" = 1
    check "symlinked result ($iso): no runner file content copied back" nott grep -q VICTIM "$FB/result"
    check "symlinked result ($iso): result path is no symlink" test ! -L "$FB/result"
    reset_repo
done

# ── A chown that fails half-way is still undone ─────────────────────────────
echo "$R" > "$FB/chown-fail"; rm -f "$FB/sudo.log"
rc=$(ISO=user fbrun ok)
check "partial chown: rc 4 (isolation setup failed)" test "$rc/$(cat "$FB/result.reason" 2>/dev/null)" = "4/isolation setup failed"
check "partial chown: chown back attempted anyway" grep -qx -- "-n chown -R $(id -u):$(id -g) $R" "$FB/sudo.log"
check "partial chown: ACLs removed" grep -qx -- "-n setfacl -x u:$FBU $T/home" "$FB/sudo.log"
check "partial chown: throwaway home removed" no_fbhome
rm -f "$FB/chown-fail"; reset_repo

# ── SIGTERM mid-run: handled at once, teardown complete ──────────────────────
echo "storePassword=ks-pass" > "$R/keystore.properties"; rm -f "$FB/sudo.log"
( POLL=60 TMO=120 ISO=user fbrun hang > "$T/bg-rc" ) &
bg=$!
for _ in $(seq 1 30); do grep -q "ready after" "$FB/run.out" 2>/dev/null && break; sleep 1; done
sleep 12   # past the startup naps: inside the 60 s poll
t_sig=$SECONDS
pkill -TERM -f "ci/freebuff-run.sh $R $FB/prompt"
wait "$bg"
el=$((SECONDS - t_sig))
check "SIGTERM: exits 143 promptly (${el}s < 10s, poll is 60s)" test "$(cat "$T/bg-rc")" = 143 -a "$el" -lt 10
check "SIGTERM: keystore.properties restored" grep -qx "storePassword=ks-pass" "$R/keystore.properties"
check "SIGTERM: project given back, ACLs removed" bash -c 'grep -qx -- "-n chown -R $(id -u):$(id -g) $2" "$1" && grep -qx -- "-n setfacl -x u:$3 $4" "$1"' _ "$FB/sudo.log" "$R" "$FBU" "$T/home"
check "SIGTERM: throwaway home removed" no_fbhome
rm -f "$R/keystore.properties"; reset_repo

# ── CI without the means to isolate: refuse, unless same-user is explicit ────
rc=0; env PATH="$FB/bin:$PATH" HOME="$T/home" GITHUB_ACTIONS=true FREEBUFF_SUDO=false FREEBUFF_CONFIG_DIR="$T/fbcfg" \
    AUTOFIX_FREEBUFF_BIN=freebuff bash "$ROOT/ci/freebuff-run.sh" "$R" "$FB/prompt" "$FB/result" > "$FB/run.out" 2>&1 || rc=$?
check "CI, no sudo, auto: rc 4 'isolation unavailable'" test "$rc/$(cat "$FB/result.reason" 2>/dev/null)" = "4/isolation unavailable"
rc=$(XENV="GITHUB_ACTIONS=true" SUDOCMD=false ISO=same fbrun ok)
check "CI, no sudo, FREEBUFF_ISOLATION=same: runs (rc 0)" test "$rc" = 0
reset_repo

rc=0; env -u CODEBUFF_API_KEY PATH="$FB/bin:$PATH" AUTOFIX_FREEBUFF_BIN=freebuff FREEBUFF_CONFIG_DIR="$T/nocreds" \
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
