#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# ci/freebuff-run.sh — run one Freebuff task headlessly
#
#   ci/freebuff-run.sh <project_dir> <prompt_file> <result_file>
#
# Freebuff (https://freebuff.com, the free ad-supported Codebuff agent) is the
# fallback while Claude is out of quota (lib/ai-provider.sh). It is a TUI with no
# print mode, so it is driven through tmux: start it in a detached session, paste
# the prompt, press Enter, and watch the pane for the states that need a key
# press. Completion is the agent writing its result file (OUTSIDE the repo)
# whose last line is FREEBUFF-DONE; it is copied to <result_file> (at most 64 KB,
# never through a symlink).
#
# Exit: 0 = done (result file complete), 1 = ran but did not finish and the tree
# changed, 4 = Freebuff unavailable (not installed, not logged in, allowance used
# up, servers unreachable, another session active and FREEBUFF_TAKEOVER=no, no
# isolation in CI, the agent tampered with .git, or no result and no change). The
# reason for a 4 is the last line of <result_file>.reason — always one of the
# FIXED strings passed to `unavailable` below (lib/ai-provider.sh accepts nothing
# else). Lines for the public status log (no content, ever) go to
# <result_file>.notice. Only short progress lines go to stdout; the full pane goes
# to $FREEBUFF_PANE_LOG (default <result_file>.pane), a withheld log: it contains
# the app's code.
#
# Secrets in the tree. Signing material that ci/clone-app.sh placed in the clone
# (it lists every such file in $AUTOFIX_SECRET_FILES, default
# $RUNNER_TEMP/autofix-secret-files), plus keystore.properties, local.properties
# and untracked *.jks/*.keystore near the root, are moved out of the tree for
# the session and put back afterwards. While it runs, local.properties keeps only
# its non-secret lines (sdk.dir, ...), other .properties files keep their keys
# with placeholder values (Gradle configuration still succeeds), tracked files
# show their committed content, keystores are absent. Both modes.
#
# Isolation (FREEBUFF_ISOLATION=auto|user|same, default auto):
#   user  Freebuff runs as a dedicated unprivileged account ($FREEBUFF_USER,
#         default autofix-fb; created once with useradd) with a throwaway HOME,
#         its own copy of the Freebuff config/credentials (600, owned by it) and a
#         clean `env -i` environment (plus JAVA_HOME / ANDROID_HOME /
#         ANDROID_SDK_ROOT and a gradle.properties holding only the runner's
#         org.gradle.java.home and jvmargs, so it can build; its Gradle cache
#         starts cold). The project is bind-mounted into that HOME and chowned to
#         the account for the duration (and back afterwards); the runner's HOME,
#         $RUNNER_TEMP and ~/.ssh get an explicit no-access ACL for it. So it
#         cannot READ the SSH key, the signing material, the runner's
#         GITHUB_ENV/GITHUB_PATH/GITHUB_OUTPUT files or anything else of the
#         runner user's. Its tmux server runs as that account too.
#         Afterwards everything the runner will act on is put back: .git/config,
#         .git/hooks and .git/info/attributes are restored from a snapshot, a
#         replaced .git is disabled (exit 4), modes are made usable again.
#         NOT a sandbox for the code the agent writes: the verification build
#         that follows runs it as the runner (as it does Claude's code).
#   same  Freebuff runs as the calling user with a scrubbed environment only (it
#         can read this user's files). Used locally (VM/Mac).
#   auto  Outside CI: same. In CI (GITHUB_ACTIONS=true): user, and when that is
#         impossible (no passwordless sudo, no setfacl) exit 4 "isolation
#         unavailable" — set FREEBUFF_ISOLATION=same explicitly to run unisolated.
#
# Knobs: FREEBUFF_TIMEOUT_MIN (60) / FREEBUFF_TIMEOUT_SEC: ONE deadline from the
# start of this script, covering the wait in line and the work. FREEBUFF_TAKEOVER
# (yes in CI, no elsewhere): press "Take over" when the account's session is in
# use elsewhere — that ENDS the other session (yours, if you use the same account
# interactively). FREEBUFF_MAX_CONTINUES (6), FREEBUFF_POLL_SEC (10),
# FREEBUFF_READY_MAX_SEC (120), FREEBUFF_UNREACHABLE_MAX_SEC (300),
# FREEBUFF_CHROME_POLLS (3), AUTOFIX_FREEBUFF_BIN (freebuff), FREEBUFF_USER,
# FREEBUFF_SUDO ("sudo -n"; tests substitute a fake), AUTOFIX_SECRET_FILES. The
# API key, if any, comes in as AUTOFIX_CODEBUFF_API_KEY (or CODEBUFF_API_KEY) and
# only Freebuff sees it.
###############################################################################

PROJECT="${1:?usage: freebuff-run.sh <project_dir> <prompt_file> <result_file>}"
PROMPT_FILE="${2:?prompt file required}"
RESULT="${3:?result file required}"
T0=$SECONDS
TIMEOUT_SEC="${FREEBUFF_TIMEOUT_SEC:-$(( ${FREEBUFF_TIMEOUT_MIN:-60} * 60 ))}"
DEADLINE=$((T0 + TIMEOUT_SEC))
MAX_CONTINUES="${FREEBUFF_MAX_CONTINUES:-6}"
POLL="${FREEBUFF_POLL_SEC:-10}"
READY_MAX="${FREEBUFF_READY_MAX_SEC:-120}"
UNREACHABLE_MAX="${FREEBUFF_UNREACHABLE_MAX_SEC:-300}"
CHROME_POLLS="${FREEBUFF_CHROME_POLLS:-3}"
FB_BIN="${AUTOFIX_FREEBUFF_BIN:-freebuff}"
PANE_LOG="${FREEBUFF_PANE_LOG:-$RESULT.pane}"
ISOLATION="${FREEBUFF_ISOLATION:-auto}"
FB_USER="${FREEBUFF_USER:-autofix-fb}"
read -ra SUDO <<< "${FREEBUFF_SUDO:-sudo -n}"
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then TAKEOVER="${FREEBUFF_TAKEOVER:-yes}"; else TAKEOVER="${FREEBUFF_TAKEOVER:-no}"; fi
SECRET_LIST="${AUTOFIX_SECRET_FILES:-${RUNNER_TEMP:+$RUNNER_TEMP/autofix-secret-files}}"
SENTINEL="FREEBUFF-DONE"
RESULT_MAX=65536
PANE_MAX=2000000

say() { echo "[freebuff-run] $*"; }
notice() { echo "$*" >> "$RESULT.notice"; say "$*"; }
# unavailable <fixed reason> [detail for the withheld log only]
unavailable() { echo "$1" >> "$RESULT.reason"; say "unavailable: $1${2:+ ($2)}"; exit 4; }
nap() { sleep "$1" & wait $!; }   # a signal is handled at once, not after the sleep

case "$RESULT" in /*) ;; *) unavailable "result file must be an absolute path" ;; esac
PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd -P)" || unavailable "no project dir"
case "$(cd "$(dirname "$RESULT")" && pwd -P)/" in
    "$PROJECT"/*) unavailable "result file must be outside the repo" ;;
esac
rm -f "$RESULT" "$RESULT.reason" "$RESULT.notice"

# ── A scrubbed environment ───────────────────────────────────────────────────
# The app's code goes to a third-party, ad-funded service. The agent gets no
# credential but its own: no GitHub/Bitbucket access, no Claude key, no signing
# keys, no mail password, no SSH agent, no handle on the Actions runner's command
# files (writing GITHUB_ENV/GITHUB_PATH would plant code in later steps). Done in
# this process, because a tmux session inherits the tmux SERVER's environment —
# hence the private server (-L) below, started from this scrubbed one. Repo
# .agents files and mcp.json are untrusted input: never --trust-agents, and the
# env switch for it is dropped. In user mode the agent's env is `env -i` anyway.
CB_KEY="${AUTOFIX_CODEBUFF_API_KEY:-${CODEBUFF_API_KEY:-}}"
RUNNER_HOME="$HOME"
RUNNER_TEMP_DIR="${RUNNER_TEMP:-}"
SRC_CFG="${FREEBUFF_CONFIG_DIR:-$HOME/.config/manicode}"
RUNNER_GRADLE_PROPS="${GRADLE_USER_HOME:-$HOME/.gradle}/gradle.properties"
if [[ "$ISOLATION" == "auto" ]]; then
    if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
        ISOLATION=same
    elif "${SUDO[@]}" true >/dev/null 2>&1 && command -v setfacl >/dev/null 2>&1; then
        ISOLATION=user
    else
        unavailable "isolation unavailable" "CI without passwordless sudo or setfacl; FREEBUFF_ISOLATION=same runs Freebuff unisolated"
    fi
fi
unset GH_TOKEN GITHUB_TOKEN APP_REPO_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN \
      CLAUDE_CODE_OAUTH_TOKEN SSH_AUTH_SOCK CODEBUFF_TRUST_AGENT_DIRS CODEBUFF_GITHUB_TOKEN TMUX \
      AUTOFIX_CODEBUFF_API_KEY CODEBUFF_API_KEY AUTOFIX_SECRET_FILES \
      GITHUB_ENV GITHUB_PATH GITHUB_OUTPUT GITHUB_STEP_SUMMARY GITHUB_STATE RUNNER_TEMP
for v in $(compgen -e); do
    case "$v" in
        ACTIONS_*|BITBUCKET_*|*_KEYSTORE_*|AUTOFIX_MAIL_*|*_TOKEN|*_SECRET|*_PASSWORD|*_PASS|*_API_KEY|*_KEY) unset "$v" ;;
    esac
done

command -v tmux >/dev/null 2>&1 || unavailable "tmux not installed"
FB_ABS=$(command -v "$FB_BIN" 2>/dev/null) || unavailable "freebuff not installed"
[[ "$SRC_CFG" == /* ]] || unavailable "FREEBUFF_CONFIG_DIR must be absolute"
if [[ -z "$CB_KEY" && ! -s "$SRC_CFG/credentials.json" ]]; then
    unavailable "not logged in" "no credentials.json and no CODEBUFF_API_KEY"
fi

ME_UID=$(id -u) ME_GID=$(id -g)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fbrun.XXXXXX"); chmod 700 "$WORK"
SOCK="autofix-fb-$$-$RANDOM"
S="fb"
FBHOME="" FBWORK="" MOUNTED="" UMOUNT_FAILED="" CHOWNED="" DENIED=() TORN_DOWN="" TAMPERED=""
SECRETS_LEFT="" SECRET_SRC=() GIT_SNAP="" GIT_INO="" GIT_HAD="" RES_IN=""
GITDIR="$PROJECT/.git"
head_start=$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null || echo "")

as_root() { "${SUDO[@]}" "$@"; }
# The runner's git, never running anything the agent left in .git.
rgit() { git -c core.fsmonitor=false -c core.hooksPath=/dev/null -C "$PROJECT" "$@"; }
under_project() { # <path> — its directory, resolved, is the project or inside it
    local d; d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
    case "$d/" in "$PROJECT"/*) return 0 ;; esac
    return 1
}

# ── Secrets out of the tree ──────────────────────────────────────────────────
SECRET_RE='(store|key|password|passwd|alias|secret|token)'
# props_redact drop|placeholder < file — lines whose KEY looks secret are dropped
# (local.properties: sdk.dir stays) or get the value ci-placeholder.
props_redact() {
    awk -v mode="$1" -v re="$SECRET_RE" '{
        if (match($0, /^[[:space:]]*[^=:#![:space:]]+[[:space:]]*[=:]/)) {
            k = substr($0, 1, RLENGTH); sub(/[[:space:]]*[=:]$/, "", k)
            if (tolower(k) ~ re) { if (mode == "placeholder") print k "=ci-placeholder"; next }
        }
        print
    }'
}
secret_candidates() {
    { [[ -n "$SECRET_LIST" && -f "$SECRET_LIST" ]] && cat "$SECRET_LIST"
      local f
      for f in keystore.properties local.properties app/keystore.properties app/local.properties; do
          echo "$PROJECT/$f"
      done
      find "$PROJECT" -maxdepth 2 -path "$PROJECT/.git" -prune -o -type f \( -name '*.jks' -o -name '*.keystore' \) -print 2>/dev/null
    } | awk 'NF && !seen[$0]++'
}
move_secrets_out() {
    local p rel n=0 tracked
    while IFS= read -r p; do
        [[ -f "$p" && ! -L "$p" ]] || continue
        under_project "$p" || continue
        p="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
        [[ " ${SECRET_SRC[*]+${SECRET_SRC[*]}} " == *" $p "* ]] && continue
        rel="${p#"$PROJECT"/}"
        tracked=""; rgit ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 && tracked=1
        # A committed keystore is in the history anyway; nothing to hide.
        [[ -n "$tracked" && "$p" != *.properties ]] && continue
        mv "$p" "$WORK/secret.$n" || continue
        SECRET_SRC[n]="$p"
        if [[ -n "$tracked" ]]; then
            rgit show "HEAD:$rel" > "$p" 2>/dev/null || true       # no deletion for `git add -A` to commit
        elif [[ "$(basename "$p")" == local.properties ]]; then
            props_redact drop < "$WORK/secret.$n" > "$p"
        elif [[ "$p" == *.properties ]]; then
            props_redact placeholder < "$WORK/secret.$n" > "$p"
        fi
        n=$((n + 1))
        say "secret file kept out of the tree for the session: $rel"
    done < <(secret_candidates)
}
restore_secrets() {
    local i p
    for i in ${SECRET_SRC[@]+"${!SECRET_SRC[@]}"}; do
        p="${SECRET_SRC[i]}"
        [[ -e "$WORK/secret.$i" ]] || continue
        mkdir -p "$(dirname "$p")" 2>/dev/null
        if ! under_project "$p"; then
            say "WARNING: $(dirname "$p") no longer lies inside the project; $(basename "$p") left in $WORK"
            SECRETS_LEFT=1; continue
        fi
        rm -rf -- "$p"
        mv -f "$WORK/secret.$i" "$p" || { say "WARNING: could not restore $p; left in $WORK"; SECRETS_LEFT=1; }
    done
}

# ── .git snapshot ────────────────────────────────────────────────────────────
# After the session the runner (holding every secret) runs git in this repo.
# What the agent may have left there to run as the runner — core.fsmonitor or
# any other command in .git/config, a hook, a filter in .git/info/attributes, a
# commondir pointing at another config, a whole substitute .git — is undone.
ino() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1" 2>/dev/null; }
snapshot_git() {
    [[ -d "$GITDIR" && ! -L "$GITDIR" && -f "$GITDIR/config" ]] || return 0
    GIT_INO=$(ino "$GITDIR")
    cp -p "$GITDIR/config" "$WORK/git-config" || return 0
    mkdir -p "$WORK/git-hooks"
    [[ -d "$GITDIR/hooks" && ! -L "$GITDIR/hooks" ]] && cp -a "$GITDIR/hooks/." "$WORK/git-hooks/"
    [[ -f "$GITDIR/info/attributes" ]] && cp -p "$GITDIR/info/attributes" "$WORK/git-attributes"
    local f
    for f in commondir config.worktree; do [[ -e "$GITDIR/$f" ]] && GIT_HAD+=" $f"; done
    GIT_SNAP=1
}
restore_git() {
    [[ -n "$GIT_SNAP" ]] || return 0
    local ino=""
    [[ -d "$GITDIR" && ! -L "$GITDIR" ]] && ino=$(ino "$GITDIR")
    if [[ "$ino" != "$GIT_INO" ]]; then
        # A substitute .git can carry anything. Disable it: a .git FILE pointing
        # nowhere makes every later git command here fail instead of looking up
        # the tree for another repository.
        TAMPERED=1
        say "WARNING: the agent replaced .git; repository disabled"
        rm -rf -- "$GITDIR"
        printf 'gitdir: /nonexistent/autofix-freebuff-tampered\n' > "$GITDIR"
        return 0
    fi
    local d f
    for d in hooks info; do [[ -L "$GITDIR/$d" || ( -e "$GITDIR/$d" && ! -d "$GITDIR/$d" ) ]] && rm -f -- "$GITDIR/$d"; done
    rm -rf -- "$GITDIR/config"; cp -p "$WORK/git-config" "$GITDIR/config"
    rm -rf -- "$GITDIR/hooks"; cp -a "$WORK/git-hooks" "$GITDIR/hooks"
    mkdir -p "$GITDIR/info"; rm -rf -- "$GITDIR/info/attributes"
    [[ -f "$WORK/git-attributes" ]] && cp -p "$WORK/git-attributes" "$GITDIR/info/attributes"
    for f in commondir config.worktree; do
        [[ " $GIT_HAD " == *" $f "* ]] || rm -rf -- "${GITDIR:?}/$f"
    done
}

# ── Result ───────────────────────────────────────────────────────────────────
# The result file is the agent's: read it as the agent (user mode) and never
# through a symlink, at most RESULT_MAX bytes.
read_res() {
    [[ -n "$RES_IN" ]] || return 1
    if [[ "$ISOLATION" == "user" ]]; then
        # shellcheck disable=SC2016
        "${SUDO[@]}" -u "$FB_USER" env -i PATH=/usr/bin:/bin sh -c \
            '[ -f "$1" ] && [ ! -L "$1" ] && head -c "$2" -- "$1"' _ "$RES_IN" "$RESULT_MAX" 2>/dev/null
    else
        [[ -f "$RES_IN" && ! -L "$RES_IN" ]] && head -c "$RESULT_MAX" -- "$RES_IN"
    fi
}
fetch_result() {
    if [[ "$ISOLATION" != "user" && -L "$RESULT" ]]; then
        say "WARNING: the result file is a symlink; refused"
        rm -f -- "$RESULT"; return 0
    fi
    local out
    out=$(read_res; echo x) ; out="${out%x}"
    rm -f -- "$RESULT"
    [[ -n "$out" ]] && printf '%s' "$out" > "$RESULT"
    return 0
}

kill_agent() {
    local i
    for i in 1 2 3 4 5; do
        as_root pkill -KILL -u "$FB_USER" >/dev/null 2>&1
        as_root pgrep -u "$FB_USER" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    say "WARNING: processes of $FB_USER survived pkill"
}

# Undo everything, in reverse order. Idempotent: called before the final verdict
# (the runner needs its project back to judge it) and from the EXIT trap. Never
# fails the run; a step that cannot be undone is reported.
teardown() {
    [[ -z "$TORN_DOWN" ]] || return 0
    TORN_DOWN=1
    if [[ "$ISOLATION" == "user" ]]; then
        kill_agent
        if [[ -n "$MOUNTED" ]]; then
            as_root umount "$FBWORK" >/dev/null 2>&1 || as_root umount -l "$FBWORK" >/dev/null 2>&1 \
                || { UMOUNT_FAILED=1; say "WARNING: could not unmount $FBWORK"; }
        fi
        if [[ -n "$CHOWNED" ]]; then
            as_root chown -R "$ME_UID:$ME_GID" "$PROJECT" || say "WARNING: could not give $PROJECT back to $(id -un)"
            # A mode 000 left by the agent must not break the runner's git push.
            as_root chmod -R u+rwX "$PROJECT" || say "WARNING: could not make $PROJECT writable again"
        fi
        local p
        for p in ${DENIED[@]+"${DENIED[@]}"}; do as_root setfacl -x "u:$FB_USER" "$p" >/dev/null 2>&1 || true; done
    fi
    restore_git
    restore_secrets
    fetch_result
}

STOPPED=""
stop_tmux() {
    [[ -z "$STOPPED" ]] || return 0
    STOPPED=1
    "${T[@]}" capture-pane -p -J -t "$S" -S -5000 2>/dev/null | head -c "$PANE_MAX" > "$WORK/pane" || true
    "${T[@]}" kill-server >/dev/null 2>&1 || true
}
finish() {
    trap '' TERM INT HUP          # a second signal must not cut the teardown short
    stop_tmux
    if [[ -n "${cred_before:-}" && "$(cred_hash)" != "$cred_before" ]]; then
        notice "Freebuff refreshed its credentials; update the FREEBUFF_CREDENTIALS secret if runs start failing to log in"
    fi
    teardown
    if [[ -s "$WORK/pane" ]]; then
        if [[ -L "$PANE_LOG" ]]; then say "WARNING: the pane log is a symlink; not written"
        else cat "$WORK/pane" > "$PANE_LOG" 2>/dev/null || true; fi
    fi
    if [[ -n "$FBHOME" ]]; then
        if [[ -n "$UMOUNT_FAILED" ]] || as_root mountpoint -q "$FBWORK" 2>/dev/null; then
            say "WARNING: $FBWORK is still mounted; $FBHOME not removed (it holds the project)"
        else
            as_root rm -rf --one-file-system "$FBHOME" >/dev/null 2>&1
        fi
    fi
    [[ -n "$SECRETS_LEFT" ]] || rm -rf "$WORK"
}
T=(true)
trap finish EXIT
trap 'exit 143' TERM INT HUP

snapshot_git
move_secrets_out

# ── Isolation ────────────────────────────────────────────────────────────────
if [[ "$ISOLATION" == "user" ]]; then
    fb_path=$(readlink -f "$FB_ABS")
    case "$fb_path/" in "$RUNNER_HOME"/*) unavailable "freebuff installed under the runner HOME" "install it globally (npm i -g); $FB_USER cannot read $RUNNER_HOME" ;; esac
    node_dir=$(dirname "$(readlink -f "$(command -v node 2>/dev/null || echo /usr/bin/node)")")
    FB_PATH="$node_dir:$(dirname "$fb_path"):$(dirname "$FB_ABS"):/usr/local/bin:/usr/bin:/bin"
    [[ -n "${JAVA_HOME:-}" ]] && FB_PATH="$JAVA_HOME/bin:$FB_PATH"
    command -v setfacl >/dev/null 2>&1 || unavailable "isolation unavailable" "setfacl not installed (apt-get install acl)"

    if ! id -u "$FB_USER" >/dev/null 2>&1; then
        as_root useradd --system --user-group --shell /bin/bash --home-dir /nonexistent --no-create-home "$FB_USER" \
            || unavailable "isolation setup failed" "could not create user $FB_USER"
    fi
    FBHOME=$(mktemp -d /tmp/autofix-fb-home.XXXXXX) || unavailable "isolation setup failed" "no temp dir"
    FBWORK="$FBHOME/work"
    mkdir -p "$FBHOME/.config/manicode" "$FBHOME/out" "$FBWORK" "$FBHOME/.gradle"
    # The agent binary Freebuff downloads (~140 MB), its helpers and settings, but
    # not this machine's session history.
    for f in "$SRC_CFG"/*; do
        [[ -f "$f" ]] || continue
        case "$(basename "$f")" in message-history.json|freebuff-live-*|last-fatal-crash.json) continue ;; esac
        cp -p "$f" "$FBHOME/.config/manicode/"
    done
    [[ -f "$FBHOME/.config/manicode/credentials.json" ]] && chmod 600 "$FBHOME/.config/manicode/credentials.json"
    if [[ -n "$CB_KEY" ]]; then (umask 077; printf '%s' "$CB_KEY" > "$FBHOME/.codebuff-key"); fi
    # Its commits carry the runner's identity; the repo is its own while it runs.
    {
        printf '[safe]\n\tdirectory = *\n[user]\n'
        printf '\tname = %s\n\temail = %s\n' "$(rgit config user.name || echo autofix)" \
            "$(rgit config user.email || echo autofix@localhost)"
    } > "$FBHOME/.gitconfig"
    # So it can build: the runner's JDK and heap settings, nothing else (the
    # runner's ~/.gradle may hold signing properties, and its caches sit behind
    # the HOME deny below, so dependencies download afresh).
    {
        jh=$(sed -n 's/^org\.gradle\.java\.home=//p' "$RUNNER_GRADLE_PROPS" 2>/dev/null | tail -1)
        jh="${jh:-${JAVA_HOME:-}}"
        [[ -n "$jh" ]] && printf 'org.gradle.java.home=%s\n' "$jh"
        grep -E '^org\.gradle\.jvmargs=' "$RUNNER_GRADLE_PROPS" 2>/dev/null | grep -viE "$SECRET_RE" | tail -1
    } > "$FBHOME/.gradle/gradle.properties"
    as_root chown -R "$FB_USER:$FB_USER" "$FBHOME" || unavailable "isolation setup failed" "could not hand the Freebuff home to $FB_USER"
    as_root chmod 700 "$FBHOME"
    # The runner reads the result as it appears and removes the dir afterwards.
    as_root setfacl -m "u:$(id -un):x" "$FBHOME" && as_root setfacl -m "u:$(id -un):rwx,d:u:$(id -un):rwx" "$FBHOME/out" \
        || unavailable "isolation setup failed" "could not set ACLs on the Freebuff home"

    # No access at all to the runner's HOME (which holds ~/.ssh and ~/.gradle,
    # and on hosted runners RUNNER_TEMP with the signing keys and the GITHUB_*
    # command files).
    for p in "$RUNNER_HOME" "$RUNNER_HOME/.ssh" "$RUNNER_TEMP_DIR"; do
        [[ -n "$p" && -e "$p" ]] || continue
        DENIED+=("$p")
        as_root setfacl -m "u:$FB_USER:---" "$p" || unavailable "isolation setup failed" "could not deny $FB_USER access to $p"
    done
    # Flags first: a chown or mount that fails half-way is still undone.
    CHOWNED=1
    as_root chown -R "$FB_USER:$FB_USER" "$PROJECT" || unavailable "isolation setup failed" "could not hand $PROJECT to $FB_USER"
    MOUNTED=1
    as_root mount --bind "$PROJECT" "$FBWORK" || unavailable "isolation setup failed" "could not bind-mount the project"
    AGENT_CWD="$FBWORK"
    RES_IN="$FBHOME/out/result.txt"
    FB_ENV=(HOME="$FBHOME" PATH="$FB_PATH" LANG=C.UTF-8 TERM=xterm-256color FREEBUFF_CONFIG_DIR="$FBHOME/.config/manicode")
    for v in JAVA_HOME ANDROID_HOME ANDROID_SDK_ROOT; do [[ -n "${!v:-}" ]] && FB_ENV+=("$v=${!v}"); done
    T=("${SUDO[@]}" -u "$FB_USER" env -i "${FB_ENV[@]}" tmux -L "$SOCK" -f /dev/null)
    cred_file="$FBHOME/.config/manicode/credentials.json"
    cred_hash() { as_root cat "$cred_file" 2>/dev/null | sha256sum | cut -c1-64; }
    # shellcheck disable=SC2016
    launch='[ -s "$HOME/.codebuff-key" ] && export CODEBUFF_API_KEY="$(cat "$HOME/.codebuff-key")"; '
    say "isolated: running as $FB_USER"
else
    say "WARNING: Freebuff runs as $(id -un) with a scrubbed environment only (no isolated user: not in CI or FREEBUFF_ISOLATION=same); it can read this user's files"
    AGENT_CWD="$PROJECT"
    RES_IN="$RESULT"
    T=(tmux -L "$SOCK" -f /dev/null)
    cred_file="$SRC_CFG/credentials.json"
    cred_hash() { sha256sum < "$cred_file" 2>/dev/null | cut -c1-64; }
    launch=""
    [[ -n "$CB_KEY" ]] && export CODEBUFF_API_KEY="$CB_KEY"
fi
cred_before=$(cred_hash)

# ── tmux ─────────────────────────────────────────────────────────────────────
tree_changed() {
    [[ "$(rgit rev-parse HEAD 2>/dev/null || echo "")" != "$head_start" ]] && return 0
    [[ -n "$(rgit status --porcelain -- . ':(exclude).autofix-logs' 2>/dev/null)" ]]
}
alive()     { "${T[@]}" has-session -t "$S" 2>/dev/null; }
pane()      { "${T[@]}" capture-pane -p -J -t "$S" 2>/dev/null; }
pane_all()  { "${T[@]}" capture-pane -p -J -t "$S" -S -5000 2>/dev/null; }
count()     { pane_all | grep -cF -- "$1"; }
send_line() { "${T[@]}" send-keys -t "$S" -l "$1"; nap 1; "${T[@]}" send-keys -t "$S" Enter; }
done_ok()   { [[ "$(read_res | grep -v '^[[:space:]]*$' | tail -1 | tr -d '[:space:]')" == "$SENTINEL" ]]; }
past_deadline() { [[ $SECONDS -ge $DEADLINE ]]; }

# The TUI's own lines (status bar, input box, modals) as opposed to the agent's
# transcript. In freebuff 0.2.x every transcript line — thinking, tool calls,
# tool output, the final message — is indented by at least two spaces, while
# the chrome starts at column 0/1 or with a box-drawing character. App code the
# agent prints ("Not logged in" in a string literal, say) is therefore never
# chrome. The right-hand scrollbar column is cut off first.
# The status bar's "Chat: <title>" is the start of the prompt (issue text): cut.
chrome() {
    sed -E 's/[[:space:]]*(▐|█|▌|▍|▎|▏|▕)+[[:space:]]*$//' \
        | grep -vE '^  ' \
        | sed -E -e 's/^(│|┃|╭|╮|╰|╯|─|━| )+//' -e 's/ · Chat: .*//' \
        | grep -v '^[[:space:]]*$'
}

# Strings from the freebuff 0.2.36 TUI (checked against the binary). Only the
# exact failure sentences: "0/5 hours remaining", "1h left · 12.1K (5%)",
# "May use data for AI training" and "Your first message starts the session."
# are normal screens.
LOGIN_RE='Press ENTER to login|Open this URL (in your browser )?to log ?in|Not logged in'
ALLOWANCE_RE="what's left today doesn't cover an hour|doesn't cover an hour of|share one daily allowance"
UNREACHABLE_RE="Can't reach (Freebuff|Codebuff)"
READY_TXT='Enter a coding task or / for commands'   # matched case-insensitively
TAKEOVER_TXT='Take over'

# The wrapper keeps the pane alive after freebuff exits, so its last screen is
# still there to capture and the exit is detectable. The absolute path: in user
# mode PATH starts with node's directory, which may hold another freebuff.
printf -v cmd '%s%q; echo "[freebuff exited rc=$?]"; sleep 86400' "$launch" "$FB_ABS"
"${T[@]}" new-session -d -s "$S" -x 220 -y 60 -c "$AGENT_CWD" "$cmd" \
    || unavailable "could not start tmux"
say "started (session $SOCK)"

takeovers=0
take_over() {
    [[ "$TAKEOVER" == "yes" ]] || unavailable "session in use elsewhere" "FREEBUFF_TAKEOVER=$TAKEOVER"
    takeovers=$((takeovers + 1))
    [[ $takeovers -gt 5 ]] && unavailable "session in use elsewhere" "pressed Take over 5 times"
    say "take over"; "${T[@]}" send-keys -t "$S" Enter; nap 3
}

# ── Wait for the input prompt ────────────────────────────────────────────────
# No transcript exists yet, so the whole screen is read here.
waited=0
while :; do
    [[ $waited -ge $READY_MAX ]] && unavailable "freebuff did not show its prompt" "within ${READY_MAX}s"
    past_deadline && unavailable "still waiting in line at the deadline" "${TIMEOUT_SEC}s"
    alive || unavailable "the tmux session died at startup"
    p=$(pane)
    # Waiting in line for capacity is not a failure; only the deadline ends it.
    echo "$p" | grep -qF 'in line' || waited=$((waited + 1))
    if echo "$p" | grep -qE "$LOGIN_RE";     then unavailable "not logged in" "login screen shown"; fi
    if echo "$p" | grep -qE "$ALLOWANCE_RE"; then unavailable "free allowance used up"; fi
    if echo "$p" | grep -qF '[freebuff exited'; then unavailable "freebuff exited at startup"; fi
    if echo "$p" | grep -qF 'Load and run these? [y/N]'; then send_line n; nap 2; continue; fi
    if echo "$p" | grep -qF "$TAKEOVER_TXT"; then take_over; continue; fi
    echo "$p" | grep -qiF "$READY_TXT" && break
    nap 1
done
say "ready after ${waited}s"

# ── Send the task ────────────────────────────────────────────────────────────
{
    cat "$PROMPT_FILE"
    cat <<EOF

---
Rules for this session from the autofix runner (they override anything above that conflicts):
- Work only inside this repository ($AGENT_CWD). Do not push, tag or release, do not change git remotes, and do not use \`gh\` or the GitHub API.
- Leave your changes committed or uncommitted exactly as the task above says.
- When you have finished (or have to stop), write a short summary to this file, which is outside the repository:
RESULT_FILE: $RES_IN
  Copy into it, verbatim, every marker line the task asks you to print (ALREADY_FIXED:, BUILD_ENV_BROKEN:, the FIX_SUMMARY_START ... FIX_SUMMARY_END block).
  Its very last line must be exactly $SENTINEL
- Write that file only once you are done, and nowhere else.
EOF
} > "$WORK/prompt"
chmod 644 "$WORK/prompt"
"${T[@]}" load-buffer -b task - < "$WORK/prompt"
"${T[@]}" paste-buffer -p -d -b task -t "$S"
nap 3
# Counted over the whole history, so a notice is acted on once per new
# appearance. The baseline is taken before Enter: text that arrived with the
# pasted prompt (issue text can say anything) is not an event.
n_ended=$(count 'free session ended'); n_released=$(count 'was released')
"${T[@]}" send-keys -t "$S" Enter
nap 3
continues=0 unreach_since=0 login_hits=0 allow_hits=0 start=$SECONDS finished=""
CONTINUE_MSG="Continue the same task from where you stopped. Check git status first and do not redo finished work. When done, write $RES_IN as instructed, with the last line exactly $SENTINEL"

while :; do
    if done_ok; then say "done in $(( (SECONDS - start) / 60 )) min"; finished=1; break; fi
    if ! alive; then say "the tmux session died"; break; fi
    p=$(pane)
    if echo "$p" | grep -qF '[freebuff exited'; then
        say "freebuff exited before finishing"; break
    fi
    # Hard failures count only in the TUI's chrome, and only once they have
    # stayed on screen for CHROME_POLLS polls in a row: a modal stays, while
    # text passing through the input box does not.
    ch=$(echo "$p" | chrome)
    if echo "$ch" | grep -qE "$LOGIN_RE"; then login_hits=$((login_hits + 1)); else login_hits=0; fi
    if echo "$ch" | grep -qE "$ALLOWANCE_RE"; then allow_hits=$((allow_hits + 1)); else allow_hits=0; fi
    [[ $login_hits -ge $CHROME_POLLS ]] && unavailable "logged out during the run"
    [[ $allow_hits -ge $CHROME_POLLS ]] && unavailable "free allowance used up"
    if echo "$ch" | grep -qE "$UNREACHABLE_RE"; then
        [[ $unreach_since -eq 0 ]] && unreach_since=$SECONDS
        [[ $((SECONDS - unreach_since)) -ge $UNREACHABLE_MAX ]] && unavailable "Freebuff servers unreachable" "${UNREACHABLE_MAX}s"
    else
        unreach_since=0
    fi
    # The TUI draws on the alternate screen, so "history" is the visible screen:
    # a notice can scroll away, so the count is tracked down as well as up.
    c=$(count 'free session ended')
    if [[ $c -le $n_ended ]]; then
        n_ended=$c
    else
        n_ended=$c
        if [[ $continues -ge $MAX_CONTINUES ]]; then say "free session ended $c times; giving up"; break; fi
        continues=$((continues + 1)); say "free session ended; continue #$continues"
        send_line "$CONTINUE_MSG"; nap 5
    fi
    # Chrome only: with FREEBUFF_TAKEOVER=no a "Take over" in app code must not end the run.
    echo "$ch" | grep -qF "$TAKEOVER_TXT" && take_over
    c=$(count 'was released')
    if [[ $c -gt $n_released ]]; then say "session released"; "${T[@]}" send-keys -t "$S" Enter; nap 3; fi
    n_released=$c
    if past_deadline; then say "timed out after ${TIMEOUT_SEC}s"; break; fi
    nap "$POLL"
done

# The project must be the runner's again before it can be judged. A finished
# run whose result does not survive the copy-back (symlink, vanished) is not done.
stop_tmux
teardown
[[ -n "$TAMPERED" ]] && unavailable "repository tampered by the agent"
if [[ -n "$finished" && -s "$RESULT" ]]; then exit 0; fi
# Did not finish. A changed tree means the agent worked and failed (a normal
# failed attempt); an untouched one means it never got going (no AI available).
if tree_changed; then exit 1; fi
unavailable "no result and no change in the repo" "timed out or stopped"
