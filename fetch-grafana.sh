#!/bin/bash
# Usage: ./fetch-grafana.sh <grafana_session> <app_name> <start> <end>
# Dates in format: "2026-02-28 22:18:00"
# Log lines are written to stdout; progress/errors go to stderr.
# Requires: curl, jq
#
# Run with Docker (no install needed):
#   1. Build: docker build -t fetch-grafana -f- . <<< $'FROM alpine\nRUN apk add --no-cache bash curl jq\nCOPY fetch-grafana.sh /fetch-grafana.sh\nRUN chmod +x /fetch-grafana.sh\nENTRYPOINT ["bash","/fetch-grafana.sh"]'
#   2. Run:   docker run --rm fetch-grafana <session> <app_name> "<start>" "<end>" > output.txt
#
# Example:
#   ./fetch-grafana.sh "abc123" "botcoapi-prod" "2026-04-01 22:18:00" "2026-04-01 22:26:00" > log1.txt

GRAFANA_SESSION="$1"
APP_NAME="$2"
START_STR="$3"
END_STR="$4"

if [ -z "$GRAFANA_SESSION" ] || [ -z "$APP_NAME" ] || [ -z "$START_STR" ] || [ -z "$END_STR" ]; then
  echo "Usage: $0 <grafana_session> <app_name> <start_date> <end_date>" >&2
  echo "" >&2
  echo "Example (local):" >&2
  echo "  $0 abc123 botcoapi-prod \"2026-04-01 22:18:00\" \"2026-04-01 22:26:00\" > log1.txt" >&2
  echo "" >&2
  echo "Example (Docker):" >&2
  echo "  # Build the image (once):" >&2
  echo "  docker build -t fetch-grafana -f- . <<< \$'FROM alpine\\nRUN apk add --no-cache bash curl jq\\nCOPY fetch-grafana.sh /fetch-grafana.sh\\nRUN chmod +x /fetch-grafana.sh\\nENTRYPOINT [\"bash\",\"/fetch-grafana.sh\"]'" >&2
  echo "" >&2
  echo "  # Run:" >&2
  echo "  docker run --rm fetch-grafana abc123 botcoapi-prod \"2026-04-01 22:18:00\" \"2026-04-01 22:26:00\" > log1.txt" >&2
  exit 1
fi

GRAFANA_URL="https://grafana.botco.ai"
DATASOURCE_UID="aeyder96xwflsa"
LIMIT=1000

# Convert dates to milliseconds
START_MS=$(date -u -d "$START_STR" +%s)000
END_MS=$(date -u -d "$END_STR" +%s)000
START_NS="${START_MS}000000"

echo "Fetching logs from $START_STR to $END_STR..." >&2

CURRENT_END_MS=$END_MS
PAGE=0
TOTAL=0
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

while true; do
  PAGE=$((PAGE + 1))
  RAW="$TMP_DIR/raw_$PAGE.json"

  CURRENT_END_DATE=$(date -u -d "@$((CURRENT_END_MS / 1000))" "+%Y-%m-%d %H:%M:%S")
  START_DATE=$(date -u -d "@$((START_MS / 1000))" "+%Y-%m-%d %H:%M:%S")
  echo "Page $PAGE: fetching $START_DATE → $CURRENT_END_DATE" >&2

  curl -s \
    -H "Cookie: grafana_session=$GRAFANA_SESSION" \
    -H "content-type: application/json" \
    -H "x-datasource-uid: $DATASOURCE_UID" \
    -H "x-grafana-org-id: 1" \
    -H "x-plugin-id: loki" \
    "$GRAFANA_URL/api/ds/query?ds_type=loki&requestId=fetch_$PAGE" \
    --data-raw "{\"queries\":[{\"refId\":\"A\",\"expr\":\"{app=\\\"${APP_NAME}\\\"}\",\"queryType\":\"range\",\"datasource\":{\"type\":\"loki\",\"uid\":\"$DATASOURCE_UID\"},\"direction\":\"backward\",\"maxLines\":$LIMIT,\"datasourceId\":2,\"intervalMs\":1000,\"maxDataPoints\":$LIMIT}],\"from\":\"$START_MS\",\"to\":\"$CURRENT_END_MS\"}" \
    -o "$RAW" || { echo "ERROR: curl failed" >&2; exit 1; }

  # Check for auth error
  if grep -q '"status":401\|"statusCode":401' "$RAW"; then
    echo "ERROR: Unauthorized (401) - grafana_session may be expired" >&2
    exit 1
  fi

  # Check for unexpected response
  if ! grep -q '"results"' "$RAW"; then
    echo "ERROR: Unexpected response:" >&2
    cat "$RAW" >&2
    exit 1
  fi

  # Extract tsNs (index 3) and Line (index 2) across all frames
  jq -r '
    .results.A.frames[] |
    .data.values as $v |
    range($v[2] | length) |
    [$v[3][.], $v[2][.]] | @tsv
  ' "$RAW" > "$TMP_DIR/page_$PAGE.tsv"

  COUNT=$(wc -l < "$TMP_DIR/page_$PAGE.tsv")
  TOTAL=$((TOTAL + COUNT))
  echo "Page $PAGE: $COUNT entries (total: $TOTAL)" >&2

  if [ "$COUNT" -eq 0 ]; then
    break
  fi

  # Oldest timestamp = smallest tsNs in this page
  OLDEST_TS=$(awk -F'\t' '{print $1}' "$TMP_DIR/page_$PAGE.tsv" | sort -n | head -1)
  OLDEST_DATE=$(date -u -d "@$((OLDEST_TS / 1000000000))" "+%Y-%m-%d %H:%M:%S")
  echo "Page $PAGE: oldest entry at $OLDEST_DATE" >&2

  if [ "$COUNT" -lt "$LIMIT" ] || [ "$OLDEST_TS" -le "$START_NS" ]; then
    break
  fi

  # Convert oldest tsNs to ms for next request
  CURRENT_END_MS=$(( (OLDEST_TS - 1) / 1000000 ))
done

# Merge, sort by timestamp, deduplicate, output only log lines
echo "Merging and sorting..." >&2
cat "$TMP_DIR"/page_*.tsv 2>/dev/null \
  | sort -t$'\t' -k1,1n \
  | sort -t$'\t' -k1,1n -u \
  | cut -f2-

FINAL=$(cat "$TMP_DIR"/page_*.tsv 2>/dev/null | sort -t$'\t' -k1,1n -u | wc -l)
echo "Done. $FINAL unique entries written to stdout" >&2
