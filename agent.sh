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

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:$PATH"
unset CLAUDECODE  # prevent "nested session" error when run from cron

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# On Linux (cloud) default to 1 — one build at a time to stay within e2-micro RAM budget.
# On macOS default to 3 — Mac has plenty of RAM for parallel builds.
if [[ "${AUTOFIX_MAX_PARALLEL:-}" != "" ]]; then
    MAX_PARALLEL="$AUTOFIX_MAX_PARALLEL"
elif [[ "$(uname)" == "Darwin" ]]; then
    MAX_PARALLEL=3
else
    MAX_PARALLEL=1
fi

# Timeout wrapper for gh CLI calls (portable macOS, no coreutils needed)
GH_TIMEOUT="${GH_TIMEOUT:-120}"
run_with_timeout() {
    perl -e '
        my $timeout = shift @ARGV;
        my $pid = fork // die "fork: $!";
        if ($pid == 0) { exec @ARGV; die "exec: $!" }
        $SIG{ALRM} = sub { kill "TERM", $pid; waitpid($pid, 0); exit 124 };
        alarm $timeout;
        waitpid($pid, 0);
        alarm 0;
        exit ($? >> 8);
    ' "$GH_TIMEOUT" "$@"
}

# --list-json: discover apps with open issues, print their slugs as a JSON array
# and exit without running any workers. Used by CI to build a job matrix so that
# only apps with actual work get cloned.
LIST_JSON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-parallel) MAX_PARALLEL="$2"; shift 2 ;;
        --list-json)    LIST_JSON=true; shift ;;
        *) shift ;;
    esac
done

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
# In --list-json mode stdout must carry only the JSON array, so logs go to stderr.
log() {
    if [[ "$LIST_JSON" == "true" ]]; then
        echo "[$(timestamp)] [agent] $*" >&2
    else
        echo "[$(timestamp)] [agent] $*"
    fi
}

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
    CLOUD_SKIP_V=$(grep -E '^CLOUD_SKIP=' "$conf" | head -1 | cut -d= -f2- | tr -d '"')
    ENABLED_V=$(grep -E '^ENABLED=' "$conf" | head -1 | cut -d= -f2- | tr -d '"')

    # Registered but switched off — stays in apps/ so its config isn't lost.
    if [[ "$ENABLED_V" == "false" ]]; then
        log "${APP_SLUG_V:-$(basename "$conf" .conf)}: ENABLED=false — skipping"
        continue
    fi

    # --app <slug> / AUTOFIX_ONLY_APP restricts the run to a single app.
    if [[ -n "${AUTOFIX_ONLY_APP:-}" && "$APP_SLUG_V" != "${AUTOFIX_ONLY_APP}" ]]; then
        continue
    fi

    # Skip apps not supported on this host (e.g. Bitbucket-only apps on cloud)
    if [[ "$(uname)" != "Darwin" && "$CLOUD_SKIP_V" == "true" ]]; then
        log "${APP_SLUG_V:-$(basename "$conf" .conf)}: CLOUD_SKIP=true — not supported on this host"
        continue
    fi

    # --list-json feeds a CI matrix, and CI starts from an empty runner. An app
    # with no CODE_REPO cannot be cloned there, so it is Mac-only by definition —
    # skip it rather than queue a job that is guaranteed to fail. Checked before
    # the CUSTOM_SCRIPT branch below, which queues unconditionally.
    if [[ "$LIST_JSON" == "true" ]]; then
        CODE_REPO_V=$(grep -E '^CODE_REPO=' "$conf" | head -1 | cut -d= -f2- | tr -d '"')
        if [[ -z "$CODE_REPO_V" ]]; then
            log "${APP_SLUG_V:-$(basename "$conf" .conf)}: no CODE_REPO — local-only, not eligible for CI"
            continue
        fi
    fi

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

    # Quick check: any open autofix issues that nobody is already working on?
    #
    # Issues labelled claude-active are excluded. That label is how a run claims
    # an issue, and because it lives on GitHub it arbitrates across machines —
    # so the Mac cron and the GitHub Actions run never duplicate each other's
    # work. worker.sh applies the same filter when it builds its task list.
    count=$(run_with_timeout gh issue list \
        --repo "$BUGS_REPO_V" \
        --state open \
        --label autofix \
        --json number,labels \
        --limit 50 \
        2>/dev/null \
        | python3 -c "
import json, sys
issues = json.load(sys.stdin)
print(sum(1 for i in issues
          if 'claude-active' not in [l['name'] for l in i.get('labels', [])]))
" 2>/dev/null \
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

if [[ "$LIST_JSON" == "true" ]]; then
    # Emit a JSON array of slugs for a CI job matrix. Nothing but JSON on stdout.
    slugs=()
    for conf in "${pending_confs[@]:-}"; do
        [[ -n "$conf" ]] || continue
        s=$(grep -E '^APP_SLUG=' "$conf" | head -1 | cut -d= -f2- | tr -d '"')
        slugs+=("${s:-$(basename "$conf" .conf)}")
    done
    printf '%s\n' "${slugs[@]:-}" \
        | grep -v '^$' \
        | python3 -c "import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))"
    exit 0
fi

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
    [[ ${#batch_pids[@]} -eq 0 ]] && return
    for pid in "${batch_pids[@]}"; do
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
