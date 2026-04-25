#!/usr/bin/env bash
# elastic-agent-perf.sh
# Extracts component performance metrics from Elastic Agent diagnostic NDJSON logs
# into five analysis-ready TSV files.
#
# Usage:
#   ./elastic-agent-perf.sh [options] [log-dir]
#
# Options:
#   --all                    Analyze all discovered components (no prompt)
#   --component <id>         Analyze a specific component ID (exact match)
#   --component-regex <pat>  Analyze components whose ID matches a regex
#   --list                   List discovered components and exit
#
# Examples:
#   ./elastic-agent-perf.sh --all .
#   ./elastic-agent-perf.sh --component filestream-7d25f7b1 /path/to/logs
#   ./elastic-agent-perf.sh --component-regex winlog .
#   ./elastic-agent-perf.sh --list /path/to/logs
#
# Outputs to:  <log-dir>/perf-analysis-YYYYMMDD-HHMMSS/
#   A-output-health.tsv     — libbeat output counters + write latency
#   B-pipeline-queue.tsv    — pipeline event flow + queue depth
#   C-beat-resources.tsv    — CPU, memory, goroutines, filebeat harvester gauges (when present)
#   D-input-processing.tsv  — per-dataset-key codec/ingress processing time (monitoring.dataset; histogram.count>0 only)
#   E-health-ratios.tsv     — derived success/error/saturation ratios
#
# Field notes:
#   Counters (ACKED, FAILED, etc.)  — 30s deltas, pre-computed by monitoring layer
#   Histograms (LAT_*, Q_PCT etc.)  — lifetime reservoir gauges, NOT deltas
#   FB_ACTIVE                       — events in filebeat input buffer (pre-pipeline)
#   OUT_ACTIVE                      — events in-flight to output worker (post-queue)
#
# Failure mode signatures:
#   Input stall:            FB_ACTIVE≥0, PIPE_ACTIVE=0, OUT_ACTIVE=0, ACKED=0
#   Pipeline stall:         PIPE_ACTIVE>0, OUT_ACTIVE=0, ACKED=0
#   Output worker deadlock: OUT_ACTIVE>0, Q_PCT=1, ACKED=0, LAT_P999 extreme

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Parse flags
# ─────────────────────────────────────────────────────────────────────────────
OPT_ALL=false
OPT_COMPONENT=""
OPT_REGEX=""
OPT_LIST=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)               OPT_ALL=true;           shift ;;
    --component)         OPT_COMPONENT="$2";     shift 2 ;;
    --component-regex)   OPT_REGEX="$2";         shift 2 ;;
    --list)              OPT_LIST=true;           shift ;;
    --help|-h)
      sed -n '2,/^set -/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*)  echo "Unknown option: $1"; exit 1 ;;
    *)   break ;;
  esac
done

LOG_DIR="${1:-.}"
FILES=$(ls -1 "${LOG_DIR}"/elastic-agent-*.ndjson 2>/dev/null | sort -V)

if [[ -z "$FILES" ]]; then
  echo "No elastic-agent-*.ndjson files found in: ${LOG_DIR}"
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR="${LOG_DIR}/perf-analysis-${TIMESTAMP}"
mkdir -p "$OUT_DIR"

SEP="═══════════════════════════════════════════════════════"

echo ""
echo "$SEP"
echo " Elastic Agent component performance"
echo "$SEP"
echo " Log dir   : ${LOG_DIR}"
echo " Output    : ${OUT_DIR}"
printf " Files     : %d\n" "$(echo "$FILES" | wc -l | tr -d ' ')"
echo " Time range: $(jq -rn '[inputs | .["@timestamp"]] | sort | first' $FILES)"
echo "           → $(jq -rn '[inputs | .["@timestamp"]] | sort | last'  $FILES)"
echo "$SEP"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 1. Discover components
# ─────────────────────────────────────────────────────────────────────────────
echo "Discovering components..."

COMPONENTS=$(jq -rn '
  [inputs | {
    binary:  (.["component.binary"] // .component.binary),
    dataset: (.["component.dataset"] // .component.dataset),
    ctype:   (.["component.type"]   // .component.type),
    cid:     (.["component.id"]    // .component.id)
  }] |
  unique_by(.cid) |
  .[] |
  select(.cid != null and (.cid|tostring|length) > 0) |
  [.binary, .dataset, .ctype, .cid] | @tsv
' $FILES)

if [[ -z "$COMPONENTS" ]]; then
  echo "No component monitoring data found in these files."
  exit 1
fi

# ── Print component table (always shown unless piped away) ──────────────────
echo ""
echo "  #  Binary       Type                     Component ID"
echo "  -- ------------ ------------------------ ----------------------------------------"
i=1
while IFS=$'\t' read -r binary dataset ctype cid; do
  printf "  %-2s %-12s %-24s %s\n" "$i" "$binary" "$ctype" "$cid"
  i=$((i+1))
done <<< "$COMPONENTS"
echo ""

# ── --list: print table and exit ────────────────────────────────────────────
if [[ "$OPT_LIST" == true ]]; then
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Build component filter
# ─────────────────────────────────────────────────────────────────────────────
SELECTED_IDS=()

if [[ "$OPT_ALL" == true ]]; then
  # --all: take every discovered component
  while IFS=$'\t' read -r binary dataset ctype cid; do
    SELECTED_IDS+=("$cid")
  done <<< "$COMPONENTS"

elif [[ -n "$OPT_COMPONENT" ]]; then
  # --component <id>: exact match (partial prefix allowed)
  while IFS=$'\t' read -r binary dataset ctype cid; do
    if [[ "$cid" == *"$OPT_COMPONENT"* ]]; then
      SELECTED_IDS+=("$cid")
    fi
  done <<< "$COMPONENTS"
  if [[ ${#SELECTED_IDS[@]} -eq 0 ]]; then
    echo "No component matching '$OPT_COMPONENT' found."
    exit 1
  fi

elif [[ -n "$OPT_REGEX" ]]; then
  # --component-regex <pattern>: grep -E match against component ID
  while IFS=$'\t' read -r binary dataset ctype cid; do
    if echo "$cid" | grep -qE "$OPT_REGEX"; then
      SELECTED_IDS+=("$cid")
    fi
  done <<< "$COMPONENTS"
  if [[ ${#SELECTED_IDS[@]} -eq 0 ]]; then
    echo "No components matching regex '$OPT_REGEX' found."
    exit 1
  fi

else
  # Interactive: prompt if stdin is a terminal, otherwise select all
  if [[ -t 0 ]]; then
    echo "Enter component numbers to analyze (e.g. 1 3), or press Enter for ALL:"
    read -r SELECTION
    echo ""
    if [[ -z "$SELECTION" ]]; then
      while IFS=$'\t' read -r binary dataset ctype cid; do
        SELECTED_IDS+=("$cid")
      done <<< "$COMPONENTS"
    else
      for num in $SELECTION; do
        row=$(echo "$COMPONENTS" | sed -n "${num}p")
        cid=$(echo "$row" | cut -f4)
        SELECTED_IDS+=("$cid")
      done
    fi
  else
    # stdin is not a terminal (piped/automated) — select all silently
    echo "Non-interactive mode: analyzing all components."
    while IFS=$'\t' read -r binary dataset ctype cid; do
      SELECTED_IDS+=("$cid")
    done <<< "$COMPONENTS"
  fi
fi

if [[ ${#SELECTED_IDS[@]} -eq 0 ]]; then
  echo "No components selected. Exiting."
  exit 1
fi

echo "Analyzing: ${SELECTED_IDS[*]}"
echo ""

# Build jq OR-filter for selected component IDs (flat + nested component.* from OTel-shaped lines)
CID_FILTER=$(printf '((.["component.id"] // .component.id // "") == "%s")' "${SELECTED_IDS[0]}")
for cid in "${SELECTED_IDS[@]:1}"; do
  CID_FILTER+=$(printf ' or ((.["component.id"] // .component.id // "") == "%s")' "$cid")
done

# ─────────────────────────────────────────────────────────────────────────────
# 3. Helper — run a jq table, write TSV, report row count
# ─────────────────────────────────────────────────────────────────────────────
run_table() {
  local label="$1"
  local filename="$2"
  local jq_expr="$3"
  local outfile="${OUT_DIR}/${filename}"

  printf "  %-42s" "$label..."
  jq -rn "$jq_expr" $FILES | column -t -s $'\t' > "$outfile"
  local rows=$(( $(wc -l < "$outfile") - 1 ))
  echo " ${rows} rows -> ${filename}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Table A -- Output Health
#
# FB_ACTIVE   events in the filebeat input buffer (pre-pipeline)
#             Source: .monitoring.metrics.filebeat.events.active
#             High + PIPE_ACTIVE=0  -> input-to-pipeline stall
#
# OUT_ACTIVE  events currently in-flight to the output worker
#             Source: .monitoring.metrics.libbeat.output.events.active
#             High + ACKED=0        -> output worker deadlock (ES not responding)
#
# LAT_P999    99.9th percentile write latency (lifetime reservoir, nanoseconds)
#             Extreme tail reveals ES acknowledgement hangs
#             Example: LAT_P95=1502ms but LAT_P999=13908ms signals a severe hang
# ─────────────────────────────────────────────────────────────────────────────
run_table "Table A: Output Health" "A-output-health.tsv" '
  ["TIMESTAMP","COMPONENT_ID","ACKED","FAILED","429s","DROPPED","DUPES",
   "FB_ACTIVE","OUT_ACTIVE","BATCHES","WRITE_B","READ_B",
   "LAT_MEAN","LAT_MED","LAT_P95","LAT_P99","LAT_P999","LAT_MAX"] | @tsv,
  (inputs |
    select(('"$CID_FILTER"') and (.monitoring.metrics.libbeat != null)) |
    .["@timestamp"] as $ts |
    (.["component.id"] // .component.id // "") as $cid |
    (.monitoring.metrics.filebeat.events.active // 0) as $fb_active |
    .monitoring.metrics.libbeat |
    [
      $ts, $cid,
      (.output.events.acked                          // 0),
      (.output.events.failed                         // 0),
      (.output.events.toomany                        // 0),
      (.output.events.dropped                        // 0),
      (.output.events.duplicates                     // 0),
      $fb_active,
      (.output.events.active                         // 0),
      (.output.events.batches                        // 0),
      (.output.write.bytes                           // 0),
      (.output.read.bytes                            // 0),
      (.output.write.latency.histogram.mean          // 0),
      (.output.write.latency.histogram.median        // 0),
      (.output.write.latency.histogram.p95           // 0),
      (.output.write.latency.histogram.p99           // 0),
      (.output.write.latency.histogram.p999          // 0),
      (.output.write.latency.histogram.max           // 0)
    ] | @tsv
  )
'

# ─────────────────────────────────────────────────────────────────────────────
# Table B -- Pipeline & Queue Health
# ─────────────────────────────────────────────────────────────────────────────
run_table "Table B: Pipeline & Queue" "B-pipeline-queue.tsv" '
  ["TIMESTAMP","COMPONENT_ID","CLIENTS","PIPE_ACTIVE","PUBLISHED","FILTERED",
   "RETRY","DROPPED","Q_FILLED","Q_MAX","Q_PCT","Q_ADDED","Q_REMOVED","MODULES"] | @tsv,
  (inputs |
    select(('"$CID_FILTER"') and (.monitoring.metrics.libbeat != null)) |
    .["@timestamp"] as $ts |
    (.["component.id"] // .component.id // "") as $cid |
    .monitoring.metrics.libbeat |
    [
      $ts, $cid,
      (.pipeline.clients              // 0),
      (.pipeline.events.active        // 0),
      (.pipeline.events.published     // 0),
      (.pipeline.events.filtered      // 0),
      (.pipeline.events.retry         // 0),
      (.pipeline.events.dropped       // 0),
      (.pipeline.queue.filled.events  // 0),
      (.pipeline.queue.max_events     // 0),
      (.pipeline.queue.filled.pct     // 0),
      (.pipeline.queue.added.events   // 0),
      (.pipeline.queue.removed.events // 0),
      (.config.module.running         // 0)
    ] | @tsv
  )
'

# ─────────────────────────────────────────────────────────────────────────────
# Table C -- Beat Resource Usage
# ─────────────────────────────────────────────────────────────────────────────
run_table "Table C: Beat Resources" "C-beat-resources.tsv" '
  ["TIMESTAMP","COMPONENT_ID","VERSION","UPTIME_s",
   "CPU_TOTAL_ms","CPU_USER_ms","CPU_SYS_ms",
   "MEM_ALLOC_MB","RSS_MB","GOROUTINES",
   "HARV_RUNNING","HARV_FILES"] | @tsv,
  (inputs |
    select(('"$CID_FILTER"') and (.monitoring.metrics.beat != null)) |
    .["@timestamp"] as $ts |
    (.["component.id"] // .component.id // "") as $cid |
    .monitoring.metrics as $m |
    $m.beat |
    [
      $ts, $cid,
      .info.version,
      (.info.uptime.ms / 1000 | round),
      (.cpu.total.time.ms       // 0),
      (.cpu.user.time.ms        // 0),
      (.cpu.system.time.ms      // 0),
      (.memstats.memory_alloc / 1048576 | round),
      (.memstats.rss          / 1048576 | round),
      (.runtime.goroutines      // 0),
      (($m.filebeat.harvester.running   // 0)),
      (($m.filebeat.harvester.open_files // 0))
    ] | @tsv
  )
'

# ─────────────────────────────────────────────────────────────────────────────
# Table D -- Per-input processing times (active inputs only)
# Histograms are lifetime reservoirs (nanoseconds -> milliseconds)
# COUNT = processing_time.histogram.count (number of latency observations in the reservoir, not "events/sec")
# Frozen count across all intervals = no new histogram observations in this capture window
# ─────────────────────────────────────────────────────────────────────────────
run_table "Table D: Per-input processing" "D-input-processing.tsv" '
  ["TIMESTAMP","COMPONENT_ID","INPUT_ID",
   "COUNT","MEAN_ms","MEDIAN_ms","P95_ms","P99_ms","MAX_ms","STDDEV_ms"] | @tsv,
  (inputs |
    select(('"$CID_FILTER"') and (.monitoring.dataset != null)) |
    .["@timestamp"] as $ts |
    (.["component.id"] // .component.id // "") as $cid |
    .monitoring.dataset | to_entries[] |
    select(.value.processing_time.histogram.count > 0) |
    .key as $iid |
    .value.processing_time.histogram |
    [
      $ts, $cid, $iid,
      .count,
      (.mean   / 1000000 | round),
      (.median / 1000000 | round),
      (.p95    / 1000000 | round),
      (.p99    / 1000000 | round),
      (.max    / 1000000 | round),
      (.stddev / 1000000 | round)
    ] | @tsv
  )
'

# ─────────────────────────────────────────────────────────────────────────────
# Table E -- Derived Health Ratios (per 30s window)
# ─────────────────────────────────────────────────────────────────────────────
run_table "Table E: Health Ratios" "E-health-ratios.tsv" '
  ["TIMESTAMP","COMPONENT_ID","TOTAL","ACKED",
   "SUCCESS_%","429_%","DROP_%","DUPE_%","RETRY_%",
   "AVG_BATCH","QUEUE_STATUS"] | @tsv,
  (inputs |
    select(('"$CID_FILTER"') and (.monitoring.metrics.libbeat != null)) |
    .["@timestamp"] as $ts |
    (.["component.id"] // .component.id // "") as $cid |
    .monitoring.metrics.libbeat |
    (.output.events.acked       // 0) as $acked   |
    (.output.events.failed      // 0) as $failed  |
    (.output.events.toomany     // 0) as $toomany |
    (.output.events.dropped     // 0) as $dropped |
    (.output.events.duplicates  // 0) as $dupes   |
    (.output.events.batches     // 0) as $batches |
    (.pipeline.events.retry     // 0) as $retry   |
    (.pipeline.events.published // 0) as $pub     |
    (.pipeline.queue.filled.pct // 0) as $qpct    |
    ($acked + $failed + $dropped + $dupes) as $total |
    [
      $ts, $cid,
      $total, $acked,
      (if $total > 0 then ($acked   / $total * 1000  | round) / 10  else 0   end),
      (if $total > 0 then ($toomany / $total * 10000 | round) / 100 else 0   end),
      (if $total > 0 then ($dropped / $total * 10000 | round) / 100 else 0   end),
      (if $total > 0 then ($dupes   / $total * 10000 | round) / 100 else 0   end),
      (if $pub   > 0 then ($retry   / $pub   * 10000 | round) / 100 else 0   end),
      (if $batches > 0 then ($total / $batches | round) else 0 end),
      (if $qpct >= 1    then "FULL"
       elif $qpct >= 0.8 then "HIGH"
       elif $qpct >= 0.5 then "MED"
       else "OK" end)
    ] | @tsv
  )
'

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "$SEP"
echo " Output files:"
echo "$SEP"
ls -lh "$OUT_DIR"/*.tsv | awk '{printf "  %-8s %s\n", $5, $9}'
echo ""
echo " View in browser   : open input-analyzer.html"
echo " Open folder      : open ${OUT_DIR}"
echo "$SEP"
echo ""
