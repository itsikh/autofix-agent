#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# ci/clone-app.sh — Clone one registered app's code into the CI workspace
#
# Usage:
#   AUTOFIX_WORKSPACE=/path/to/ws ci/clone-app.sh apps/mylock.conf
#
# Reads CODE_REPO (clone URL, becomes "origin") and the optional
# CODE_REPO_MIRROR (added as a second remote so worker.sh's GIT_REMOTES="auto"
# keeps GitHub and Bitbucket in sync exactly as it does on the Mac).
#
# Credentials are never passed on the command line or written into .git/config:
# HTTPS uses the global credential helper configured by the workflow, and SSH
# uses the key the workflow installed at ~/.ssh/.
###############################################################################

CONF_FILE="${1:?usage: clone-app.sh <apps/*.conf>}"
[[ -f "$CONF_FILE" ]] || { echo "ERROR: no such conf: $CONF_FILE" >&2; exit 1; }

: "${AUTOFIX_WORKSPACE:?AUTOFIX_WORKSPACE must be set}"

# shellcheck disable=SC1090
source "$CONF_FILE"

: "${APP_SLUG:?CONF: APP_SLUG is required}"
: "${CODE_REPO:?CONF: CODE_REPO is required for CI runs}"

DEST="${AUTOFIX_WORKSPACE}/${APP_SLUG}"
mkdir -p "$AUTOFIX_WORKSPACE"

log() { echo "[clone] [$APP_SLUG] $*"; }

if [[ -d "$DEST/.git" ]]; then
    log "already present — fetching"
    git -C "$DEST" fetch origin --prune || exit 1
    git -C "$DEST" reset --hard origin/main || exit 1
else
    # Full clone, not shallow: worker.sh rebases onto origin/main and pushes,
    # which a shallow history cannot support reliably.
    log "cloning $CODE_REPO"
    git clone "$CODE_REPO" "$DEST" || exit 1
fi

if [[ -n "${CODE_REPO_MIRROR:-}" ]]; then
    if git -C "$DEST" remote | grep -qx "mirror"; then
        git -C "$DEST" remote set-url mirror "$CODE_REPO_MIRROR"
    else
        log "adding mirror remote"
        git -C "$DEST" remote add mirror "$CODE_REPO_MIRROR"
    fi
fi

# ── Neutralise Mac-only toolchain pins ───────────────────────────────────────
# Most projects commit a Mac Android Studio path in gradle.properties, and some
# commit a local.properties with a Mac sdk.dir. Both break on a Linux runner.
#
# These files are TRACKED, and worker.sh stages with `git add -u` / `git add -A`,
# so a plain edit would be committed and pushed back — replacing the Mac paths
# with Linux ones and breaking local runs. skip-worktree makes git ignore our
# edit entirely, so the fix stays confined to this runner.
neutralise() {
    local file="$1"
    git -C "$DEST" ls-files --error-unmatch "$file" >/dev/null 2>&1 || return 0
    git -C "$DEST" update-index --skip-worktree "$file" 2>/dev/null || true
}

GP="$DEST/gradle.properties"
if [[ -f "$GP" ]] && grep -qE '^org\.gradle\.java\.home=' "$GP"; then
    log "commenting out Mac org.gradle.java.home"
    sed -i.bak -E 's|^(org\.gradle\.java\.home=.*)$|# CI-disabled: \1|' "$GP"
    rm -f "$GP.bak"
    neutralise gradle.properties
fi

# sdk.dir in local.properties overrides ANDROID_HOME, so a stale Mac path wins
# over the runner's SDK. Point it at the runner's SDK instead.
LP="$DEST/local.properties"
if [[ -f "$LP" ]] && [[ -n "${ANDROID_HOME:-}" ]]; then
    if grep -qE '^sdk\.dir=' "$LP" && ! grep -qxF "sdk.dir=${ANDROID_HOME}" "$LP"; then
        log "repointing sdk.dir at $ANDROID_HOME"
        sed -i.bak -E "s|^sdk\.dir=.*$|sdk.dir=${ANDROID_HOME}|" "$LP"
        rm -f "$LP.bak"
        neutralise local.properties
    fi
fi

log "ready at $DEST"
