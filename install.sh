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
#   2. Adds a cron entry for wrapper.sh (every 5 minutes)
#   3. Installs watchdog as a LaunchAgent (every 30 min, GUI session — needed
#      for osascript alerts to reach the screen)
#   4. Removes legacy per-app autofix cron entries
###############################################################################

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
LAUNCHAGENT_PLIST="$HOME/Library/LaunchAgents/com.autofix.watchdog.plist"
LAUNCHAGENT_LABEL="com.autofix.watchdog"

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

# ── Make scripts executable ───────────────────────────────────────────────────
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

# ── Cron entry for wrapper.sh ─────────────────────────────────────────────────
WRAPPER_LOG="$AGENT_DIR/logs/cron.log"
NEW_WRAPPER_ENTRY="*/5 * * * * $AGENT_DIR/wrapper.sh >> $WRAPPER_LOG 2>&1"

# ── Legacy cron entries to remove ────────────────────────────────────────────
LEGACY_PATTERNS=(
    "mychef/.claude/skills/autofix/autofix-wrapper.sh"
    "CallGuardEvidence/.claude/skills/autofix/autofix-wrapper.sh"
    "MedReminder/.claude/skills/autofix/autofix-wrapper.sh"
    "Anova/.claude/skills/autofix/autofix-wrapper.sh"
    "MyLock/.claude/skills/autofix/autofix-wrapper.sh"
    "SOSBlocker/.claude/skills/autofix/autofix-wrapper.sh"
    "triviaapp/scripts/claude-autofix-wrapper.sh"
    ".claude/watchdog/autofix-watchdog.sh"
    "autofix-agent/watchdog.sh"   # watchdog moved to LaunchAgent
)

if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] Would add cron entry:"
    echo "  $NEW_WRAPPER_ENTRY"
    echo ""
    echo "[dry-run] Would install LaunchAgent: $LAUNCHAGENT_PLIST"
    echo "[dry-run] Would remove legacy cron entries matching:"
    for p in "${LEGACY_PATTERNS[@]}"; do echo "  *$p*"; done
    exit 0
fi

# ── Install crontab ───────────────────────────────────────────────────────────
current=$(crontab -l 2>/dev/null || true)
filtered="$current"
for pattern in "${LEGACY_PATTERNS[@]}"; do
    filtered=$(echo "$filtered" | grep -v "$pattern" || true)
done
filtered=$(echo "$filtered" | grep -v "autofix-agent/wrapper.sh" || true)

mkdir -p "$AGENT_DIR/logs"
new_crontab=""
[[ -n "$filtered" ]] && new_crontab="$filtered"$'\n'
new_crontab+="$NEW_WRAPPER_ENTRY"
echo "$new_crontab" | crontab -
echo "Crontab updated:"
crontab -l
echo ""

# ── Install watchdog LaunchAgent ──────────────────────────────────────────────
# Unload existing if present (ignore errors)
launchctl bootout "gui/$(id -u)/$LAUNCHAGENT_LABEL" 2>/dev/null || true
launchctl unload "$LAUNCHAGENT_PLIST" 2>/dev/null || true

mkdir -p "$(dirname "$LAUNCHAGENT_PLIST")"
cat > "$LAUNCHAGENT_PLIST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCHAGENT_LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$AGENT_DIR/watchdog.sh</string>
    </array>

    <key>StartInterval</key>
    <integer>1800</integer>

    <key>StandardOutPath</key>
    <string>$AGENT_DIR/logs/watchdog.log</string>

    <key>StandardErrorPath</key>
    <string>$AGENT_DIR/logs/watchdog.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/Users/itsik-personal/.local/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>

    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST_EOF

launchctl load "$LAUNCHAGENT_PLIST" 2>&1 && echo "LaunchAgent loaded: $LAUNCHAGENT_LABEL" \
    || echo "LaunchAgent plist written — run 'launchctl load $LAUNCHAGENT_PLIST' from Terminal to activate"

echo ""
echo "=== install complete ==="
echo ""
echo "To watch wrapper logs:  tail -f $AGENT_DIR/logs/cron.log"
echo "To watch watchdog logs: tail -f $AGENT_DIR/logs/watchdog.log"
echo "To run agent now:       $AGENT_DIR/agent.sh"
echo "To run watchdog now:    launchctl kickstart -k gui/\$(id -u)/$LAUNCHAGENT_LABEL"
