#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# ci/clone-app.sh — Clone one registered app's code into the CI workspace
#
# Usage:
#   AUTOFIX_WORKSPACE=/path/to/ws ci/clone-app.sh apps/mylock.conf
#
# Reads CODE_REPO (clone URL, becomes "origin") and the optional
# CODE_REPO_MIRROR (added as a second remote, named after its host — "github" or
# "bitbucket" — so worker.sh's GIT_REMOTES="auto" and each app's own /release
# procedure both keep GitHub and Bitbucket in sync exactly as on the Mac).
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
    # Name the second remote after its HOST, not after its role. Every app's
    # /release instructions name the remotes its author created locally — mylock
    # and anova push to `github`, callguard to `bitbucket`, calcvault deliberately
    # to `origin` alone. A remote called "mirror" matches none of those, so a
    # cloud release would push its tag and commits to one host only and the other
    # would silently fall behind. Host names make each app's own procedure work
    # here unchanged, instead of rewriting ten release procedures to suit CI.
    case "$CODE_REPO_MIRROR" in
        *bitbucket.org*) MIRROR_REMOTE="bitbucket" ;;
        *github.com*)    MIRROR_REMOTE="github" ;;
        *)               MIRROR_REMOTE="mirror" ;;
    esac

    # A cached workspace may still carry the old name; one remote per URL, or
    # worker.sh and /release both push the same URL twice.
    if [[ "$MIRROR_REMOTE" != "mirror" ]] && git -C "$DEST" remote | grep -qx "mirror"; then
        git -C "$DEST" remote remove mirror || true
    fi

    if git -C "$DEST" remote | grep -qx "$MIRROR_REMOTE"; then
        git -C "$DEST" remote set-url "$MIRROR_REMOTE" "$CODE_REPO_MIRROR"
    else
        log "adding '$MIRROR_REMOTE' remote for $CODE_REPO_MIRROR"
        git -C "$DEST" remote add "$MIRROR_REMOTE" "$CODE_REPO_MIRROR"
    fi

    # Refuse to work on stale code. CODE_REPO and CODE_REPO_MIRROR are two views
    # of the same project, and worker.sh pushes to both — falling back to
    # --force-with-lease. If the mirror holds commits the clone lacks, fixing
    # here and pushing could overwrite them. buddy hit exactly this: its GitHub
    # mirror sat one release commit behind Bitbucket for months.
    if git -C "$DEST" fetch -q "$MIRROR_REMOTE" main 2>/dev/null; then
        ahead=$(git -C "$DEST" rev-list --count HEAD..FETCH_HEAD 2>/dev/null || echo 0)
        if [[ "${ahead:-0}" -gt 0 ]]; then
            echo "[clone] [$APP_SLUG] ERROR: $MIRROR_REMOTE is ${ahead} commit(s) ahead of CODE_REPO." >&2
            echo "[clone] [$APP_SLUG] Fixing here would build on stale code. Sync the two remotes first." >&2
            exit 1
        fi
        log "$MIRROR_REMOTE is in sync"
    else
        log "WARNING: could not fetch $MIRROR_REMOTE — skipping the staleness check"
    fi
fi

# ── Restore a missing Gradle wrapper jar ─────────────────────────────────────
# A repo that gitignores its wrapper jar builds fine on any machine that happens
# to have an untracked copy, and not at all on a fresh clone: ./gradlew dies with
# "Unable to access jarfile" before Gradle even starts. mylock and anova both did
# this (a blanket *.jar), and on 2026-08-21 it cost mylock #15 three fix attempts
# and a false "manual intervention required" — worker.sh read the broken wrapper
# as a broken fix. Both repos now commit the jar; this stays as the safety net for
# the next app that does not.
#
# The jar is effectively version-agnostic — it only reads distributionUrl out of
# gradle-wrapper.properties and downloads that distribution — so any recent one
# works. Never committed: worker.sh excludes gradle/wrapper from fix commits.
WJ="$DEST/gradle/wrapper/gradle-wrapper.jar"
WP="$DEST/gradle/wrapper/gradle-wrapper.properties"
if [[ ! -f "$WJ" ]]; then
    GRADLE_VER=$(sed -n 's|.*/gradle-\([0-9][0-9.]*\)-\(bin\|all\)\.zip.*|\1|p' "$WP" 2>/dev/null | head -1)
    log "WARNING: gradle-wrapper.jar is not in this repo — restoring it (distribution: ${GRADLE_VER:-unknown})"
    log "         Commit gradle/wrapper/gradle-wrapper.jar to make this unnecessary."

    # Preferred: the runner's own Gradle regenerates a matching wrapper set.
    if command -v gradle >/dev/null 2>&1; then
        if [[ -n "$GRADLE_VER" ]]; then
            (cd "$DEST" && gradle wrapper --gradle-version "$GRADLE_VER" -q) >/dev/null 2>&1 || true
        else
            (cd "$DEST" && gradle wrapper -q) >/dev/null 2>&1 || true
        fi
        [[ -f "$WJ" ]] && log "wrapper regenerated with the runner's gradle"
    fi

    # Fallback: pull a wrapper jar straight from the Gradle repo.
    if [[ ! -f "$WJ" ]]; then
        mkdir -p "$(dirname "$WJ")"
        for ref in "v${GRADLE_VER}.0" master; do
            [[ "$ref" == "v.0" ]] && continue
            if curl -fsSL --max-time 60 -o "$WJ" \
                "https://raw.githubusercontent.com/gradle/gradle/${ref}/gradle/wrapper/gradle-wrapper.jar"; then
                log "wrapper jar fetched from gradle/gradle@${ref}"
                break
            fi
            rm -f "$WJ"
        done
    fi

    if [[ ! -f "$WJ" ]]; then
        echo "[clone] [$APP_SLUG] ERROR: could not restore gradle-wrapper.jar — no build is possible." >&2
        echo "[clone] [$APP_SLUG] Commit gradle/wrapper/gradle-wrapper.jar to $CODE_REPO." >&2
        exit 1
    fi
    chmod +x "$DEST/gradlew" 2>/dev/null || true
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

# ── Placeholder keystore.properties ─────────────────────────────────────────
# Most apps read keystore.properties in app/build.gradle.kts but gitignore the
# file, so a fresh clone has no copy. Gradle then dies during CONFIGURATION
# ("null cannot be cast to non-null type kotlin.String"), which fails every
# task including assembleDebug.
#
# That failure is dangerous, not merely annoying: the agent sees a broken build,
# treats it as the bug, and "fixes" it by rewriting the release signing config —
# committing an unrequested change that makes release builds silently unsigned.
# A placeholder keeps configuration valid so the agent never sees the problem.
#
# Only written when absent, so an app that legitimately tracks the file (buddy)
# keeps its real one. Never committed: these repos already gitignore it.
KS="$DEST/keystore.properties"
if [[ ! -f "$KS" ]] && grep -rqs "keystore.properties" "$DEST/app/build.gradle.kts" "$DEST/build.gradle.kts" 2>/dev/null; then
    # When the workflow supplied this app's real signing material, install it: a
    # placeholder is enough to configure a debug build but cannot sign a release,
    # and an unsigned release is the difference between "bug fixed" and "bug fixed
    # and shipped". Both files are gitignored by these repos, and worker.sh also
    # excludes keystore.properties from fix commits, so neither is ever pushed.
    if [[ -n "${AUTOFIX_KEYSTORE_FILE:-}" && -f "${AUTOFIX_KEYSTORE_FILE}" \
       && -n "${AUTOFIX_KEYSTORE_PROPERTIES:-}" && -f "${AUTOFIX_KEYSTORE_PROPERTIES}" ]]; then
        # storeFile in the developer's copy is relative to the app module
        # (../<app>.jks). Rewrite it to where the workflow actually decoded the
        # keystore. Never echoed: the rest of the file is passwords.
        KS_ABS=$(cd "$(dirname "$AUTOFIX_KEYSTORE_FILE")" && pwd)/$(basename "$AUTOFIX_KEYSTORE_FILE")
        umask 077
        sed -E "s|^storeFile=.*|storeFile=${KS_ABS}|" "$AUTOFIX_KEYSTORE_PROPERTIES" > "$KS"
        if grep -q "^storeFile=${KS_ABS}$" "$KS"; then
            log "installed real signing keystore — release builds can be signed here"
        else
            # No storeFile line to rewrite; add one rather than leaving it unset,
            # which fails deep inside packaging with an opaque error.
            echo "storeFile=${KS_ABS}" >> "$KS"
            log "installed real signing keystore (storeFile appended)"
        fi
    else
        log "writing placeholder keystore.properties (no signing secret for this app — release will be skipped)"
        cat > "$KS" <<'KSEOF'
# Placeholder written by ci/clone-app.sh so Gradle configuration succeeds.
# No signing secret was supplied for this app, so only debug variants can be
# built here and worker.sh runs with RELEASE_MODE=none.
storeFile=ci-placeholder.jks
storePassword=ci-placeholder
keyAlias=ci-placeholder
keyPassword=ci-placeholder
KSEOF
    fi
fi

log "ready at $DEST"
