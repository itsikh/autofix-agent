#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# worker.sh — Unified per-app autofix worker
#
# Reads all configuration from a .conf file passed as the first argument.
# Based on MyLock's autofix.sh (Gen3 reference), parameterized for any app.
#
# Usage:
#   ./worker.sh apps/mychef.conf
#
# Conf file variables (see apps/*.conf for examples):
#   Required: APP_SLUG, PROJECT_DIR, BUGS_REPO
#   Optional: LOCK_SLUG, GIT_REMOTES, PROMPT_FILE, RELEASE_MODE,
#             BUILD_TASK, MAX_RETRIES, CLAUDE_PROMPT_MODE, CUSTOM_SCRIPT,
#             ALLOW_BUILD_INFRA_EDITS
###############################################################################

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:$PATH"
unset CLAUDECODE  # prevent "nested session" error when run from cron

# Prevent git SSH/HTTP operations from hanging indefinitely
export GIT_SSH_COMMAND="ssh -o ConnectTimeout=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIME=30

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load configuration ────────────────────────────────────────────────────────
CONF_FILE="${1:-}"
if [[ -z "$CONF_FILE" || ! -f "$CONF_FILE" ]]; then
    echo "ERROR: Usage: $0 <path/to/app.conf>" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONF_FILE"

# Required vars
: "${APP_SLUG:?CONF: APP_SLUG is required}"
: "${BUGS_REPO:?CONF: BUGS_REPO is required}"

# PROJECT_DIR resolution, most specific first:
#   1. AUTOFIX_WORKSPACE  — ephemeral CI runner; repos are cloned to <ws>/<slug>
#   2. PROJECT_DIR_CLOUD  — long-lived Linux VM with repos under ~/dev
#   3. PROJECT_DIR        — the developer's Mac
if [[ -n "${AUTOFIX_WORKSPACE:-}" ]]; then
    PROJECT_DIR="${AUTOFIX_WORKSPACE}/${APP_SLUG}"
elif [[ "$(uname)" != "Darwin" && -n "${PROJECT_DIR_CLOUD:-}" ]]; then
    PROJECT_DIR="$PROJECT_DIR_CLOUD"
fi
: "${PROJECT_DIR:?CONF: PROJECT_DIR is required (set PROJECT_DIR_CLOUD for non-Mac hosts)}"

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "ERROR: PROJECT_DIR not found: $PROJECT_DIR — repo not cloned on this host?" >&2
    exit 1
fi

# Optional vars with defaults
LOCK_SLUG="${LOCK_SLUG:-$APP_SLUG}"
GIT_REMOTES="${GIT_REMOTES:-auto}"
PROMPT_FILE="${PROMPT_FILE:-android-default}"
RELEASE_MODE="${RELEASE_MODE:-skill}"
# Host-level override. CI has no signing keystore, so /release there bumps the
# version but cannot publish — leaving a version with no matching release.
# Releases belong on the Mac, where the real keystore lives.
[[ -n "${AUTOFIX_RELEASE_MODE:-}" ]] && RELEASE_MODE="$AUTOFIX_RELEASE_MODE"
BUILD_TASK="${BUILD_TASK:-assembleDebug}"
MAX_RETRIES="${MAX_RETRIES:-3}"
CLAUDE_PROMPT_MODE="${CLAUDE_PROMPT_MODE:-arg}"
# Build infrastructure is not app code. A fix that rewrites the Gradle wrapper or
# the toolchain pins is almost always an agent working around a broken runner, not
# a fix for the reported bug — see BUILD_INFRA_PATHSPECS below. Set true in a conf
# only for an app whose issues really are about its build.
ALLOW_BUILD_INFRA_EDITS="${ALLOW_BUILD_INFRA_EDITS:-false}"

# ── Custom script escape hatch ────────────────────────────────────────────────
if [[ -n "${CUSTOM_SCRIPT:-}" ]]; then
    if [[ ! -f "$CUSTOM_SCRIPT" ]]; then
        echo "ERROR: CUSTOM_SCRIPT '$CUSTOM_SCRIPT' not found" >&2
        exit 1
    fi
    exec bash "$CUSTOM_SCRIPT"
fi

# ── Derived configuration ─────────────────────────────────────────────────────
LOCK_DIR="/tmp/${LOCK_SLUG}-autofix.lockdir"
LOG_DIR="$PROJECT_DIR/.autofix-logs"
PROMPT_TEMPLATE="$AGENT_DIR/prompts/${PROMPT_FILE}.txt"

# Resolve JAVA_HOME: explicit env wins, then OS-specific defaults
if [[ -n "${JAVA_HOME:-}" && -d "${JAVA_HOME}" ]]; then
    JAVA_HOME_PATH="${JAVA_HOME}"
elif [[ "$(uname)" == "Darwin" ]]; then
    JAVA_HOME_PATH="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
else
    # Linux: follow the java symlink back to the JDK root
    _java_bin="$(command -v java 2>/dev/null || true)"
    if [[ -n "$_java_bin" ]]; then
        JAVA_HOME_PATH="$(readlink -f "$_java_bin" | sed 's|/bin/java$||')"
    else
        JAVA_HOME_PATH="$(ls -d /usr/lib/jvm/temurin-17* /usr/lib/jvm/java-17* 2>/dev/null | grep -v jre | sort | tail -1 || echo "/usr/lib/jvm/default-java")"
    fi
fi
ACTIVE_LABEL="claude-active"
AUTOFIX_LABEL="autofix"
# Survives the run, unlike ACTIVE_LABEL. An issue the agent could not fix used to
# end a run looking untouched — the active label is stripped on the way out and the
# only trace was a comment. This label is the durable "the agent tried and failed"
# marker, and it is what gates the failure comment to a second consecutive failure.
STUCK_LABEL="autofix-stuck"
WORK_TMP=""
BUILD_ENV_ERROR=""
RELEASE_FAILED=false

# Paths git must not stage as part of a fix. When mylock's wrapper jar was missing
# from the repo, Claude repaired the wrapper on the runner to get a build at all,
# and `git add -A` committed gradlew, gradlew.bat and gradle-wrapper.properties
# into the fix for issue #15 (c4a08f7) — churn with no relation to the bug, from a
# newer Gradle than the project uses. Excluded unless a conf opts in.
BUILD_INFRA_PATHSPECS=(
    ':(exclude)gradlew'
    ':(exclude)gradlew.bat'
    ':(exclude)gradle/wrapper'
    ':(exclude)gradle.properties'
    ':(exclude)local.properties'
    ':(exclude)keystore.properties'
)

if [[ ! -f "$PROMPT_TEMPLATE" ]]; then
    echo "ERROR: Prompt template not found: $PROMPT_TEMPLATE" >&2
    exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log()       { echo "[$(timestamp)] [$APP_SLUG] $*"; }
log_error() { echo "[$(timestamp)] [$APP_SLUG] ERROR: $*" >&2; }

# Timeout wrapper for commands that may hang (e.g. gh CLI network calls).
# Uses perl alarm signal — portable on macOS without coreutils.
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

cleanup() {
    rm -rf "$LOCK_DIR"
    [[ -n "$WORK_TMP" ]] && rm -rf "$WORK_TMP"
    log "Lock released, exiting."
}

# ── Lock Management ───────────────────────────────────────────────────────────
write_lock_info() {
    echo $$ > "$LOCK_DIR/pid"
    ps -p $$ -o lstart= > "$LOCK_DIR/lstart" 2>/dev/null || true
}

is_lock_holder_alive() {
    local old_pid
    old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    [[ -z "$old_pid" ]] && return 1
    kill -0 "$old_pid" 2>/dev/null || return 1
    local pstate
    pstate=$(ps -p "$old_pid" -o stat= 2>/dev/null || echo "")
    [[ "$pstate" == T* ]] && return 1
    local old_lstart current_lstart
    old_lstart=$(cat "$LOCK_DIR/lstart" 2>/dev/null || echo "")
    if [[ -n "$old_lstart" ]]; then
        current_lstart=$(ps -p "$old_pid" -o lstart= 2>/dev/null || echo "")
        [[ "$old_lstart" != "$current_lstart" ]] && return 1
    fi
    return 0
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        write_lock_info
        trap cleanup EXIT
        log "Lock acquired (PID $$)."
        return
    fi
    if is_lock_holder_alive; then
        local old_pid
        old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "?")
        log_error "Another instance is running (PID $old_pid). Exiting."
        exit 0
    fi
    local old_pid
    old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "?")
    log "Stale lock (PID $old_pid). Removing."
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        write_lock_info
        trap cleanup EXIT
        log "Lock acquired (PID $$)."
    else
        log_error "Failed to acquire lock after stale removal. Exiting."
        exit 1
    fi
}

# ── Git Helpers ───────────────────────────────────────────────────────────────
get_remotes() {
    local list
    if [[ "$GIT_REMOTES" == "auto" ]]; then
        list=$(git remote 2>/dev/null || true)
    else
        list=$(echo "$GIT_REMOTES" | tr ' ,' '\n' | grep -v '^$' || true)
    fi
    # One remote per URL. A repo with two names for the same URL would be pushed
    # to twice; the second reports "Everything up-to-date", which reads exactly
    # like a real push in the log, and a genuine failure would be counted twice.
    local r url seen=""
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        url=$(git remote get-url "$r" 2>/dev/null || echo "$r")
        case " $seen " in
            *" $url "*) continue ;;
        esac
        seen="$seen $url"
        echo "$r"
    done <<< "$list"
}

push_to_remote() {
    local remote="$1"
    if git push "$remote" main 2>/dev/null; then
        return 0
    fi
    log "Fast-forward push to $remote rejected — retrying with --force-with-lease..."
    local err
    err=$(git push "$remote" main --force-with-lease 2>&1) || \
        log_error "Could not push to $remote: $err"
}

verify_git_state() {
    cd "$PROJECT_DIR"
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)
    if [[ "$branch" != "main" ]]; then
        log_error "Not on main branch (on '$branch'). Exiting."
        exit 1
    fi
    if ! git diff --quiet || ! git diff --cached --quiet; then
        log "Working tree has uncommitted changes. Auto-committing..."
        git add -u -- . ':(exclude).autofix-logs'
        git commit -m "autofix: auto-commit pending changes before run" || true
    fi
    while IFS= read -r remote; do
        [[ -z "$remote" ]] && continue
        git fetch "$remote" 2>/dev/null || true
    done < <(get_remotes)
    local origin_ahead
    origin_ahead=$(git rev-list HEAD..origin/main --count 2>/dev/null || echo 0)
    if [[ "$origin_ahead" -gt 0 ]]; then
        log "origin/main is $origin_ahead commit(s) ahead — rebasing..."
        git rebase origin/main 2>/dev/null || {
            git rebase --abort 2>/dev/null || true
            git merge --no-edit origin/main 2>/dev/null || true
        }
    fi
    while IFS= read -r remote; do
        [[ -z "$remote" ]] && continue
        push_to_remote "$remote"
    done < <(get_remotes)
    log "Git state verified."
}

# ── JSON helper ───────────────────────────────────────────────────────────────
run_py() {
    local json_file="$1"; shift
    python3 -c "$*" "$json_file"
}

# ── Label Management ──────────────────────────────────────────────────────────
ensure_label_exists() {
    local label color desc
    for label_spec in "${ACTIVE_LABEL}:F9D0C4:Autofix agent is actively working on this issue" \
                       "${STUCK_LABEL}:B60205:Autofix agent tried and could not fix this issue" \
                       "${AUTOFIX_LABEL}:0E8A16:Issue approved for automatic fixing by the autofix agent"; do
        label="${label_spec%%:*}"
        color="${label_spec#*:}"; color="${color%%:*}"
        desc="${label_spec##*:}"
        if ! run_with_timeout gh label list --repo "$BUGS_REPO" --search "$label" --json name \
            | python3 -c "import sys,json; sys.exit(0 if any(l['name']=='$label' for l in json.load(sys.stdin)) else 1)" 2>/dev/null; then
            run_with_timeout gh label create "$label" --repo "$BUGS_REPO" --description "$desc" --color "$color" 2>/dev/null || true
            log "Created label '$label'"
        fi
    done
}

label_task_active() {
    local task_file="$1"
    while IFS= read -r num; do
        run_with_timeout gh issue edit "$num" --repo "$BUGS_REPO" --add-label "$ACTIVE_LABEL" 2>/dev/null || true
    done < <(run_py "$task_file" 'import json,sys
with open(sys.argv[1]) as f: issues=json.load(f)
for i in issues: print(i["number"])')
}

unlabel_task_active() {
    local task_file="$1"
    while IFS= read -r num; do
        run_with_timeout gh issue edit "$num" --repo "$BUGS_REPO" --remove-label "$ACTIVE_LABEL" 2>/dev/null || true
    done < <(run_py "$task_file" 'import json,sys
with open(sys.argv[1]) as f: issues=json.load(f)
for i in issues: print(i["number"])')
}

# ── Issue Fetching & Grouping ─────────────────────────────────────────────────
fetch_and_group_issues() {
    local tmp_issues="$WORK_TMP/issues.json"
    local _gh_attempt _gh_max=3
    for _gh_attempt in 1 2 3; do
        # Require BOTH a clean exit AND valid JSON: a mid-stream network timeout
        # can leave gh exiting 0 with a truncated array in $tmp_issues, which
        # would otherwise crash the unguarded parser below.
        if run_with_timeout gh issue list --repo "$BUGS_REPO" --state open --label "$AUTOFIX_LABEL" --json number,title,body,labels --limit 100 > "$tmp_issues" \
            && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp_issues" 2>/dev/null; then
            break
        fi
        if [[ $_gh_attempt -lt $_gh_max ]]; then
            # NOTE: this function's stdout is captured into $tasks_file by the
            # caller, so diagnostic logging MUST go to stderr — otherwise the
            # log line is prepended to the JSON and crashes the parser.
            log "GitHub API error or invalid response on issue list (attempt $_gh_attempt/$_gh_max) — retrying in 15s..." >&2
            sleep 15
        else
            log_error "GitHub API unavailable after $_gh_max attempts — aborting."
            return 1
        fi
    done

    local count
    count=$(run_py "$tmp_issues" 'import json,sys
with open(sys.argv[1]) as f: print(len(json.load(f)))')

    if [[ "$count" == "0" ]]; then
        echo "[]"
        return
    fi

    run_py "$tmp_issues" '
import json, sys
with open(sys.argv[1]) as f:
    issues = json.load(f)

ACTIVE = "claude-active"
issues = [i for i in issues if ACTIVE not in [l["name"] for l in i.get("labels", [])]]

groups = {}
standalone = []
for issue in issues:
    labels = [l["name"] for l in issue.get("labels", [])]
    story_label = next((l for l in labels if l.startswith("story:")), None)
    if story_label:
        groups.setdefault(story_label, []).append(issue)
    else:
        standalone.append(issue)

tasks = list(groups.values())
for issue in standalone:
    tasks.append([issue])
print(json.dumps(tasks))
'
}

# ── Prompt Building ───────────────────────────────────────────────────────────
format_issues_for_prompt() {
    local task_file="$1"
    run_py "$task_file" '
import json, sys
with open(sys.argv[1]) as f:
    issues = json.load(f)
parts = []
for issue in issues:
    number = issue["number"]
    title = issue["title"]
    body = issue.get("body", "") or ""
    labels = ", ".join(l["name"] for l in issue.get("labels", []))
    part = f"### Issue #{number}: {title}\n"
    if labels:
        part += f"Labels: {labels}\n"
    part += f"\n{body}\n"
    parts.append(part)
print("\n---\n".join(parts))
'
}

build_prompt() {
    local issues_desc="$1"
    local retry_context="$2"

    local prompt
    prompt=$(cat "$PROMPT_TEMPLATE")
    prompt="${prompt/\{\{ISSUES\}\}/$issues_desc}"

    if [[ -n "$retry_context" ]]; then
        local retry_block="## Previous Attempt Failed

The previous fix attempt failed with the following error. Please analyze the error and try a different approach:

\`\`\`
$retry_context
\`\`\`"
        prompt="${prompt/\{\{RETRY_CONTEXT\}\}/$retry_block}"
    else
        prompt="${prompt/\{\{RETRY_CONTEXT\}\}/}"
    fi

    echo "$prompt"
}

# ── Build Environment ─────────────────────────────────────────────────────────
# A broken build environment is indistinguishable from a broken fix if you only
# look at gradlew's exit code — and worker.sh used to do exactly that. On
# 2026-08-21 mylock's repo was missing gradle/wrapper/gradle-wrapper.jar (a
# blanket *.jar in .gitignore), so every CI build died instantly. All three
# attempts on issue #15 were spent, ~15 minutes of Claude was burned, and the
# issue was told it needed "manual intervention" for a defect that did not exist.
#
# Two guards now stand in front of that: a cheap toolchain check before any
# Claude call, and pattern-matching on the build output so an unambiguous
# environment fault never consumes a retry or blames the fix.

# Signatures that are never caused by an app-code change. Dependency-resolution
# and compile errors are deliberately NOT here: a fix can genuinely cause those,
# and misfiling one as "environment" would abandon a fixable issue with a wrong
# diagnosis. Conservative by design — a false "code" reading only costs a retry.
is_env_build_failure() {
    local out="$1"
    local pat
    for pat in \
        'Unable to access jarfile' \
        'SDK location not found' \
        'No space left on device' \
        'Java heap space' \
        'java.lang.OutOfMemoryError' \
        'Could not create service of type' \
        'Could not open .* generic class cache' \
        'Unable to start the daemon process' \
        'JAVA_HOME is not set' \
        'no valid Java installation' \
        'Failed to install the following Android SDK packages'
    do
        if echo "$out" | grep -qE "$pat"; then
            BUILD_ENV_ERROR="$(echo "$out" | grep -oE "$pat" | head -1)"
            return 0
        fi
    done
    return 1
}

# ~5 seconds, and it catches the whole class of failure above before a single
# token is spent: a missing or unexecutable wrapper, a wrapper jar that is not
# there, an unusable JDK, a corrupt Gradle distribution.
check_build_env() {
    cd "$PROJECT_DIR"
    if [[ ! -f ./gradlew ]]; then
        BUILD_ENV_ERROR="./gradlew is missing from $PROJECT_DIR"
        return 1
    fi
    if [[ ! -x ./gradlew ]]; then
        BUILD_ENV_ERROR="./gradlew is not executable"
        return 1
    fi
    export JAVA_HOME="$JAVA_HOME_PATH"
    local out
    if ! out=$(./gradlew --version 2>&1); then
        BUILD_ENV_ERROR="$(echo "$out" | grep -vE '^\s*$' | tail -3 | tr '\n' ' ')"
        return 1
    fi
    return 0
}

# Full baseline build, CI only. The runner assembles a fresh environment every
# hour, so a build that fails before anything is touched is an environment fault
# by definition; on the Mac the environment is stable and a second full build per
# run costs more than it would catch. Also gives the retry loop a reference point:
# if HEAD did not build clean, no fix on top of it can be judged by its build.
verify_baseline_build() {
    if [[ -z "${AUTOFIX_WORKSPACE:-}" ]]; then
        return 0
    fi
    log "Verifying baseline build ($BUILD_TASK) before any fix..."
    cd "$PROJECT_DIR"
    export JAVA_HOME="$JAVA_HOME_PATH"
    local out exit_code=0
    out=$(./gradlew "$BUILD_TASK" 2>&1) || exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        log "Baseline build passed — a later build failure is attributable to the fix."
        return 0
    fi
    if is_env_build_failure "$out"; then
        BUILD_ENV_ERROR="baseline $BUILD_TASK failed: $BUILD_ENV_ERROR"
    else
        BUILD_ENV_ERROR="baseline $BUILD_TASK failed on untouched HEAD $(git rev-parse --short HEAD): $(echo "$out" | grep -E '^e: |error:|FAILURE:' | head -3 | tr '\n' ' ')"
    fi
    return 1
}

# Where this run happened, so a closed issue says who closed it and from where.
# Without this the only record was a comment, and a cloud fix was indistinguishable
# from a local one — which is how a failed 18:56 run and a successful 19:38 run on
# mylock #15 read as one contradictory story.
run_provenance() {
    if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
        local repo="${GITHUB_REPOSITORY:-itsikh/autofix-agent}"
        echo "GitHub Actions run [${GITHUB_RUN_ID}](https://github.com/${repo}/actions/runs/${GITHUB_RUN_ID})"
    else
        echo "local run on $(hostname -s 2>/dev/null || echo "$(uname -n)")"
    fi
}

# Does this issue already carry the stuck label from an earlier run?
issue_is_stuck() {
    local num="$1"
    run_with_timeout gh issue view "$num" --repo "$BUGS_REPO" --json labels \
        | python3 -c "import sys,json; sys.exit(0 if any(l['name']=='$STUCK_LABEL' for l in json.load(sys.stdin).get('labels',[])) else 1)" 2>/dev/null
}

# ── Fix Execution ─────────────────────────────────────────────────────────────
# Returns: 0 = fix applied & build passed, 1 = failure (attributable to the fix),
#          2 = already fixed, 3 = build environment is broken (not the fix's fault)
attempt_fix() {
    local prompt="$1"
    local task_log="$2"

    local head_before
    head_before=$(git rev-parse HEAD 2>/dev/null || echo "")

    log "Invoking Claude CLI..."
    local claude_exit=0
    local claude_tmp
    claude_tmp=$(mktemp)

    if [[ "$CLAUDE_PROMPT_MODE" == "stdin" ]]; then
        echo "$prompt" | claude --dangerously-skip-permissions 2>&1 | tee -a "$task_log" "$claude_tmp"
    else
        claude --dangerously-skip-permissions -p "$prompt" 2>&1 | tee -a "$task_log" "$claude_tmp"
    fi
    claude_exit=${PIPESTATUS[0]}
    local claude_output
    claude_output=$(cat "$claude_tmp")
    rm -f "$claude_tmp"

    if [[ $claude_exit -ne 0 ]]; then
        log_error "Claude CLI exited with code $claude_exit"
        return 1
    fi

    if echo "$claude_output" | grep -q "ALREADY_FIXED:"; then
        log "Claude determined issue is already fixed."
        return 2
    fi

    # Claude reporting broken tooling rather than repairing it. The prompt asks for
    # this explicitly: repairing the build and committing the repair is how an app
    # fix ends up carrying wrapper churn it has no business touching.
    if echo "$claude_output" | grep -q "BUILD_ENV_BROKEN:"; then
        BUILD_ENV_ERROR="$(echo "$claude_output" | grep -m1 "BUILD_ENV_BROKEN:" | sed 's/.*BUILD_ENV_BROKEN: *//' | cut -c1-300)"
        log_error "Claude reports the build environment is broken: $BUILD_ENV_ERROR"
        return 3
    fi

    local head_after
    head_after=$(git rev-parse HEAD 2>/dev/null || echo "")
    local claude_committed=false
    [[ -n "$head_before" && "$head_before" != "$head_after" ]] && claude_committed=true

    if [[ "$claude_committed" == "false" ]] && git diff --quiet && git diff --cached --quiet; then
        log_error "Claude ran but no files were modified or committed."
        return 1
    fi

    # Always verify here, even when Claude committed and a release will follow.
    # Deferring to /release looks like a free saving but inverts the order that
    # matters: the issue is closed and the fix is pushed BEFORE /release builds
    # anything, so a broken fix would be published and announced as resolved.
    # An extra build is cheap next to a green issue pointing at a broken commit.
    if [[ "$claude_committed" == "true" ]]; then
        log "Claude committed changes (HEAD moved to ${head_after:0:8}) — verifying build."
    fi

    log "Verifying build ($BUILD_TASK)..."
    export JAVA_HOME="$JAVA_HOME_PATH"
    local build_exit=0
    local build_output
    build_output=$(cd "$PROJECT_DIR" && ./gradlew "$BUILD_TASK" 2>&1) || build_exit=$?
    echo "$build_output" >> "$task_log"

    if [[ $build_exit -ne 0 ]]; then
        # Distinguish "the fix broke the build" from "nothing could have built here".
        # Retrying the latter just spends another Claude invocation on a fault no
        # code change can reach.
        if is_env_build_failure "$build_output"; then
            log_error "Build environment fault, not a bad fix: $BUILD_ENV_ERROR"
            return 3
        fi
        log_error "Build verification failed ($BUILD_TASK)."
        return 1
    fi

    log "Build verification passed."
    return 0
}

# Undo everything an attempt did, commits included. `git checkout -- .` cannot
# undo a commit, so a failed attempt that had already committed left that commit
# sitting on main — and verify_git_state pushes it at the start of the next run.
# An unverified fix reaching the remote is worse than no fix at all.
reset_to_task_head() {
    local head="$1"
    if [[ -n "$head" ]]; then
        git reset --hard "$head" >/dev/null 2>&1 || true
    else
        git checkout -- . 2>/dev/null || true
    fi
    # -e: the task log lives in .autofix-logs, which not every app repo gitignores,
    # and clean would delete the file this run is still writing to.
    git clean -fd -e .autofix-logs >/dev/null 2>&1 || true
}

# Only the current attempt's output. The task log is append-only across attempts,
# so a plain tail hands Claude a previous attempt's error as if it were current.
attempt_tail() {
    local file="$1" offset="$2"
    tail -c "+$((offset + 1))" "$file" 2>/dev/null | tail -50
}

# Returns: 0 = fixed (or verified already fixed), 1 = failed, 3 = environment fault
try_fix_task() {
    local task_file="$1"
    local task_log="$2"

    local issues_desc
    issues_desc=$(format_issues_for_prompt "$task_file")
    local retry_context=""
    local attempt=1

    local task_head
    task_head=$(git rev-parse HEAD 2>/dev/null || echo "")

    while [[ $attempt -le $MAX_RETRIES ]]; do
        log "Attempt $attempt/$MAX_RETRIES..."
        if [[ $attempt -gt 1 ]]; then
            reset_to_task_head "$task_head"
        fi

        # Where this attempt's output begins in the log. Extracting FIX_SUMMARY from
        # the whole file republishes every failed attempt's report too: mylock #15
        # was closed carrying two contradictory summaries, the first describing a
        # timeout value the committed code never had.
        local attempt_offset
        attempt_offset=$(wc -c < "$task_log" 2>/dev/null || echo 0)

        local prompt
        prompt=$(build_prompt "$issues_desc" "$retry_context")
        local fix_result=0
        attempt_fix "$prompt" "$task_log" || fix_result=$?

        if [[ $fix_result -eq 0 ]]; then
            # Stage first, then describe what was staged — the report should name
            # exactly what the commit contains, not everything that changed on disk.
            local add_args=(-A -- . ':(exclude).autofix-logs')
            if [[ "$ALLOW_BUILD_INFRA_EDITS" != "true" ]]; then
                local infra_touched
                infra_touched=$(git status --porcelain -- gradlew gradlew.bat gradle/wrapper \
                    gradle.properties local.properties keystore.properties 2>/dev/null \
                    | awk '{print $NF}' | tr '\n' ' ')
                if [[ -n "$infra_touched" ]]; then
                    log "Excluding build-infrastructure changes from the fix commit: $infra_touched"
                    log "Set ALLOW_BUILD_INFRA_EDITS=true in the conf if this app's issues are about its build."
                fi
                add_args+=("${BUILD_INFRA_PATHSPECS[@]}")
            fi
            git add "${add_args[@]}"

            local diff_summary diff_detail
            if [[ -n "$(git diff --cached --name-only 2>/dev/null)" ]]; then
                diff_summary=$(git diff --cached --stat 2>/dev/null || echo "")
                diff_detail=$(git diff --cached --no-color 2>/dev/null | head -200 || echo "")
            else
                # Claude committed its own work, so there is nothing staged. Describe
                # the commits it made instead of reporting an empty change set.
                diff_summary=$(git diff --stat "$task_head"..HEAD 2>/dev/null || echo "")
                diff_detail=$(git diff --no-color "$task_head"..HEAD 2>/dev/null | head -200 || echo "")
            fi

            local issue_numbers
            issue_numbers=$(run_py "$task_file" 'import json,sys
with open(sys.argv[1]) as f: issues=json.load(f)
print(", ".join("#"+str(i["number"]) for i in issues))')
            git commit -m "autofix: resolve $issue_numbers" 2>/dev/null || true
            log "Fix committed for $issue_numbers"
            echo "$diff_summary" > "$task_log.diff_summary"
            echo "$diff_detail" > "$task_log.diff_detail"
            echo "$attempt" > "$task_log.attempt"
            local fix_summary
            fix_summary=$(tail -c "+$((attempt_offset + 1))" "$task_log" 2>/dev/null \
                | sed -n '/FIX_SUMMARY_START/,/FIX_SUMMARY_END/{/FIX_SUMMARY_START/d;/FIX_SUMMARY_END/d;p;}' || echo "")
            [[ -n "$fix_summary" ]] && echo "$fix_summary" > "$task_log.fix_summary"
            return 0

        elif [[ $fix_result -eq 2 ]]; then
            echo "$attempt" > "$task_log.attempt"
            while IFS= read -r num; do
                run_with_timeout gh issue close "$num" --repo "$BUGS_REPO" \
                    --comment "Autofix agent verified this issue is already resolved in the current code.

<sub>Verified by autofix-agent on attempt ${attempt}/${MAX_RETRIES} — $(run_provenance).</sub>" \
                    2>/dev/null || true
                log "Closed already-fixed issue #$num"
                clear_stuck_label "$num"
            done < <(run_py "$task_file" 'import json,sys
with open(sys.argv[1]) as f: issues=json.load(f)
for i in issues: print(i["number"])')
            return 0

        elif [[ $fix_result -eq 3 ]]; then
            # Nothing a code change can reach. Retrying spends another full Claude
            # invocation on the same wall, and commenting libels a fix that was
            # never the problem — the exact sequence that hit mylock #15.
            reset_to_task_head "$task_head"
            log_error "Aborting task: build environment is broken — $BUILD_ENV_ERROR"
            log_error "No retry consumed, no failure comment posted: this is not a bad fix."
            return 3
        fi

        retry_context=$(attempt_tail "$task_log" "$attempt_offset")
        [[ -z "$retry_context" ]] && retry_context="Unknown error"
        attempt=$((attempt + 1))
    done

    reset_to_task_head "$task_head"

    # Label on the first failure, comment only when a later run fails again. A
    # comment on every failed run is how mylock #15 got "manual intervention
    # required" an hour before a clean run fixed it — two runs telling one story
    # in opposite directions, with nothing to reconcile them.
    while IFS= read -r num; do
        if issue_is_stuck "$num"; then
            run_with_timeout gh issue comment "$num" --repo "$BUGS_REPO" \
                --body "Autofix agent has now failed to resolve this issue on two or more consecutive runs ($MAX_RETRIES attempts each). Manual intervention required.

<sub>Last attempt: $(run_provenance).</sub>" 2>/dev/null || true
            log "Commented on repeatedly-stuck issue #$num"
        else
            run_with_timeout gh issue edit "$num" --repo "$BUGS_REPO" \
                --add-label "$STUCK_LABEL" 2>/dev/null || true
            log "Labelled #$num '$STUCK_LABEL' — first failure, no comment yet"
        fi
    done < <(run_py "$task_file" 'import json,sys
with open(sys.argv[1]) as f: issues=json.load(f)
for i in issues: print(i["number"])')
    log_error "All $MAX_RETRIES attempts failed."
    return 1
}

# A fixed issue must not stay flagged as stuck from an earlier failed run.
clear_stuck_label() {
    local num="$1"
    run_with_timeout gh issue edit "$num" --repo "$BUGS_REPO" \
        --remove-label "$STUCK_LABEL" 2>/dev/null || true
}

# ── Release Trigger ───────────────────────────────────────────────────────────
trigger_release() {
    if [[ "$RELEASE_MODE" == "none" ]]; then
        # Not a benign skip. The point of the agent is ticket in, new version out;
        # a fix that is pushed but never published reaches no user. mylock #15 was
        # fixed in the cloud on 2026-08-21 and sat unreleased because CI forces
        # RELEASE_MODE=none and the Mac then saw no open issues to act on.
        log_error "UNRELEASED: fixes are pushed but RELEASE_MODE=none, so no version was published."
        log_error "ci/release-drift.sh must pick this up, or the fix never reaches a user."
        RELEASE_FAILED=true
        return
    fi

    # What the newest published release is before we start, so success can be
    # judged by a release appearing rather than by an exit code.
    local before_tag after_tag
    before_tag=$(run_with_timeout gh release view --repo "$BUGS_REPO" --json tagName -q .tagName 2>/dev/null || echo "")

    log "Triggering release via Claude CLI (/release)..."
    cd "$PROJECT_DIR"
    local rel_exit=0
    claude --dangerously-skip-permissions -p "/release" </dev/null 2>&1 || rel_exit=$?
    if [[ $rel_exit -ne 0 ]]; then
        log_error "Release FAILED (claude exit $rel_exit). Fixes are pushed but unreleased."
        RELEASE_FAILED=true
        return
    fi

    # A zero exit is not proof of a release: /release aborts in its own pre-flight
    # (missing keystore, tag already taken) and still leaves claude exiting 0.
    after_tag=$(run_with_timeout gh release view --repo "$BUGS_REPO" --json tagName -q .tagName 2>/dev/null || echo "")
    if [[ -z "$after_tag" || "$after_tag" == "$before_tag" ]]; then
        log_error "Release published nothing — still at '${before_tag:-none}'. Fixes are pushed but unreleased."
        RELEASE_FAILED=true
        return
    fi
    log "Released $after_tag (was ${before_tag:-none})."
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$LOG_DIR"
    WORK_TMP=$(mktemp -d)

    log "=== Worker started (project: $PROJECT_DIR, repo: $BUGS_REPO) ==="
    acquire_lock
    verify_git_state
    ensure_label_exists

    # Both checks run before a single token is spent. Without them a broken runner
    # reads as a broken fix: every attempt fails, the issue is told it needs manual
    # intervention, and the actual fault never gets named.
    if ! check_build_env; then
        log_error "Build environment is unusable: $BUILD_ENV_ERROR"
        log_error "Refusing to run: every attempt would fail here and be blamed on the fix."
        return 1
    fi
    if ! verify_baseline_build; then
        log_error "$BUILD_ENV_ERROR"
        log_error "Refusing to run: HEAD does not build, so no fix could be verified against it."
        return 1
    fi

    local any_fixed=false
    local any_failed=false
    local env_failed=false
    local all_fixed_issues=()
    local round=1

    while true; do
        log "--- Round $round ---"
        local tasks_file="$WORK_TMP/tasks_r${round}.json"
        fetch_and_group_issues > "$tasks_file"

        local task_count
        task_count=$(run_py "$tasks_file" 'import json,sys
with open(sys.argv[1]) as f: print(len(json.load(f)))')

        if [[ "$task_count" == "0" ]]; then
            log "No open issues. Done."
            break
        fi

        log "Found $task_count task(s) to process."
        local fixed_this_round=()
        local task_index=0

        while [[ $task_index -lt $task_count ]]; do
            local task_file="$WORK_TMP/task_r${round}_${task_index}.json"
            python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    tasks = json.load(f)
print(json.dumps(tasks[$task_index]))
" "$tasks_file" > "$task_file"

            local task_label
            task_label=$(run_py "$task_file" 'import json,sys
with open(sys.argv[1]) as f: issues=json.load(f)
print(", ".join("#"+str(i["number"]) for i in issues))')

            log "Processing task: $task_label"
            label_task_active "$task_file"

            local task_log="$LOG_DIR/task_$(date +%Y%m%d_%H%M%S)_${task_label//[^0-9_]/_}.log"

            local task_result=0
            try_fix_task "$task_file" "$task_log" || task_result=$?

            if [[ $task_result -eq 0 ]]; then
                any_fixed=true
                fixed_this_round+=("1")
                local attempt_no="?"
                [[ -f "$task_log.attempt" ]] && attempt_no=$(cat "$task_log.attempt")
                local close_body=""
                [[ -f "$task_log.fix_summary" ]] && close_body+="$(cat "$task_log.fix_summary")\n\n"
                [[ -f "$task_log.diff_summary" ]] && close_body+="---\n### Files Changed\n\`\`\`\n$(cat "$task_log.diff_summary")\n\`\`\`\n"
                [[ -z "$close_body" ]] && close_body="Fixed by autofix agent."
                # Provenance, so a closed issue says which run closed it and after how
                # many attempts. Without it a failed run and a later successful one read
                # as one contradictory story on the same issue.
                close_body+="\n<sub>Fixed by autofix-agent on attempt ${attempt_no}/${MAX_RETRIES} — $(run_provenance).</sub>"

                while IFS= read -r num; do
                    run_with_timeout gh issue close "$num" --repo "$BUGS_REPO" \
                        --comment "$(echo -e "$close_body")" 2>/dev/null || true
                    log "Closed issue #$num"
                    clear_stuck_label "$num"
                    all_fixed_issues+=("$num")
                done < <(run_py "$task_file" 'import json,sys
with open(sys.argv[1]) as f: issues=json.load(f)
for i in issues: print(i["number"])')
                rm -f "$task_log.diff_summary" "$task_log.diff_detail" "$task_log.fix_summary" "$task_log.attempt"
            elif [[ $task_result -eq 3 ]]; then
                # The environment, not this task. Every remaining task would hit the
                # same wall, so stop rather than burn the rest of the budget on it.
                any_failed=true
                env_failed=true
                unlabel_task_active "$task_file"
                break
            else
                any_failed=true
            fi

            unlabel_task_active "$task_file"
            task_index=$((task_index + 1))
        done

        if [[ "$env_failed" == "true" ]]; then
            log_error "Stopping: the build environment is broken, not the fixes."
            break
        fi

        if [[ ${#fixed_this_round[@]} -gt 0 ]]; then
            # Never swallow the push error. A failed push here means the issue
            # was closed but the fix never left the machine — the worst possible
            # outcome, and it used to be reported as "Pushed fixes".
            local push_failed=false
            while IFS= read -r remote; do
                [[ -z "$remote" ]] && continue
                local push_err
                if ! push_err=$(git push "$remote" main 2>&1); then
                    log_error "Push to '$remote' FAILED: $push_err"
                    push_failed=true
                else
                    log "Pushed to '$remote'."
                fi
            done < <(get_remotes)
            if [[ "$push_failed" == "true" ]]; then
                log_error "Round $round: fixes committed but NOT pushed."
                any_failed=true
            else
                log "Pushed fixes for round $round."
            fi
        else
            log "No issues fixed this round. Stopping."
            break
        fi

        round=$((round + 1))
        sleep 5
    done

    if [[ "$any_fixed" == "true" ]]; then
        log "=== Post-fix: triggering release ==="
        trigger_release
        log "=== Worker done: ${#all_fixed_issues[@]} issue(s) fixed ==="
    else
        log "=== Worker done: no issues fixed ==="
    fi

    [[ "$any_failed" == "true" || "$RELEASE_FAILED" == "true" ]] && return 1
    return 0
}

set -o pipefail
main "$@" 2>&1 | tee -a "$LOG_DIR/autofix_$(date +%Y%m%d).log"
