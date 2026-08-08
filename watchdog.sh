#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# watchdog.sh — Registry-aware watchdog for autofix-agent
#
# Every 30 minutes (via cron):
#   1. Verify claude CLI is operational
#   2. Auto-discover projects from apps/*.conf, check log freshness & failures
#   3. Kill any worker running longer than MAX_AGE_MINUTES
#   4. Clean up ALL stale lock dirs (owner dead or killed)
#   5. Kill orphaned stuck sub-processes (git, gradlew)
#   6. Send macOS notification + write alerts log for unfixable problems
#
# Cron example:
#   */30 * * * * /path/to/autofix-agent/watchdog.sh >> /path/to/autofix-agent/logs/watchdog.log 2>&1
###############################################################################

export PATH="/opt/homebrew/bin:/Users/itsik-personal/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
unset CLAUDECODE  # prevent "nested session" error if launchctl has it set

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_AGE_MINUTES=90
LOG="$AGENT_DIR/logs/watchdog.log"
ALERTS_LOG="$AGENT_DIR/logs/alerts.log"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log()       { echo "[$(timestamp)] [watchdog] $*"; }

mkdir -p "$(dirname "$LOG")"

# ── Alerting ──────────────────────────────────────────────────────────────────
_alerts=()

alert() {
    local msg="$1"
    log "ALERT: $msg"
    echo "[$(timestamp)] $msg" >> "$ALERTS_LOG"
    _alerts+=("$msg")
}

notify_user() {
    local title="$1"
    local body="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    # 1. Play attention sound
    afplay /System/Library/Sounds/Basso.aiff 2>/dev/null || true

    # 2. Speak the alert (works from any shell context, no GUI needed)
    say "Autofix watchdog alert. ${title}. ${body}" 2>/dev/null || true

    # 3. Write alert file to Desktop — visible next time user looks at Finder
    local desktop_file="$HOME/Desktop/WATCHDOG_ALERT_$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "========================================"
        echo " AUTOFIX WATCHDOG ALERT"
        echo " $ts"
        echo "========================================"
        echo ""
        echo "$title"
        echo ""
        echo "$body"
        echo ""
        echo "Full details: $ALERTS_LOG"
        echo "========================================"
    } > "$desktop_file"
    log "Alert file written to Desktop: $desktop_file"
}

log "=== Watchdog check ==="

# ── Step 1: Verify claude CLI is operational ──────────────────────────────────
claude_out=$(claude --version 2>&1) || true
if [[ "$claude_out" != *"Claude Code"* ]]; then
    alert "claude CLI is not working — output: ${claude_out:-<empty>}"
else
    log "claude CLI: $claude_out"
fi

# ── Step 2: Per-project health checks (auto-discovered from apps/*.conf) ──────
now_seconds=$(date +%s)

shopt -s nullglob
for conf in "$AGENT_DIR/apps"/*.conf; do
    [[ -f "$conf" ]] || continue

    APP_SLUG_V=$(grep -E '^APP_SLUG=' "$conf" | head -1 | cut -d= -f2- | tr -d '"')
    PROJECT_DIR_V=$(grep -E '^PROJECT_DIR=' "$conf" | head -1 | cut -d= -f2- | tr -d '"')
    CRON_INTERVAL_V=$(grep -E '^CRON_INTERVAL=' "$conf" | head -1 | cut -d= -f2- | tr -d '"')
    ENABLED_V=$(grep -E '^ENABLED=' "$conf" | head -1 | cut -d= -f2- | tr -d '"')
    pname="${APP_SLUG_V:-$(basename "$conf" .conf)}"
    pinterval="${CRON_INTERVAL_V:-5}"

    # A disabled app stops receiving heartbeats, so its last log goes stale and
    # the freshness check below would alert "cron may be dead" every 30 minutes.
    if [[ "$ENABLED_V" == "false" ]]; then
        log "$pname: ENABLED=false — skipping health check"
        continue
    fi

    # Find the most recently modified log in the per-app log dir (worker writes
    # autofix_YYYYMMDD.log; legacy scripts wrote cron.log — accept either)
    plog=""
    if [[ -n "$PROJECT_DIR_V" && -d "$PROJECT_DIR_V/.autofix-logs" ]]; then
        plog=$(ls -t "$PROJECT_DIR_V/.autofix-logs/"*.log 2>/dev/null | head -1 || true)
    fi
    # Fallback: most recent agent-level wrapper run log
    if [[ -z "$plog" || ! -f "$plog" ]]; then
        plog=$(ls -t "$AGENT_DIR/logs/wrapper_run_"*.log 2>/dev/null | head -1 || true)
    fi
    if [[ -z "$plog" || ! -f "$plog" ]]; then
        log "$pname: no log file yet — skipping"
        continue
    fi

    # 2a. Log freshness
    last_mod=$(stat -f %m "$plog" 2>/dev/null || echo 0)
    age_minutes=$(( (now_seconds - last_mod) / 60 ))
    stale_threshold=$(( pinterval * 5 ))

    if [[ $age_minutes -gt $stale_threshold && $age_minutes -gt 20 ]]; then
        alert "$pname: log not updated for ${age_minutes}m (expected every ${pinterval}m) — cron may be dead"
        continue
    fi

    # 2b. Consecutive failures in last 40 log lines
    recent=$(tail -40 "$plog" 2>/dev/null || true)
    fail_count=$(echo "$recent" | grep -cE "exhausted|Giving up|ERROR.*meta-retries" || true)
    # Count real worker successes only — exclude heartbeat "No open issues" lines
    # which only mean there were no issues to process, not that a fix succeeded.
    ok_count=$(echo "$recent" | grep -cE "succeeded|completed|done.*fixed|issue.*fixed|Closed issue" || true)

    if [[ $fail_count -ge 3 && $ok_count -eq 0 ]]; then
        alert "$pname: $fail_count consecutive failures with 0 successes — script or config broken"
    elif [[ $fail_count -ge 3 ]]; then
        log "$pname: $fail_count failures / $ok_count successes (mixed — monitoring)"
    else
        log "$pname: ok ($ok_count successes, $fail_count errors in last 40 lines, log age ${age_minutes}m)"
    fi

    # 2c. Known error patterns
    if echo "$recent" | grep -qE "nested.*session|CLAUDECODE"; then
        alert "$pname: 'nested session' errors — CLAUDECODE env var may be set in launchctl"
    fi
    if echo "$recent" | grep -qE "grep.*invalid option.*P"; then
        alert "$pname: grep -P used — macOS grep doesn't support -P, change to -E"
    fi
    if echo "$recent" | grep -qE "git.*Authentication|Permission denied.*publickey|fatal.*repository"; then
        alert "$pname: git auth/repo error — SSH key or remote may need attention"
    fi
done

# ── Step 3: Parse elapsed time string into minutes ────────────────────────────
elapsed_to_minutes() {
    local etime="$1"
    local minutes=0
    if [[ "$etime" =~ ^([0-9]+)-([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        minutes=$(( (10#${BASH_REMATCH[1]} * 1440) + (10#${BASH_REMATCH[2]} * 60) + 10#${BASH_REMATCH[3]} ))
    elif [[ "$etime" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        minutes=$(( (10#${BASH_REMATCH[1]} * 60) + 10#${BASH_REMATCH[2]} ))
    elif [[ "$etime" =~ ^([0-9]+):([0-9]+)$ ]]; then
        minutes=$(( 10#${BASH_REMATCH[1]} ))
    fi
    echo "$minutes"
}

# ── Step 4: Kill stale autofix processes ──────────────────────────────────────
killed_pids=()

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pid=$(echo "$line" | awk '{print $1}')
    etime=$(echo "$line" | awk '{print $2}')
    cmd=$(echo "$line" | cut -d' ' -f3-)

    elapsed=$(elapsed_to_minutes "$etime")
    [[ $elapsed -lt $MAX_AGE_MINUTES ]] && continue

    log "STALE ($elapsed min): PID $pid — $cmd"
    pgid=$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d ' ')
    if [[ -n "$pgid" && "$pgid" != "0" && "$pgid" != "$$" ]]; then
        kill -- "-$pgid" 2>/dev/null && log "  Killed process group $pgid" || true
    fi
    kill "$pid" 2>/dev/null || true
    killed_pids+=("$pid")
    log "  Killed PID $pid"

done < <(ps -ax -o pid=,etime=,command= 2>/dev/null \
    | grep -E '(autofix[.-]|autofix\.sh|autofix-wrapper|worker\.sh|agent\.sh|wrapper\.sh)' \
    | grep -v grep \
    | grep -v " $$ " \
    | grep -v "watchdog")

[[ ${#killed_pids[@]} -gt 0 ]] && sleep 2

# ── Step 5: Clean ALL stale lock dirs ────────────────────────────────────────
# Discover from apps/*.conf + scan /tmp for any autofix lock dirs
declare -a all_locks=()

for conf in "$AGENT_DIR/apps"/*.conf; do
    [[ -f "$conf" ]] || continue
    APP_SLUG_V=$(grep -E '^APP_SLUG=' "$conf" | head -1 | cut -d= -f2- | tr -d '"')
    LOCK_SLUG_V=$(grep -E '^LOCK_SLUG=' "$conf" | head -1 | cut -d= -f2- | tr -d '"')
    slug="${LOCK_SLUG_V:-$APP_SLUG_V}"
    [[ -n "$slug" ]] && all_locks+=("/tmp/${slug}-autofix.lockdir")
done

shopt -u nullglob  # turn off nullglob before find — prevents ls/find getting no args

# Also scan /tmp for any autofix lock dirs not in registry
while IFS= read -r l; do
    all_locks+=("$l")
done < <(find /tmp -maxdepth 1 \( -name "*autofix*.lockdir" -o -name "*autofix*.lock" \) 2>/dev/null || true)

# Deduplicate via sort (bash 3.2 compatible — no associative arrays)
_lock_tmp=$(mktemp)
for l in "${all_locks[@]}"; do [[ -n "$l" ]] && echo "$l"; done > "$_lock_tmp"
find /tmp -maxdepth 1 \( -name "*autofix*.lockdir" -o -name "*autofix*.lock" \) 2>/dev/null >> "$_lock_tmp" || true

while IFS= read -r lock; do
    [[ -z "$lock" ]] && continue
    [[ -d "$lock" ]] || continue

    lock_pid=$(cat "$lock/pid" 2>/dev/null | tr -d '[:space:]' || echo "")
    if [[ -z "$lock_pid" ]]; then
        log "Lock $lock has no pid file — removing."
        rm -rf "$lock"
        continue
    fi

    if kill -0 "$lock_pid" 2>/dev/null; then
        pstate=$(ps -p "$lock_pid" -o stat= 2>/dev/null | tr -d ' ' || echo "")
        if [[ "$pstate" == T* || "$pstate" == Z* ]]; then
            log "Lock $lock owner PID $lock_pid is in state '$pstate' — removing."
            rm -rf "$lock"
        else
            lock_age_seconds=$(( now_seconds - $(stat -f %m "$lock" 2>/dev/null || echo "$now_seconds") ))
            lock_age_minutes=$(( lock_age_seconds / 60 ))
            if [[ $lock_age_minutes -gt 120 ]]; then
                log "Lock $lock held by PID $lock_pid for ${lock_age_minutes}m — force-removing."
                rm -rf "$lock"
            else
                log "Lock $lock: live PID $lock_pid (state=$pstate, age=${lock_age_minutes}m) — leaving."
            fi
        fi
    else
        log "Lock $lock owner PID $lock_pid is dead — removing."
        rm -rf "$lock"
    fi
done < <(sort -u "$_lock_tmp")
rm -f "$_lock_tmp"

# ── Step 6: Kill orphaned stuck sub-processes ─────────────────────────────────
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pid=$(echo "$line" | awk '{print $1}')
    etime=$(echo "$line" | awk '{print $2}')
    elapsed=$(elapsed_to_minutes "$etime")
    [[ $elapsed -lt $MAX_AGE_MINUTES ]] && continue
    ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ' || echo "")
    if [[ -n "$ppid" ]] && ! kill -0 "$ppid" 2>/dev/null; then
        log "Orphaned stuck process PID $pid (${elapsed}m): $(echo "$line" | cut -d' ' -f3-)"
        kill "$pid" 2>/dev/null && log "  Killed." || true
    fi
done < <(ps -ax -o pid=,etime=,command= 2>/dev/null \
    | grep -E '(git fetch|git push|gradlew)' \
    | grep -v grep)

# ── Step 7: Flush alerts as a single notification ─────────────────────────────
if [[ ${#_alerts[@]} -gt 0 ]]; then
    count=${#_alerts[@]}
    if [[ $count -eq 1 ]]; then
        notify_user "Autofix Watchdog" "${_alerts[0]}"
    else
        notify_user "Autofix Watchdog — $count issues" "${_alerts[0]} (+$((count - 1)) more — see alerts.log)"
    fi
    log "Sent notification: $count alert(s)"
fi

log "=== Watchdog done ==="
