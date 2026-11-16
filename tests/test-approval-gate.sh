#!/usr/bin/env bash
# Offline test for worker.sh's APPROVED_BY gate (filter_approved). A fake `gh`
# answers the GraphQL timeline query per issue number; no network is used.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_TMP=$(mktemp -d); trap 'rm -rf "$WORK_TMP"' EXIT
FAKE="$WORK_TMP/fake"; mkdir -p "$FAKE/bin"

log() { :; }
run_with_timeout() { "$@"; }
run_py() { local f="$1"; shift; python3 -c "$*" "$f"; }
eval "$(awk '/^filter_approved\(\) \{/,/^\}/' "$HERE/../worker.sh")"

cat > "$FAKE/bin/gh" <<'G'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in n=*) n="${a#n=}" ;; esac; done
f="$FAKE_DIR/issue_$n.json"; [[ -f "$f" ]] || exit 1; cat "$f"
G
chmod +x "$FAKE/bin/gh"; export PATH="$FAKE/bin:$PATH" FAKE_DIR="$FAKE"

ev() { # login createdAt [label]
    printf '{"__typename":"LabeledEvent","createdAt":"%s","label":{"name":"%s"},"actor":{"login":"%s"}}' "$2" "${3:-approved}" "$1"; }
issue() { # n lastEditedAt nodes...
    local n="$1" edited="$2"; shift 2
    local IFS=,
    printf '{"data":{"repository":{"issue":{"lastEditedAt":%s,"timelineItems":{"nodes":[%s]}}}}}' "$edited" "$*" > "$FAKE/issue_$n.json"; }

issue 1 null "$(ev itsikh 2026-11-16T10:00:00Z)"                                   # approved by owner → kept
issue 2 null "$(ev reporter-bot 2026-11-16T10:00:00Z)"                             # self-approved → dropped
issue 3 '"2026-11-16T11:00:00Z"' "$(ev itsikh 2026-11-16T10:00:00Z)"               # body edited after → dropped
issue 4 null "$(ev itsikh 2026-11-16T09:00:00Z),$(ev someone 2026-11-16T10:00:00Z)" # re-labelled by other → dropped
issue 5 null "$(ev itsikh 2026-11-16T10:00:00Z),{\"__typename\":\"RenamedTitleEvent\",\"createdAt\":\"2026-11-16T12:00:00Z\"}" # retitled → dropped
issue 6 '"2026-11-16T09:00:00Z"' "$(ev someone 2026-11-16T08:00:00Z),$(ev ItsikH 2026-11-16T10:00:00Z)" # edit before approval, case-insensitive → kept
issue 7 null "$(ev itsikh 2026-11-16T10:00:00Z bug)"                               # approver added another label only → dropped
# issue 8: no fake response → API failure → dropped (fail closed)
echo '[{"number":1},{"number":2},{"number":3},{"number":4},{"number":5},{"number":6},{"number":7},{"number":8}]' > "$WORK_TMP/issues.json"

BUGS_REPO="itsikh/example" APPROVED_BY="itsikh, other" AUTOFIX_LABEL="approved"
filter_approved "$WORK_TMP/issues.json"
got=$(python3 -c 'import json,sys; print(" ".join(str(i["number"]) for i in json.load(open(sys.argv[1]))))' "$WORK_TMP/issues.json")
if [[ "$got" == "1 6" ]]; then echo "PASS approval gate ($got)"; else echo "FAIL approval gate: got '$got', want '1 6'"; exit 1; fi
