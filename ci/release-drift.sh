#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# ci/release-drift.sh — is every autofixed bug actually released?
#
# The agent exists to turn a ticket into a shipped version. Everything between
# those two points is invisible to the person who filed the bug: they do not
# care that a commit landed, they care that a version exists containing it.
#
# That link broke silently on 2026-08-21. mylock #15 was fixed by the hourly
# cloud run, which forces RELEASE_MODE=none because it had no signing keystore.
# The run closed the issue, so the Mac's next run found no open issues and never
# cut a release either. The fix sat in main, the issue read "completed", and no
# user could install it. medreminder had the same gap.
#
# This is the check that would have caught it: for each app, compare the newest
# published release against the code's main branch and report any `autofix:`
# commit that has never shipped.
#
# Usage:
#   ci/release-drift.sh                 # human-readable report, all apps
#   ci/release-drift.sh --json          # machine-readable, for automation
#   ci/release-drift.sh --app mylock    # one app
#   ci/release-drift.sh --remote        # GitHub API only, no clone needed (CI)
#
# Exit codes:
#   0  every app is in sync (or has nothing unreleased from autofix)
#   1  at least one app has unreleased autofix commits
#   2  the check itself could not run for at least one app
###############################################################################

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

JSON=false
ONLY_APP=""
# --remote answers the question without a clone, for the hourly cloud run: nine
# Android repos cloned every hour to count commits would cost more than the fixes
# do. It can only see code repos hosted on GitHub; the Bitbucket-primary apps
# (calcvault, mychef, sosblocker) come back "unverifiable" and are covered by the
# Mac's watchdog, which has their clones.
REMOTE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)   JSON=true; shift ;;
        --remote) REMOTE=true; shift ;;
        --app)   ONLY_APP="${2:?--app needs a slug}"; shift 2 ;;
        -h|--help) sed -n '5,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

drift_found=false
check_failed=false
json_rows=()

emit() { [[ "$JSON" == "true" ]] || echo "$*"; }

# Report a row in both formats. status is one of:
#   in-sync | drift | no-release | no-clone | tag-missing | unverifiable
row() {
    local slug="$1" status="$2" released="$3" autofix_n="$4" total_n="$5" note="$6"
    json_rows+=("$(python3 -c '
import json, sys
print(json.dumps({
    "app": sys.argv[1], "status": sys.argv[2], "released": sys.argv[3],
    "unreleased_autofix_commits": int(sys.argv[4]), "unreleased_commits": int(sys.argv[5]),
    "note": sys.argv[6],
}))' "$slug" "$status" "$released" "$autofix_n" "$total_n" "$note")")

    local marker="  ok "
    case "$status" in
        drift)       marker="DRIFT" ;;
        no-release)  marker="  -  " ;;
        no-clone|tag-missing|unverifiable) marker="  ? " ;;
    esac
    emit "$(printf '%s %-12s released=%-10s unreleased: %s autofix / %s total  %s' \
        "$marker" "$slug" "${released:-none}" "$autofix_n" "$total_n" "$note")"
}

emit "── release drift ────────────────────────────────────────────────────────"

shopt -s nullglob
for conf in "$AGENT_DIR/apps"/*.conf; do
    (
        # Subshell per app: confs are sourced, and one app's variables must not
        # leak into the next. Values needed after this block go through row().
        unset APP_SLUG PROJECT_DIR PROJECT_DIR_CLOUD BUGS_REPO ENABLED CODE_REPO
        # shellcheck disable=SC1090
        source "$conf"

        [[ -n "$ONLY_APP" && "${APP_SLUG:-}" != "$ONLY_APP" ]] && exit 0
        [[ "${ENABLED:-true}" == "false" ]] && exit 0
        [[ -z "${APP_SLUG:-}" || -z "${BUGS_REPO:-}" ]] && exit 0

        # Same resolution order as worker.sh, so this reports on whatever tree
        # the agent would actually have released from.
        if [[ -n "${AUTOFIX_WORKSPACE:-}" ]]; then
            PROJECT_DIR="${AUTOFIX_WORKSPACE}/${APP_SLUG}"
        elif [[ "$(uname)" != "Darwin" && -n "${PROJECT_DIR_CLOUD:-}" ]]; then
            PROJECT_DIR="$PROJECT_DIR_CLOUD"
        fi

        released=$(gh release view --repo "$BUGS_REPO" --json tagName -q .tagName 2>/dev/null || echo "")
        if [[ -z "$released" ]]; then
            echo "ROW|$APP_SLUG|no-release||0|0|no published release yet — nothing to compare"
            exit 0
        fi

        if [[ "$REMOTE" == "true" ]]; then
            # github.com/<owner>/<repo>.git → <owner>/<repo>
            case "${CODE_REPO:-}" in
                https://github.com/*)
                    gh_repo="${CODE_REPO#https://github.com/}"; gh_repo="${gh_repo%.git}" ;;
                *)
                    echo "ROW|$APP_SLUG|unverifiable|$released|0|0|code repo is not on GitHub — checked by the Mac watchdog"
                    exit 0 ;;
            esac
            # compare returns 404 when the tag is absent from the code repo, which
            # is itself the answer: the release exists but its tag never landed.
            cmp_json=$(gh api "repos/${gh_repo}/compare/${released}...main" 2>/dev/null || echo "")
            if [[ -z "$cmp_json" ]]; then
                echo "ROW|$APP_SLUG|tag-missing|$released|0|0|tag $released is not in ${gh_repo} — cannot compare"
                exit 0
            fi
            read -r total autofix_n subjects <<<"$(printf '%s' "$cmp_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
msgs = [c["commit"]["message"].splitlines()[0] for c in d.get("commits", [])]
fix = [m[len("autofix: "):] for m in msgs if m.startswith("autofix: ")]
print(len(msgs), len(fix), ",".join(fix)[:120] or "-")
')"
            if [[ "${autofix_n:-0}" -gt 0 ]]; then
                echo "ROW|$APP_SLUG|drift|$released|$autofix_n|$total|unreleased fixes: $subjects"
            else
                echo "ROW|$APP_SLUG|in-sync|$released|0|$total|"
            fi
            exit 0
        fi

        if [[ -z "${PROJECT_DIR:-}" || ! -d "$PROJECT_DIR/.git" ]]; then
            echo "ROW|$APP_SLUG|no-clone|$released|0|0|no local clone at ${PROJECT_DIR:-<unset>}"
            exit 0
        fi

        git -C "$PROJECT_DIR" fetch --tags --quiet --all 2>/dev/null

        # Compare against the remote branch, never the local checkout: a Mac that
        # has not pulled would otherwise report drift that does not exist, or miss
        # drift that does. Fall back to local main only if there is no remote ref.
        head_ref="origin/main"
        git -C "$PROJECT_DIR" rev-parse -q --verify "refs/remotes/origin/main" >/dev/null 2>&1 || head_ref="main"

        base="$released"
        if ! git -C "$PROJECT_DIR" rev-parse -q --verify "refs/tags/$released" >/dev/null 2>&1; then
            # The Bitbucket-primary apps (calcvault, mychef, sosblocker) publish
            # releases to a separate GitHub repo and have no tags on the code
            # remote at all — calcvault's origin has none. Fall back to the commit
            # /release makes when it bumps the version, which every app has:
            #   git commit -m "chore: release v<version>"
            base=$(git -C "$PROJECT_DIR" log --format='%H %s' "$head_ref" 2>/dev/null \
                | grep -m1 -F "chore: release ${released}" | cut -d' ' -f1)
            if [[ -z "$base" ]]; then
                echo "ROW|$APP_SLUG|tag-missing|$released|0|0|no tag $released and no \"chore: release $released\" commit — cannot compare"
                exit 0
            fi
        fi

        total=$(git -C "$PROJECT_DIR" rev-list --count "$base..$head_ref" 2>/dev/null || echo 0)
        autofix_n=$(git -C "$PROJECT_DIR" log --format=%s "$base..$head_ref" 2>/dev/null \
            | grep -c '^autofix: ' || true)
        autofix_n=${autofix_n:-0}

        if [[ "$autofix_n" -gt 0 ]]; then
            subjects=$(git -C "$PROJECT_DIR" log --format=%s "$base..$head_ref" 2>/dev/null \
                | grep '^autofix: ' | sed 's/^autofix: //' | paste -sd, - | cut -c1-120)
            echo "ROW|$APP_SLUG|drift|$released|$autofix_n|$total|unreleased fixes: $subjects"
        else
            echo "ROW|$APP_SLUG|in-sync|$released|0|$total|"
        fi
    ) > /tmp/release-drift-$$.row 2>/dev/null

    while IFS='|' read -r tag slug status released autofix_n total note; do
        [[ "$tag" != "ROW" ]] && continue
        row "$slug" "$status" "$released" "$autofix_n" "$total" "$note"
        case "$status" in
            drift) drift_found=true ;;
            no-clone|tag-missing|unverifiable) check_failed=true ;;
        esac
    done < /tmp/release-drift-$$.row
    rm -f /tmp/release-drift-$$.row
done

if [[ "$JSON" == "true" ]]; then
    printf '[%s]\n' "$(IFS=,; echo "${json_rows[*]:-}")"
else
    emit "─────────────────────────────────────────────────────────────────────────"
    if [[ "$drift_found" == "true" ]]; then
        emit "DRIFT: at least one app has an autofixed bug that was never released."
        emit "Every one of those is a closed issue whose reporter still has the bug."
    else
        emit "All apps in sync: no autofixed commit is waiting for a release."
    fi
fi

[[ "$drift_found" == "true" ]] && exit 1
[[ "$check_failed" == "true" ]] && exit 2
exit 0
