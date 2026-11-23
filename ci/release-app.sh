#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# ci/release-app.sh — publish a release for one app whose fixes never shipped
#
# The backstop half of the ticket → fix → release loop. worker.sh releases in the
# same run it fixes, which covers the normal path; this covers every way that can
# fail: the run died after pushing, /release hit a transient error, or the fix
# happened in an environment with no signing material at all. mylock #15 was the
# last of those — fixed in the cloud on 2026-08-21, closed as completed, and
# never released, because CI could not sign and the Mac had no open issue left to
# act on.
#
# Expects the app already cloned into the workspace by ci/clone-app.sh.
#
# Usage:
#   AUTOFIX_WORKSPACE=/path/to/ws ci/release-app.sh apps/mylock.conf
###############################################################################

CONF_FILE="${1:?usage: release-app.sh <apps/*.conf>}"
[[ -f "$CONF_FILE" ]] || { echo "ERROR: no such conf: $CONF_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$CONF_FILE"
: "${APP_SLUG:?CONF: APP_SLUG is required}"
: "${BUGS_REPO:?CONF: BUGS_REPO is required}"

if [[ -n "${AUTOFIX_WORKSPACE:-}" ]]; then
    PROJECT_DIR="${AUTOFIX_WORKSPACE}/${APP_SLUG}"
elif [[ "$(uname)" != "Darwin" && -n "${PROJECT_DIR_CLOUD:-}" ]]; then
    PROJECT_DIR="$PROJECT_DIR_CLOUD"
fi
: "${PROJECT_DIR:?PROJECT_DIR could not be resolved}"

log() { echo "[release] [$APP_SLUG] $*"; }
die() { echo "[release] [$APP_SLUG] ERROR: $*" >&2; exit 1; }

[[ -d "$PROJECT_DIR/.git" ]] || die "no clone at $PROJECT_DIR — run ci/clone-app.sh first"

# Refuse to "release" with the CI placeholder. A release signed by a keystore that
# does not exist either fails deep inside packaging or ships something no device
# will accept as an update — worse than not releasing, because it looks done.
KS="$PROJECT_DIR/keystore.properties"
if [[ -f "$KS" ]] && grep -q '^storeFile=ci-placeholder.jks' "$KS"; then
    die "only a placeholder keystore is present — set ${APP_SLUG}_KEYSTORE_BASE64 to release this app"
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:$PATH"
unset CLAUDECODE  # prevent "nested session" when invoked from cron or a runner

# Claude out of quota: there is nothing to do until it is back, and failing here
# every hour would bury real failures. /release stays Claude-only (it signs and
# publishes); the Freebuff fallback is for fixes. lib/ai-provider.sh keeps the
# reset time, restored across runs by the workflow's cache.
AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/ai-provider.sh
source "$AGENT_DIR/lib/ai-provider.sh"
if ! claude_available; then
    ai_log "release deferred until Claude is back (blocked until $AI_BLOCKED_UNTIL)"
    exit 0
fi

before_tag=$(gh release view --repo "$BUGS_REPO" --json tagName -q .tagName 2>/dev/null || echo "")
log "current release: ${before_tag:-none} — invoking /release"

cd "$PROJECT_DIR" || die "cannot enter $PROJECT_DIR"
rel_exit=0
rel_out=$(mktemp)
"$AUTOFIX_CLAUDE_BIN" --dangerously-skip-permissions -p "/release" </dev/null > "$rel_out" 2>&1 || rel_exit=$?
cat "$rel_out"
if [[ $rel_exit -ne 0 ]] && reason=$(claude_limit_reason "$(tail -c 3000 "$rel_out")"); then
    rm -f "$rel_out"
    record_claude_limit "$reason"
    ai_log "Claude limit hit ($reason); Claude blocked until $AI_BLOCKED_UNTIL; release deferred"
    exit 0
fi
rm -f "$rel_out"
if [[ $rel_exit -ne 0 ]]; then
    die "/release exited $rel_exit — nothing was published"
fi

# An exit code proves the CLI ran, not that a release exists: /release aborts in
# its own pre-flight (missing keystore, tag already taken) and still exits 0.
after_tag=$(gh release view --repo "$BUGS_REPO" --json tagName -q .tagName 2>/dev/null || echo "")
if [[ -z "$after_tag" || "$after_tag" == "$before_tag" ]]; then
    die "no new release appeared — still at '${before_tag:-none}'"
fi

# A new tag is not a shippable release. `gh release create` with an asset
# attached creates a draft, uploads, and publishes only when the upload
# completes — so a killed or timed-out upload leaves the tag in place on a draft
# holding nothing. That is the worst possible outcome for an unattended run: it
# looks released, the loop reports success, and no device can install it. Seen
# for real on triviaapp v0.9.225, where a 13 MB APK outran the upload window.
draft=$(gh release view "$after_tag" --repo "$BUGS_REPO" --json isDraft -q .isDraft 2>/dev/null || echo "unknown")
assets=$(gh release view "$after_tag" --repo "$BUGS_REPO" --json assets -q '[.assets[].name] | length' 2>/dev/null || echo 0)

if [[ "$draft" != "false" ]]; then
    die "$after_tag exists but is a draft (isDraft=$draft) — the upload never finished, so nothing shipped"
fi
if [[ "${assets:-0}" -lt 1 ]]; then
    die "$after_tag is published but carries no assets — there is nothing for a device to download"
fi

log "released $after_tag with $assets asset(s) (was ${before_tag:-none})"
