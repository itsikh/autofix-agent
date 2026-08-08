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
#             BUILD_TASK, MAX_RETRIES, CLAUDE_PROMPT_MODE, CUSTOM_SCRIPT
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
BUILD_TASK="${BUILD_TASK:-assembleDebug}"
MAX_RETRIES="${MAX_RETRIES:-3}"
CLAUDE_PROMPT_MODE="${CLAUDE_PROMPT_MODE:-arg}"

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
WORK_TMP=""

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
    if [[ "$GIT_REMOTES" == "auto" ]]; then
        git remote 2>/dev/null || true
    else
        echo "$GIT_REMOTES" | tr ' ,' '\n' | grep -v '^$' || true
    fi
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

# ── Fix Execution ─────────────────────────────────────────────────────────────
# Returns: 0 = fix applied & build passed, 1 = failure, 2 = already fixed
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

    local head_after
    head_after=$(git rev-parse HEAD 2>/dev/null || echo "")
    local claude_committed=false
    [[ -n "$head_before" && "$head_before" != "$head_after" ]] && claude_committed=true

    if [[ "$claude_committed" == "false" ]] && git diff --quiet && git diff --cached --quiet; then
        log_error "Claude ran but no files were modified or committed."
        return 1
    fi

    if [[ "$claude_committed" == "true" ]]; then
        log "Claude committed changes (HEAD moved to ${head_after:0:8}) — build verified by release."
        return 0
    fi

    log "Verifying build ($BUILD_TASK)..."
    export JAVA_HOME="$JAVA_HOME_PATH"
    local build_exit=0
    local build_output
    build_output=$(cd "$PROJECT_DIR" && ./gradlew "$BUILD_TASK" 2>&1) || build_exit=$?
    echo "$build_output" >> "$task_log"

    if [[ $build_exit -ne 0 ]]; then
        log_error "Build verification failed ($BUILD_TASK)."
        return 1
    fi

    log "Build verification passed."
    return 0
}

try_fix_task() {
    local task_file="$1"
    local task_log="$2"

    local issues_desc
    issues_desc=$(format_issues_for_prompt "$task_file")
    local retry_context=""
    local attempt=1

    while [[ $attempt -le $MAX_RETRIES ]]; do
        log "Attempt $attempt/$MAX_RETRIES..."
        if [[ $attempt -gt 1 ]]; then
            git checkout -- . 2>/dev/null || true
            git clean -fd 2>/dev/null || true
        fi

        local prompt
        prompt=$(build_prompt "$issues_desc" "$retry_context")
        local fix_result=0
        attempt_fix "$prompt" "$task_log" || fix_result=$?

        if [[ $fix_result -eq 0 ]]; then
            local diff_summary diff_detail
            diff_summary=$(git diff --stat 2>/dev/null || echo "")
            diff_detail=$(git diff --no-color 2>/dev/null | head -200 || echo "")
            # Exclude the agent's own log dir: not every app repo gitignores
            # .autofix-logs, and `git add -A` would otherwise commit our logs
            # into the app's history and push them.
            git add -A -- . ':(exclude).autofix-logs'
            local issue_numbers
            issue_numbers=$(run_py "$task_file" 'import json,sys
with open(sys.argv[1]) as f: issues=json.load(f)
print(", ".join("#"+str(i["number"]) for i in issues))')
            git commit -m "autofix: resolve $issue_numbers" 2>/dev/null || true
            log "Fix committed for $issue_numbers"
            echo "$diff_summary" > "$task_log.diff_summary"
            echo "$diff_detail" > "$task_log.diff_detail"
            local fix_summary
            fix_summary=$(sed -n '/FIX_SUMMARY_START/,/FIX_SUMMARY_END/{/FIX_SUMMARY_START/d;/FIX_SUMMARY_END/d;p;}' "$task_log" 2>/dev/null || echo "")
            [[ -n "$fix_summary" ]] && echo "$fix_summary" > "$task_log.fix_summary"
            return 0

        elif [[ $fix_result -eq 2 ]]; then
            while IFS= read -r num; do
                run_with_timeout gh issue close "$num" --repo "$BUGS_REPO" \
                    --comment "Autofix agent verified this issue is already resolved in the current code." \
                    2>/dev/null || true
                log "Closed already-fixed issue #$num"
            done < <(run_py "$task_file" 'import json,sys
with open(sys.argv[1]) as f: issues=json.load(f)
for i in issues: print(i["number"])')
            return 0
        fi

        retry_context=$(tail -50 "$task_log" 2>/dev/null || echo "Unknown error")
        attempt=$((attempt + 1))
    done

    git checkout -- . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
    while IFS= read -r num; do
        run_with_timeout gh issue comment "$num" --repo "$BUGS_REPO" \
            --body "Autofix agent failed to resolve this issue after $MAX_RETRIES attempts. Manual intervention required." \
            2>/dev/null || true
    done < <(run_py "$task_file" 'import json,sys
with open(sys.argv[1]) as f: issues=json.load(f)
for i in issues: print(i["number"])')
    log_error "All $MAX_RETRIES attempts failed."
    return 1
}

# ── Release Trigger ───────────────────────────────────────────────────────────
trigger_release() {
    if [[ "$RELEASE_MODE" == "none" ]]; then
        log "RELEASE_MODE=none — skipping release."
        return
    fi
    log "Triggering release via Claude CLI (/release)..."
    cd "$PROJECT_DIR"
    claude --dangerously-skip-permissions -p "/release" </dev/null 2>&1 || {
        log_error "Release skill failed. Manual release may be needed."
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$LOG_DIR"
    WORK_TMP=$(mktemp -d)

    log "=== Worker started (project: $PROJECT_DIR, repo: $BUGS_REPO) ==="
    acquire_lock
    verify_git_state
    ensure_label_exists

    local any_fixed=false
    local any_failed=false
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

            if try_fix_task "$task_file" "$task_log"; then
                any_fixed=true
                fixed_this_round+=("1")
                local close_body=""
                [[ -f "$task_log.fix_summary" ]] && close_body+="$(cat "$task_log.fix_summary")\n\n"
                [[ -f "$task_log.diff_summary" ]] && close_body+="---\n### Files Changed\n\`\`\`\n$(cat "$task_log.diff_summary")\n\`\`\`\n"
                [[ -z "$close_body" ]] && close_body="Fixed by autofix agent."

                while IFS= read -r num; do
                    run_with_timeout gh issue close "$num" --repo "$BUGS_REPO" \
                        --comment "$(echo -e "$close_body")" 2>/dev/null || true
                    log "Closed issue #$num"
                    all_fixed_issues+=("$num")
                done < <(run_py "$task_file" 'import json,sys
with open(sys.argv[1]) as f: issues=json.load(f)
for i in issues: print(i["number"])')
                rm -f "$task_log.diff_summary" "$task_log.diff_detail" "$task_log.fix_summary"
            else
                any_failed=true
            fi

            unlabel_task_active "$task_file"
            task_index=$((task_index + 1))
        done

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

    [[ "$any_failed" == "true" ]] && return 1
    return 0
}

set -o pipefail
main "$@" 2>&1 | tee -a "$LOG_DIR/autofix_$(date +%Y%m%d).log"
