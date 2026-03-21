#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# wrapper.sh — Meta-wrapper for agent.sh
#
# Runs agent.sh. If it exits non-zero, asks Claude to diagnose and fix the
# failure (stale lock, git divergence, script bug, etc.), then retries.
#
# This is the single file you point cron at:
#   */5 * * * * /path/to/autofix-agent/wrapper.sh >> /path/to/autofix-agent/logs/cron.log 2>&1
###############################################################################

export PATH="/opt/homebrew/bin:/Users/itsik-personal/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
unset CLAUDECODE  # prevent "nested session" error when run from cron

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SCRIPT="$AGENT_DIR/agent.sh"
LOG_DIR="$AGENT_DIR/logs"
MAX_META_RETRIES=2
MAX_RUN_SECONDS=7200  # 2-hour hard limit per full agent run

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log()       { echo "[$(timestamp)] [wrapper] $*"; }
log_err()   { echo "[$(timestamp)] [wrapper] ERROR: $*" >&2; }

mkdir -p "$LOG_DIR"

attempt=1
while [[ $attempt -le $((MAX_META_RETRIES + 1)) ]]; do
    log "=== Run attempt $attempt / $((MAX_META_RETRIES + 1)) ==="

    run_log="$LOG_DIR/wrapper_run_$(date +%Y%m%d_%H%M%S).log"

    bash "$AGENT_SCRIPT" > >(tee "$run_log") 2>&1 &
    agent_pid=$!
    (sleep "$MAX_RUN_SECONDS" && kill -- -"$agent_pid" 2>/dev/null; kill "$agent_pid" 2>/dev/null) &
    killer_pid=$!
    wait "$agent_pid"
    exit_code=$?
    kill "$killer_pid" 2>/dev/null
    wait "$killer_pid" 2>/dev/null

    if [[ $exit_code -eq 143 ]]; then
        log_err "agent.sh exceeded ${MAX_RUN_SECONDS}s hard limit — killed by timeout."
        exit_code=124
    fi

    if [[ $exit_code -eq 0 ]]; then
        log "agent.sh succeeded on attempt $attempt."
        exit 0
    fi

    if [[ $attempt -gt $MAX_META_RETRIES ]]; then
        log_err "All $MAX_META_RETRIES meta-retries exhausted. Giving up."
        exit 1
    fi

    log "agent.sh exited $exit_code on attempt $attempt — invoking Claude to diagnose..."

    error_context=$(tail -80 "$run_log" 2>/dev/null || echo "(no output captured)")

    fix_prompt="The autofix-agent script failed. Diagnose and fix the root cause so the next run succeeds.

Agent directory: $AGENT_DIR
Agent script: $AGENT_SCRIPT

--- Last 80 lines of output ---
$error_context
--- end of output ---

Common issues and how to fix them:

1. Stale lock at /tmp/<slug>-autofix.lockdir
   - Check the PID: cat /tmp/<slug>-autofix.lockdir/pid
   - Only remove the lock if that PID is dead or stopped:
     ps -p <pid> -o stat=
   - If stale: rm -rf /tmp/<slug>-autofix.lockdir

2. App conf file missing required vars (APP_SLUG, PROJECT_DIR, BUGS_REPO)
   - Check: ls $AGENT_DIR/apps/*.conf
   - Edit the offending conf file

3. Git not on main branch or auth error
   - Check: cd <PROJECT_DIR> && git status && git remote -v

4. Bug in worker.sh or agent.sh
   - Read $AGENT_DIR/worker.sh and $AGENT_DIR/agent.sh
   - Fix the bash logic (known pitfalls: PIPESTATUS swallowing, subshell exit codes)

Constraints: minimal changes only. Do not remove a live lock. All strings in English."

    log "Calling Claude to diagnose and fix..."
    claude --dangerously-skip-permissions -p "$fix_prompt" </dev/null 2>&1
    claude_exit=$?

    if [[ $claude_exit -ne 0 ]]; then
        log_err "Claude exited $claude_exit — retrying agent.sh anyway..."
    else
        log "Claude fix complete. Retrying agent.sh..."
    fi

    sleep 3
    attempt=$((attempt + 1))
done
