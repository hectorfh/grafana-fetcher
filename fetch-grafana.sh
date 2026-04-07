#!/bin/bash
# Usage: ./fetch-grafana.sh <grafana_session> <app_name> <start> <end>
# Dates in format: "2026-02-28 22:18:00"
# Log lines are written to stdout; progress/errors go to stderr.
#
# Run with Docker (no install needed):
#   1. Build: docker build -t fetch-grafana -f- . <<< $'FROM alpine\nRUN apk add --no-cache bash curl\nCOPY fetch-grafana.sh /fetch-grafana.sh\nRUN chmod +x /fetch-grafana.sh\nENTRYPOINT ["bash","/fetch-grafana.sh"]'
#   2. Run:   docker run --rm fetch-grafana <session> <app_name> "<start>" "<end>" > output.txt
#
# Example:
#   ./fetch-grafana.sh "abc123" "wb-506-dpl-521" "2026-02-28 22:18:00" "2026-02-28 22:26:00" > log1.txt

GRAFANA_SESSION="$1"
APP_NAME="$2"
START_STR="$3"
END_STR="$4"

if [ -z "$GRAFANA_SESSION" ] || [ -z "$APP_NAME" ] || [ -z "$START_STR" ] || [ -z "$END_STR" ]; then
  echo "Usage: $0 <grafana_session> <app_name> <start_date> <end_date>" >&2
  echo "" >&2
  echo "Example (local):" >&2
  echo "  $0 abc123 wb-506-dpl-521 \"2026-02-28 22:18:00\" \"2026-02-28 22:26:00\" > log1.txt" >&2
  echo "" >&2
  echo "Example (Docker):" >&2
  echo "  # Build the image (once):" >&2
  echo "  docker build -t fetch-grafana -f- . <<< \$'FROM alpine\\nRUN apk add --no-cache bash curl\\nCOPY fetch-grafana.sh /fetch-grafana.sh\\nRUN chmod +x /fetch-grafana.sh\\nENTRYPOINT [\"bash\",\"/fetch-grafana.sh\"]'" >&2
  echo "" >&2
  echo "  # Run:" >&2
  echo "  docker run --rm fetch-grafana abc123 wb-506-dpl-521 \"2026-02-28 22:18:00\" \"2026-02-28 22:26:00\" > log1.txt" >&2
  exit 1
fi

LOKI_URL="https://grafana.botco.ai/api/datasources/proxy/uid/aeyder96xwflsa/loki/api/v1/query_range"
QUERY="%7Bapp%3D%22${APP_NAME}%22%7D"
LIMIT=5000

# Convert dates to nanoseconds
START_NS=$(date -u -d "$START_STR" +%s)000000000
END_NS=$(date -u -d "$END_STR" +%s)000000000

echo "Fetching logs from $START_STR to $END_STR..." >&2

CURRENT_END=$END_NS
PAGE=0
TOTAL=0
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

while true; do
  PAGE=$((PAGE + 1))
  RAW="$TMP_DIR/raw_$PAGE.json"

  CURRENT_END_DATE=$(date -u -d "@$((CURRENT_END / 1000000000))" "+%Y-%m-%d %H:%M:%S")
  START_DATE=$(date -u -d "@$((START_NS / 1000000000))" "+%Y-%m-%d %H:%M:%S")
  echo "Page $PAGE: fetching $START_DATE → $CURRENT_END_DATE" >&2

  curl -s \
    -H "Cookie: grafana_session=$GRAFANA_SESSION" \
    "$LOKI_URL?query=$QUERY&start=$START_NS&end=$CURRENT_END&limit=$LIMIT&direction=backward" \
    -o "$RAW" || { echo "ERROR: curl failed" >&2; exit 1; }

  # Check for auth error
  if grep -q '"statusCode":401' "$RAW"; then
    echo "ERROR: Unauthorized (401) - grafana_session may be expired" >&2
    exit 1
  fi

  # Check for any other error
  if ! grep -q '"status":"success"' "$RAW"; then
    echo "ERROR: Unexpected response:" >&2
    cat "$RAW" >&2
    exit 1
  fi

  # Parse ["ts","line"] pairs from the values arrays
  # values":[["1234","log line"],["1235","log line2"]]
  sed 's/\],\[/\n/g' "$RAW" \
    | grep -o '"[0-9]\{19\}","[^"]*"' \
    | sed 's/^"\([0-9]*\)","\(.*\)"$/\1\t\2/' \
    > "$TMP_DIR/page_$PAGE.tsv"

  COUNT=$(wc -l < "$TMP_DIR/page_$PAGE.tsv")
  TOTAL=$((TOTAL + COUNT))
  echo "Page $PAGE: $COUNT entries (total: $TOTAL)" >&2

  if [ "$COUNT" -eq 0 ]; then
    break
  fi

  # Oldest timestamp = smallest ts in this page
  OLDEST_TS=$(awk -F'\t' '{print $1}' "$TMP_DIR/page_$PAGE.tsv" | sort -n | head -1)
  OLDEST_DATE=$(date -u -d "@$((OLDEST_TS / 1000000000))" "+%Y-%m-%d %H:%M:%S")
  echo "Page $PAGE: oldest entry at $OLDEST_DATE, next end will be $((OLDEST_TS - 1))" >&2

  if [ "$COUNT" -lt "$LIMIT" ] || [ "$OLDEST_TS" -le "$START_NS" ]; then
    break
  fi

  CURRENT_END=$((OLDEST_TS - 1))
done

# Merge, sort by timestamp, deduplicate, output only log lines
echo "Merging and sorting..." >&2
cat "$TMP_DIR"/page_*.tsv 2>/dev/null \
  | sort -t$'\t' -k1,1n \
  | sort -t$'\t' -k1,1n -u \
  | cut -f2-

FINAL=$(cat "$TMP_DIR"/page_*.tsv 2>/dev/null | sort -t$'\t' -k1,1n -u | wc -l)
echo "Done. $FINAL unique entries written to stdout" >&2
