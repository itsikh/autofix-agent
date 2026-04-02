#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# agent.sh — Unified autofix dispatcher
#
# Reads all apps/*.conf files, checks each registered app for open autofix
# issues (GitHub), then runs worker.sh for those apps in parallel batches.
#
# Usage:
#   ./agent.sh [--max-parallel N]
#
# Environment:
#   AUTOFIX_MAX_PARALLEL  default 3 (overridden by --max-parallel)
###############################################################################

export PATH="/opt/homebrew/bin:/Users/itsik-personal/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
unset CLAUDECODE  # prevent "nested session" error when run from cron

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_PARALLEL="${AUTOFIX_MAX_PARALLEL:-3}"

# Parse --max-parallel argument
while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-parallel) MAX_PARALLEL="$2"; shift 2 ;;
        *) shift ;;
    esac
done

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log()       { echo "[$(timestamp)] [agent] $*"; }

log "=== Agent run started (max-parallel=$MAX_PARALLEL) ==="

# ── Discover apps with open issues ───────────────────────────────────────────
declare -a pending_confs=()

shopt -s nullglob
for conf in "$AGENT_DIR/apps"/*.conf; do
    [[ -f "$conf" ]] || continue

    # Read required keys from conf without sourcing (avoids env pollution)
    APP_SLUG_V=$(grep -E '^APP_SLUG=' "$conf" | head -1 | cut -d= -f2- | tr -d '"')
    BUGS_REPO_V=$(grep -E '^BUGS_REPO=' "$conf" | head -1 | cut -d= -f2- | tr -d '"')
    CUSTOM_V=$(grep -E '^CUSTOM_SCRIPT=' "$conf" | head -1 | cut -d= -f2- | tr -d '"')

    if [[ -n "$CUSTOM_V" ]]; then
        # Custom scripts manage their own issue detection — always queue them
        log "${APP_SLUG_V:-$(basename "$conf" .conf)}: custom script — queued"
        pending_confs+=("$conf")
        continue
    fi

    if [[ -z "$BUGS_REPO_V" ]]; then
        log "$(basename "$conf"): missing BUGS_REPO — skipping"
        continue
    fi

    PROJECT_DIR_V=$(grep -E '^PROJECT_DIR=' "$conf" | head -1 | cut -d= -f2- | tr -d '"')

    # Quick check: any open autofix issues?
    count=$(gh issue list \
        --repo "$BUGS_REPO_V" \
        --state open \
        --label autofix \
        --json number \
        --limit 1 \
        2>/dev/null \
        | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null \
        || echo 0)

    if [[ "$count" -gt 0 ]]; then
        log "${APP_SLUG_V}: $count open issue(s) — queued"
        pending_confs+=("$conf")
    else
        log "${APP_SLUG_V}: no open issues — skipping"
        # Write heartbeat so watchdog knows this app is being checked regularly
        if [[ -n "$PROJECT_DIR_V" ]]; then
            mkdir -p "$PROJECT_DIR_V/.autofix-logs"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$APP_SLUG_V] No open issues — skipping." \
                >> "$PROJECT_DIR_V/.autofix-logs/autofix_$(date +%Y%m%d).log"
        fi
    fi
done

if [[ ${#pending_confs[@]} -eq 0 ]]; then
    log "No apps with open issues. Exiting."
    exit 0
fi

log "Processing ${#pending_confs[@]} app(s) in batches of $MAX_PARALLEL..."

# ── Run workers in parallel batches ──────────────────────────────────────────
any_failed=false
batch_pids=()
batch_apps=()

flush_batch() {
    local i=0
    for pid in "${batch_pids[@]+"${batch_pids[@]}"}"; do
        local app="${batch_apps[$i]:-?}"
        if wait "$pid"; then
            log "$app: worker completed successfully"
        else
            log "$app: worker exited with error"
            any_failed=true
        fi
        i=$((i + 1))
    done
    batch_pids=()
    batch_apps=()
}

for conf in "${pending_confs[@]}"; do
    APP_SLUG_V=$(grep -E '^APP_SLUG=' "$conf" | head -1 | cut -d= -f2- | tr -d '"')
    LOG_SLUG="${APP_SLUG_V:-$(basename "$conf" .conf)}"

    bash "$AGENT_DIR/worker.sh" "$conf" &
    pid=$!
    batch_pids+=("$pid")
    batch_apps+=("$LOG_SLUG")
    log "$LOG_SLUG: launched worker (PID $pid)"

    if [[ ${#batch_pids[@]} -ge $MAX_PARALLEL ]]; then
        flush_batch
    fi
done

flush_batch  # wait for any remaining workers

if [[ "$any_failed" == "true" ]]; then
    log "=== Agent run done — some workers failed ==="
    exit 1
fi

log "=== Agent run done — all workers succeeded ==="
exit 0
