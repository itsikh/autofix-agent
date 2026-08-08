#!/usr/bin/env bash
# test-cloud-build.sh — Probe each Android project's minimum viable heap for GCP e2-micro
#
# Tests each app at PROBE_HEAPS to find the smallest heap that completes assembleDebug,
# and samples the peak resident memory of the ENTIRE build process tree (Gradle JVM +
# forked aapt2/d8/etc), which is what actually has to fit in a VM's RAM.
#
# Usage:
#   ./test-cloud-build.sh [--quick] [--app <slug>]
#
#   --quick    Test only the two most relevant tiers: 700m (e2-micro) and 1500m (e2-small)
#   --app      Test only one specific app slug

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs/cloud-build-test"
mkdir -p "$LOG_DIR"
REPORT="$LOG_DIR/report-$(date +%Y%m%d-%H%M%S).txt"
RESULTS_DIR="$LOG_DIR/results-$$"
mkdir -p "$RESULTS_DIR"

# Heap tiers to probe (MB), from smallest to largest
FULL_HEAPS="512 700 1024 1536 2048"
QUICK_HEAPS="700 1500"
PROBE_HEAPS="$FULL_HEAPS"

ONLY_APP=""
QUICK=false
# Default on: an incremental build reports "N up-to-date" and compiles nothing,
# which measures no memory at all. A clean build is also the honest worst case
# for a cloud host, which starts from a fresh clone.
# Side effect: wipes build/ in the probed projects (regenerated on next build).
CLEAN=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)    QUICK=true; PROBE_HEAPS="$QUICK_HEAPS"; shift ;;
        --app)      ONLY_APP="$2"; shift 2 ;;
        --no-clean) CLEAN=false; shift ;;
        *) shift ;;
    esac
done

BUILD_TARGETS="clean assembleDebug"
$CLEAN || BUILD_TARGETS="assembleDebug"

# ── Java home detection ───────────────────────────────────────────────────────
# Gradle needs JAVA_HOME to bootstrap gradlew; gradle.properties sets java.home
# for the daemon only. We pick the Android Studio JBR if present, else system Java.
detect_java_home() {
    local proj_dir="$1"
    # 1. Try the per-project gradle.properties org.gradle.java.home
    local gp="$proj_dir/gradle.properties"
    if [[ -f "$gp" ]]; then
        local jhome
        jhome=$(grep -E '^org\.gradle\.java\.home=' "$gp" | head -1 | cut -d= -f2- | tr -d '"')
        if [[ -n "$jhome" && -d "$jhome" ]]; then
            echo "$jhome"; return
        fi
    fi
    # 2. Android Studio JBR (macOS)
    if [[ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]]; then
        echo "/Applications/Android Studio.app/Contents/jbr/Contents/Home"; return
    fi
    # 3. JAVA_HOME from environment
    if [[ -n "${JAVA_HOME:-}" && -d "$JAVA_HOME" ]]; then
        echo "$JAVA_HOME"; return
    fi
    # 4. system java_home utility
    if /usr/libexec/java_home &>/dev/null 2>&1; then
        /usr/libexec/java_home; return
    fi
    echo ""
}

# ── Helpers ───────────────────────────────────────────────────────────────────

ts()  { date "+%H:%M:%S"; }
log() { echo "[$(ts)] $*" | tee -a "$REPORT"; }
hr()  { echo "────────────────────────────────────────────────────────────────" | tee -a "$REPORT"; }

# Sample the total RSS of a process tree until killed.
#
# /usr/bin/time -l is NOT usable here: it reports rusage for direct waited-for
# children only, so it measures the gradlew wrapper shell (~113 MB) and never
# sees the JVM or the forked aapt2/d8 processes. On a 1 GB VM what matters is
# the SUM of the whole tree at its worst moment, which only sampling gives us.
#
# Writes "<tree_peak_mb> <largest_single_proc_mb>" to $2, refreshed every tick.
#
# exec so the backgrounded PID is python3 itself — otherwise we would kill the
# wrapper subshell and leave python3 orphaned, holding the caller's command-
# substitution pipe open forever.
sample_tree_rss() {
    local root_pid="$1"
    local out_file="$2"
    exec python3 - "$root_pid" "$out_file" <<'PYEOF'
import subprocess, sys, time

root, out = int(sys.argv[1]), sys.argv[2]
peak_tree = peak_one = 0

while True:
    try:
        ps = subprocess.run(['ps', '-axo', 'pid=,ppid=,rss='],
                            capture_output=True, text=True).stdout
    except Exception:
        break

    children, rss = {}, {}
    for line in ps.splitlines():
        parts = line.split()
        if len(parts) != 3:
            continue
        try:
            pid, ppid, kb = int(parts[0]), int(parts[1]), int(parts[2])
        except ValueError:
            continue
        children.setdefault(ppid, []).append(pid)
        rss[pid] = kb

    # Walk the descendant tree from root, summing RSS. ps reports KB on both
    # macOS and Linux, so this stays portable.
    total, biggest, stack, seen = 0, 0, [root], set()
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        kb = rss.get(pid, 0)
        total += kb
        biggest = max(biggest, kb)
        stack.extend(children.get(pid, []))

    peak_tree = max(peak_tree, total // 1024)
    peak_one = max(peak_one, biggest // 1024)

    with open(out, 'w') as f:
        f.write(f"{peak_tree} {peak_one}\n")

    time.sleep(0.5)
PYEOF
}

# Run a build and measure peak whole-tree resident memory.
# Outputs "<tree_peak_mb> <largest_single_proc_mb>"; returns the build exit code.
run_build_measure() {
    local project_dir="$1"
    local heap_mb="$2"
    local build_log="$3"
    local java_home="$4"

    local metaspace_mb=$(( heap_mb / 3 ))
    [[ $metaspace_mb -lt 128 ]] && metaspace_mb=128
    [[ $metaspace_mb -gt 512 ]] && metaspace_mb=512

    # GRADLE_OPTS controls the JVM that runs the build when --no-daemon is active.
    # SerialGC is more memory-efficient than G1/Parallel at small heaps.
    # kotlin.compiler.execution.strategy=in-process avoids a second JVM for the
    # Kotlin daemon (which alone would need another 512m-4g by default).
    local gradle_opts="-Xmx${heap_mb}m -Xms64m -XX:MaxMetaspaceSize=${metaspace_mb}m -XX:+UseSerialGC"

    local rss_file="$build_log.rss"
    echo "0 0" > "$rss_file"

    (
        cd "$project_dir"
        export JAVA_HOME="$java_home"
        export PATH="$java_home/bin:$PATH"
        GRADLE_OPTS="$gradle_opts" \
        ./gradlew $BUILD_TARGETS \
            --no-daemon \
            --no-configuration-cache \
            --no-build-cache \
            -Pkotlin.compiler.execution.strategy=in-process \
            -Dorg.gradle.logging.level=lifecycle \
            >"$build_log" 2>&1
    ) &
    local build_pid=$!

    # >/dev/null: the sampler must not inherit our stdout, which is the caller's
    # command-substitution pipe — holding it open would hang $(run_build_measure).
    sample_tree_rss "$build_pid" "$rss_file" >/dev/null 2>&1 &
    local sampler_pid=$!

    wait "$build_pid"
    local exit_code=$?

    kill "$sampler_pid" 2>/dev/null
    wait "$sampler_pid" 2>/dev/null

    local peak_tree peak_one
    read -r peak_tree peak_one < "$rss_file" 2>/dev/null || { peak_tree=0; peak_one=0; }
    rm -f "$rss_file"

    echo "${peak_tree:-0} ${peak_one:-0}"
    return $exit_code
}

# ── Main ──────────────────────────────────────────────────────────────────────

log "=== Cloud Build Memory Probe ==="
log "Heaps to test: $PROBE_HEAPS MB"
log "Report: $REPORT"
hr

shopt -s nullglob
for conf in "$SCRIPT_DIR/apps"/*.conf; do
    APP_SLUG=$(grep -E '^APP_SLUG='     "$conf" | head -1 | cut -d= -f2- | tr -d '"')
    PROJECT_DIR=$(grep -E '^PROJECT_DIR=' "$conf" | head -1 | cut -d= -f2- | tr -d '"')
    CUSTOM=$(grep -E '^CUSTOM_SCRIPT='  "$conf" | head -1 | cut -d= -f2- | tr -d '"')

    [[ -z "$APP_SLUG" ]] && APP_SLUG="$(basename "$conf" .conf)"

    if [[ -n "$ONLY_APP" && "$APP_SLUG" != "$ONLY_APP" ]]; then
        continue
    fi

    if [[ -n "$CUSTOM" ]]; then
        log "$APP_SLUG: skipping (CUSTOM_SCRIPT — no standard Gradle build)"
        continue
    fi
    if [[ ! -d "$PROJECT_DIR" ]]; then
        log "$APP_SLUG: skipping (PROJECT_DIR not found: $PROJECT_DIR)"
        continue
    fi
    if [[ ! -f "$PROJECT_DIR/gradlew" ]]; then
        log "$APP_SLUG: skipping (no gradlew in $PROJECT_DIR)"
        continue
    fi

    JAVA_HOME_VAL="$(detect_java_home "$PROJECT_DIR")"
    if [[ -z "$JAVA_HOME_VAL" ]]; then
        log "$APP_SLUG: skipping (cannot locate Java home)"
        continue
    fi

    log ""
    log "▶ $APP_SLUG  ($PROJECT_DIR)"
    log "  Java: $JAVA_HOME_VAL"
    hr

    result_file="$RESULTS_DIR/$APP_SLUG"
    # format per line: heap|status|rss_mb
    : > "$result_file"

    for heap in $PROBE_HEAPS; do
        build_log="$LOG_DIR/${APP_SLUG}-${heap}m.log"
        log "  Testing ${heap}m heap..."

        start_epoch=$SECONDS
        measured=$(run_build_measure "$PROJECT_DIR" "$heap" "$build_log" "$JAVA_HOME_VAL")
        build_exit=$?
        elapsed=$(( SECONDS - start_epoch ))
        read -r peak_mb peak_one_mb <<< "$measured"

        oom_lines=0
        if [[ $build_exit -ne 0 ]]; then
            oom_lines=$(grep -c -E "OutOfMemoryError|GC overhead limit|Cannot allocate|heap space|Killed" "$build_log" 2>/dev/null) || oom_lines=0
        fi

        if [[ $build_exit -eq 0 ]]; then
            log "  ✓ ${heap}m: BUILD PASSED  — tree peak ${peak_mb} MB (largest proc ${peak_one_mb} MB)  (${elapsed}s)"
            echo "${heap}|PASS|${peak_mb}|${peak_one_mb}" >> "$result_file"
            # First pass = minimum viable heap (heaps are smallest-first)
            break
        elif [[ "$oom_lines" -gt 0 ]]; then
            log "  ✗ ${heap}m: OOM           — tree peak ${peak_mb} MB  (${elapsed}s)"
            echo "${heap}|OOM|${peak_mb}|${peak_one_mb}" >> "$result_file"
        else
            log "  ✗ ${heap}m: BUILD ERROR   — tree peak ${peak_mb} MB  (${elapsed}s)"
            log "    (see: $build_log)"
            echo "${heap}|ERR|${peak_mb}|${peak_one_mb}" >> "$result_file"
            # Real build error won't be fixed by more RAM — stop
            break
        fi
    done
done

# ── Final Report ──────────────────────────────────────────────────────────────

log ""
hr
log "SUMMARY"
hr
log ""

# Usable RAM per GCP tier = total RAM minus ~250 MB for the OS.
MICRO_LIMIT=750   # e2-micro  1 GB  (FREE tier)
SMALL_LIMIT=1750  # e2-small  2 GB  (~$7/mo)
MEDIUM_LIMIT=3750 # e2-medium 4 GB  (~$13/mo)

# worker.sh runs Claude CLI (Node) and Gradle in the same run. Claude is not
# guaranteed to have exited before a build starts — it can invoke builds itself
# — so the honest budget is build tree peak + Claude's resident footprint.
CLAUDE_RSS_MB="${CLAUDE_RSS_MB:-450}"

log "Sizing against: build tree peak + ${CLAUDE_RSS_MB} MB for Claude CLI"
log ""

printf "%-16s %-10s %-11s %-10s %-11s %-20s %s\n" \
    "APP" "MIN_HEAP" "TREE_PEAK" "MAX_PROC" "+CLAUDE" "GCP_TIER" "VERDICT" | tee -a "$REPORT"
printf "%-16s %-10s %-11s %-10s %-11s %-20s %s\n" \
    "---" "--------" "---------" "--------" "-------" "--------" "-------" | tee -a "$REPORT"

all_pass=true
for result_file in "$RESULTS_DIR"/*; do
    [[ -f "$result_file" ]] || continue
    app_slug="$(basename "$result_file")"

    min_heap="?"; peak_rss="?"; peak_one="?"; budget="?"
    verdict="untested"; gcp_tier="?"

    # Read lines in order (smallest heap first)
    while IFS='|' read -r heap status rss one; do
        if [[ "$status" == "PASS" ]]; then
            min_heap="$heap"
            peak_rss="$rss"
            peak_one="$one"
            budget=$(( rss + CLAUDE_RSS_MB ))

            # Tier is decided by MEASURED memory, not by the -Xmx we passed.
            # A 700m heap does not mean a 700m process.
            if [[ "$budget" -le "$MICRO_LIMIT" ]]; then
                gcp_tier="e2-micro (FREE)"
                verdict="OK for free tier"
            elif [[ "$budget" -le "$SMALL_LIMIT" ]]; then
                gcp_tier="e2-small (~\$7/mo)"
                verdict="exceeds free tier"
                all_pass=false
            elif [[ "$budget" -le "$MEDIUM_LIMIT" ]]; then
                gcp_tier="e2-medium (~\$13/mo)"
                verdict="needs 4 GB"
                all_pass=false
            else
                gcp_tier="> e2-medium"
                verdict="needs large VM"
                all_pass=false
            fi
            break
        fi
    done < "$result_file"

    if [[ "$min_heap" == "?" ]]; then
        all_pass=false
        # Report what the last probe found
        last=$(tail -1 "$result_file" 2>/dev/null)
        if [[ -n "$last" ]]; then
            IFS='|' read -r last_heap last_status last_rss last_one <<< "$last"
            peak_rss="$last_rss"; peak_one="$last_one"
            if [[ "$last_status" == "OOM" ]]; then
                verdict="OOM at all tested heaps"
                gcp_tier="> ${last_heap}m needed"
            else
                verdict="build error (not OOM)"
                gcp_tier="investigate log"
            fi
        fi
    fi

    printf "%-16s %-10s %-11s %-10s %-11s %-20s %s\n" \
        "$app_slug" "$min_heap" "$peak_rss" "$peak_one" "$budget" "$gcp_tier" "$verdict" | tee -a "$REPORT"
done

rm -rf "$RESULTS_DIR"

log ""
if $all_pass; then
    log "✅ All apps fit within e2-micro budget — free tier is viable"
else
    log "⚠️  Some apps exceed e2-micro — see GCP_TIER column for the minimum VM per app"
    log ""
    log "Options:"
    log "  1. e2-small (2 GB, ~\$7/mo)    if all apps fit at ≤ 1500m"
    log "  2. e2-medium (4 GB, ~\$13/mo)  if any app needs > 1500m"
    log "  3. MAX_PARALLEL=1              builds run one at a time, peak RAM stays lower"
    log "  4. Cloud Build (120 free min/day)  offload the Gradle compile step"
fi

log ""
log "Full build logs: $LOG_DIR/"
log "Report saved:    $REPORT"
