#!/usr/bin/env bash
# Offline end-to-end test of worker.sh while Claude is out of quota: the real
# worker against a fake `gh` (issues, labels, comments, releases recorded in a
# log), a fake Freebuff driver, a fake `claude` that must never be called, a
# local bare "origin" and BUILD_CMD=true. Checks:
#   - no AI (exit 4 from run_fix_agent): exit 0, no stuck label, no comment, no
#     retry, remaining tasks not tried, "no AI" reported once per Claude block;
#   - one Freebuff attempt per issue: a failed attempt is not retried and the
#     issue is left open without a stuck label, the next issue still gets one;
#   - a Freebuff fix is pushed and closed, and the release is deferred
#     (RELEASE_DEFERRED in the final line) without invoking Claude;
#   - ci/release-app.sh and the drift-scan hold defer while Claude is blocked.
set -uo pipefail
# Hermetic on an Actions runner too: nothing here may pick the real sudo or CI paths.
unset GITHUB_ACTIONS RUNNER_TEMP AUTOFIX_SECRET_FILES
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAKE="$T/fake"; mkdir -p "$FAKE/bin"
fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
nott() { ! "$@"; }
export TZ=UTC

# ── Fakes ────────────────────────────────────────────────────────────────────
cat > "$FAKE/bin/gh" <<'G'
#!/usr/bin/env bash
F="$(cd "$(dirname "$0")/.." && pwd)"; echo "gh $*" >> "$F/gh.log"
case "$1 $2" in
  "issue list")
    python3 -c 'import json,sys
closed = set(open(sys.argv[2]).read().split()) if len(sys.argv) > 2 else set()
print(json.dumps([i for i in json.load(open(sys.argv[1])) if str(i["number"]) not in closed]))' \
      "$F/issues.json" "$F/closed.txt" 2>/dev/null || cat "$F/issues.json" ;;
  "issue close") echo "$3" >> "$F/closed.txt" ;;
  "issue view")  echo '{"labels":[]}' ;;
  "label list")  echo '[{"name":"claude-active"},{"name":"autofix-stuck"},{"name":"autofix"}]' ;;
  "release view") echo "v1.0" ;;
esac
exit 0
G
cat > "$FAKE/claude" <<'C'
#!/usr/bin/env bash
echo x >> "$(dirname "$0")/claude-calls"; echo "fake claude must not run while blocked"; exit 1
C
# Driver: rc from fb-rc (0 = fix + result, 1 = changed but unfinished, 4 = unavailable).
cat > "$FAKE/freebuff-run" <<'D'
#!/usr/bin/env bash
F="$(dirname "$0")"; echo x >> "$F/fb-calls"
rc=$(cat "$F/fb-rc" 2>/dev/null || echo 0)
case $rc in
  4) echo "free allowance used up" > "$3.reason"; exit 4 ;;
  1) echo broken >> "$1/app.txt"; exit 1 ;;
esac
echo fixed >> "$1/app.txt"
printf 'FIX_SUMMARY_START\nfixed by fake freebuff\nFIX_SUMMARY_END\nFREEBUFF-DONE\n' > "$3"
D
chmod +x "$FAKE/bin/gh" "$FAKE/claude" "$FAKE/freebuff-run"

# ── App repo with a bare origin ──────────────────────────────────────────────
git init -q --bare -b main "$T/origin.git"
R="$T/ws/noaitest"; git init -q -b main "$R"
( cd "$R" && echo base > app.txt && printf '.autofix-logs/\n' > .gitignore && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm base && git remote add origin "$T/origin.git" && git push -q origin main )
git -C "$R" config user.email t@t; git -C "$R" config user.name t
cat > "$T/noaitest.conf" <<EOF
APP_SLUG=noaitest
BUGS_REPO=me/noaitest-bugs
LOCK_SLUG=noaitest-$$
BUILD_CMD=true
BUILD_ENV_CHECK_CMD=true
MAX_RETRIES=3
EOF

STATE="$T/state"; mkdir -p "$STATE"
export AUTOFIX_STATE_DIR="$STATE" AUTOFIX_WORKSPACE="$T/ws" AUTOFIX_PATH_PREPEND="$FAKE/bin"
export AUTOFIX_CLAUDE_BIN="$FAKE/claude" AUTOFIX_FREEBUFF_RUN="$FAKE/freebuff-run"
export AUTOFIX_NOW="$(date -u -d 2026-11-22T20:00:00Z +%s)"
issues() { python3 -c 'import json,sys; print(json.dumps([{"number":int(n),"title":"Bug %s"%n,"body":"b","labels":[{"name":"autofix"}]} for n in sys.argv[1:]]))' "$@" > "$FAKE/issues.json"; }
calls() { [[ -f "$FAKE/$1" ]] && wc -l < "$FAKE/$1" || echo 0; }
runw() { # -> rc; output in $T/w.out
    rm -f "$FAKE/gh.log" "$FAKE/closed.txt"; local rc=0
    bash "$ROOT/worker.sh" "$T/noaitest.conf" > "$T/w.out" 2>&1 || rc=$?
    echo "$rc"
}
block() { echo "2026-11-23T17:01Z" > "$STATE/claude-blocked-until"; }

# ── 1. Blocked, Freebuff unavailable: no AI ─────────────────────────────────
block; issues 11 12; echo 4 > "$FAKE/fb-rc"
rc=$(runw)
check "no AI: worker exits 0 (no red job every hour)" test "$rc" = 0
check "no AI: Freebuff tried once, second task not tried, no retries" test "$(calls fb-calls)" = 1
check "no AI: Claude never invoked" test "$(calls claude-calls)" = 0
check "no AI: no stuck label" nott grep -q -- "--add-label autofix-stuck" "$FAKE/gh.log"
check "no AI: no comment, no close" nott grep -qE "gh issue (comment|close)" "$FAKE/gh.log"
check "no AI: active label removed again" grep -q -- "issue edit 11 .*--remove-label claude-active" "$FAKE/gh.log"
check "no AI: warning status line" grep -q "\] No AI agent available: Claude blocked until 2026-11-23T17:01Z; free allowance used up" "$T/w.out"
check "no AI: not an ERROR line" nott grep -q "ERROR: .*AI" "$T/w.out"
check "no AI: first report for the block" grep -q "No AI this run: Claude blocked until 2026-11-23T17:01Z" "$T/w.out"
check "no AI: status-lines.sh carries it" bash -c 'bash "$1/ci/status-lines.sh" "$2" | grep -q "No AI agent available"' _ "$ROOT" "$T/w.out"
rc=$(runw)
check "no AI again, same block: exit 0, 'already reported' (the mail step skips it)" \
    bash -c '[[ $1 == 0 ]] && grep -q "already reported for the Claude block until 2026-11-23T17:01Z (no mail)" "$2"' _ "$rc" "$T/w.out"
echo "2026-11-24T09:01Z" > "$STATE/claude-blocked-until"
runw >/dev/null
check "no AI, new block: reported again" grep -q "No AI this run: Claude blocked until 2026-11-24T09:01Z" "$T/w.out"
rm -f "$FAKE/fb-calls"

# ── 2. One Freebuff attempt per issue ────────────────────────────────────────
# Scope "task": a neutral line, not "no AI" — no report, no mail flag used up.
block; issues 21 22; echo 1 > "$FAKE/fb-rc"; rm -f "$STATE"/no-ai-reported-*
rc=$(runw)
check "one attempt per issue: exit 0" test "$rc" = 0
check "one attempt per issue: exactly one Freebuff run per issue (2)" test "$(calls fb-calls)" = 2
check "one attempt per issue: no stuck label, no comment" nott grep -qE -- "--add-label autofix-stuck|gh issue comment" "$FAKE/gh.log"
check "one attempt per issue: neutral line for the task" grep -q "Freebuff already tried this task this run — left open for the next run" "$T/w.out"
check "one attempt per issue: not reported as 'No AI agent available' (the mail verdict)" nott grep -q "No AI agent available" "$T/w.out"
check "one attempt per issue: no 'No AI this run' report" nott grep -q "No AI this run" "$T/w.out"
check "one attempt per issue: the once-per-block mail flag is not used up" bash -c '! ls "$1"/no-ai-reported-* >/dev/null 2>&1' _ "$STATE"
check "one attempt per issue: tree back at the task commit" test -z "$(git -C "$R" status --porcelain)"
rm -f "$FAKE/fb-calls"

# ── 3. Freebuff fixes it; release deferred ───────────────────────────────────
block; issues 31; echo 0 > "$FAKE/fb-rc"
rc=$(runw)
check "Freebuff fix: exit 0" test "$rc" = 0
check "Freebuff fix: issue closed" grep -q "gh issue close 31" "$FAKE/gh.log"
check "Freebuff fix: pushed to origin" test "$(git -C "$T/origin.git" rev-parse main)" = "$(git -C "$R" rev-parse HEAD)"
check "Freebuff fix: close comment carries Freebuff's summary" grep -q "fixed by fake freebuff" "$FAKE/gh.log"
check "Freebuff fix: release deferred, Claude not invoked" \
    bash -c 'grep -q "AI-PROVIDER: release deferred until Claude is back" "$1" && [[ $(cat "$2" 2>/dev/null | wc -l) == 0 ]]' _ "$T/w.out" "$FAKE/claude-calls"
check "Freebuff fix: RELEASE_DEFERRED in the final line" grep -q "=== Worker done: 1 issue(s) fixed; release deferred until Claude is back ===" "$T/w.out"
check "Freebuff fix: no release FAILED" nott grep -q "Release FAILED" "$T/w.out"

# ── 4. ci/release-app.sh and the drift-scan hold ─────────────────────────────
block
rel=0; out=$(PATH="$FAKE/bin:$PATH" bash "$ROOT/ci/release-app.sh" "$T/noaitest.conf" 2>&1) || rel=$?
check "release-app: deferred while blocked, exit 0" bash -c '[[ $1 == 0 ]] && grep -q "release deferred until Claude is back" <<< "$2"' _ "$rel" "$out"
check "release-app: Claude not invoked" test "$(calls claude-calls)" = 0
# The drift-scan / scan jobs' check, verbatim from the workflow.
check "drift-scan hold: blocked -> held" nott bash -c 'cd "$1" && source lib/ai-provider.sh && claude_available' _ "$ROOT"
AUTOFIX_NOW=$(date -u -d 2026-11-23T17:05:00Z +%s) \
    check "drift-scan hold: after the reset -> released" bash -c 'cd "$1" && source lib/ai-provider.sh && claude_available' _ "$ROOT"

echo
if [[ $fails -eq 0 ]]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
