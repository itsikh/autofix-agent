#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# install.sh — One-time setup for autofix-agent
#
# Usage:
#   ./install.sh [--dry-run]
#
# What it does:
#   1. Makes all scripts executable
#   2. Adds a single cron entry for wrapper.sh (every 5 minutes)
#   3. Adds the watchdog cron entry (every 30 minutes)
#   4. Optionally removes legacy per-app autofix cron entries
###############################################################################

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        *) shift ;;
    esac
done

echo "=== autofix-agent install ==="
echo "Agent directory: $AGENT_DIR"
echo "Dry-run: $DRY_RUN"
echo ""

# ── Make scripts executable ────────────────────────────────────────────────────
for script in worker.sh agent.sh wrapper.sh watchdog.sh install.sh; do
    path="$AGENT_DIR/$script"
    if [[ -f "$path" ]]; then
        if [[ "$DRY_RUN" == "false" ]]; then
            chmod +x "$path"
            echo "chmod +x $path"
        else
            echo "[dry-run] chmod +x $path"
        fi
    fi
done
echo ""

# ── Cron entries to add ────────────────────────────────────────────────────────
WRAPPER_LOG="$AGENT_DIR/logs/cron.log"
WATCHDOG_LOG="$AGENT_DIR/logs/watchdog.log"

NEW_WRAPPER_ENTRY="*/5 * * * * $AGENT_DIR/wrapper.sh >> $WRAPPER_LOG 2>&1"
NEW_WATCHDOG_ENTRY="*/30 * * * * $AGENT_DIR/watchdog.sh >> $WATCHDOG_LOG 2>&1"

# ── Legacy entries to remove (per-app scripts being replaced) ──────────────────
LEGACY_PATTERNS=(
    "mychef/.claude/skills/autofix/autofix-wrapper.sh"
    "CallGuardEvidence/.claude/skills/autofix/autofix-wrapper.sh"
    "MedReminder/.claude/skills/autofix/autofix-wrapper.sh"
    "Anova/.claude/skills/autofix/autofix-wrapper.sh"
    "MyLock/.claude/skills/autofix/autofix-wrapper.sh"
    "SOSBlocker/.claude/skills/autofix/autofix-wrapper.sh"
    "triviaapp/scripts/claude-autofix-wrapper.sh"
    ".claude/watchdog/autofix-watchdog.sh"
)

echo "Current crontab:"
crontab -l 2>/dev/null || echo "(empty)"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] Would add cron entries:"
    echo "  $NEW_WRAPPER_ENTRY"
    echo "  $NEW_WATCHDOG_ENTRY"
    echo ""
    echo "[dry-run] Would remove legacy entries matching:"
    for p in "${LEGACY_PATTERNS[@]}"; do
        echo "  *$p*"
    done
    exit 0
fi

# ── Build new crontab ──────────────────────────────────────────────────────────
current=$(crontab -l 2>/dev/null || true)

# Remove legacy per-app entries
filtered="$current"
for pattern in "${LEGACY_PATTERNS[@]}"; do
    filtered=$(echo "$filtered" | grep -v "$pattern" || true)
done

# Remove any pre-existing autofix-agent entries (idempotent)
filtered=$(echo "$filtered" | grep -v "autofix-agent/wrapper.sh" | grep -v "autofix-agent/watchdog.sh" || true)

# Build new crontab
mkdir -p "$AGENT_DIR/logs"
new_crontab=""
if [[ -n "$filtered" ]]; then
    new_crontab="$filtered"$'\n'
fi
new_crontab+="$NEW_WRAPPER_ENTRY"$'\n'
new_crontab+="$NEW_WATCHDOG_ENTRY"

echo "$new_crontab" | crontab -

echo "New crontab installed:"
crontab -l
echo ""
echo "=== install complete ==="
echo ""
echo "To verify: crontab -l"
echo "To watch logs: tail -f $WRAPPER_LOG"
echo "To run now: $AGENT_DIR/agent.sh"
