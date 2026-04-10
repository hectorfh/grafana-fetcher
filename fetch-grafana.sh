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
LIMIT=1100

# Rotate token only if current session is expired or invalid
echo "Checking grafana_session token..." >&2
AUTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Cookie: grafana_session=$GRAFANA_SESSION" \
  "$GRAFANA_URL/api/user")

if [ "$AUTH_STATUS" = "401" ]; then
  echo "Token expired (401), rotating..." >&2
  ROTATE_RESPONSE=$(curl -s -D - -X POST \
    -H "Content-Type: application/json" \
    -H "Cookie: grafana_session=$GRAFANA_SESSION" \
    "$GRAFANA_URL/api/user/auth-tokens/rotate" \
    -o /dev/null)
  NEW_TOKEN=$(echo "$ROTATE_RESPONSE" | grep -i "^set-cookie:" | grep -o "grafana_session=[^;]*" | cut -d= -f2)
  if [ -n "$NEW_TOKEN" ]; then
    echo "Token rotated successfully." >&2
    GRAFANA_SESSION="$NEW_TOKEN"
  else
    echo "ERROR: Token expired and rotation failed. Check your session." >&2
    exit 1
  fi
else
  echo "Token is valid (HTTP $AUTH_STATUS)." >&2
fi

# Convert dates to milliseconds
START_MS=$(date -u -d "$START_STR" +%s)000
END_MS=$(date -u -d "$END_STR" +%s)000

echo "Fetching logs from $START_STR to $END_STR..." >&2

WINDOW_MS=60000  # max 1 minute per iteration
CURRENT_END_MS=$END_MS
PAGE=0
TOTAL=0
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

while true; do
  PAGE=$((PAGE + 1))
  RAW="$TMP_DIR/raw_$PAGE.json"

  # Limit this iteration to at most 1 minute
  PAGE_START_MS=$(( CURRENT_END_MS - WINDOW_MS ))
  if [ "$PAGE_START_MS" -lt "$START_MS" ]; then
    PAGE_START_MS=$START_MS
  fi
  PAGE_START_NS="${PAGE_START_MS}000000"

  CURRENT_END_DATE=$(date -u -d "@$((CURRENT_END_MS / 1000))" "+%Y-%m-%d %H:%M:%S")
  PAGE_START_DATE=$(date -u -d "@$((PAGE_START_MS / 1000))" "+%Y-%m-%d %H:%M:%S")
  echo "Page $PAGE: fetching $PAGE_START_DATE → $CURRENT_END_DATE" >&2

  curl -s \
    -H "Cookie: grafana_session=$GRAFANA_SESSION" \
    -H "content-type: application/json" \
    -H "x-datasource-uid: $DATASOURCE_UID" \
    -H "x-grafana-org-id: 1" \
    -H "x-plugin-id: loki" \
    "$GRAFANA_URL/api/ds/query?ds_type=loki&requestId=fetch_$PAGE" \
    --data-raw "{\"queries\":[{\"refId\":\"A\",\"expr\":\"{app=\\\"${APP_NAME}\\\"}\",\"queryType\":\"range\",\"datasource\":{\"type\":\"loki\",\"uid\":\"$DATASOURCE_UID\"},\"direction\":\"backward\",\"maxLines\":$LIMIT,\"datasourceId\":2,\"intervalMs\":1000,\"maxDataPoints\":$LIMIT}],\"from\":\"$PAGE_START_MS\",\"to\":\"$CURRENT_END_MS\"}" \
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
    # Empty window — advance to previous window or stop
    if [ "$PAGE_START_MS" -le "$START_MS" ]; then
      break
    fi
    CURRENT_END_MS=$PAGE_START_MS
    continue
  fi

  # Oldest timestamp = smallest tsNs in this page
  OLDEST_TS=$(awk -F'\t' '{print $1}' "$TMP_DIR/page_$PAGE.tsv" | sort -n | head -1)
  OLDEST_DATE=$(date -u -d "@$((OLDEST_TS / 1000000000))" "+%Y-%m-%d %H:%M:%S")
  echo "Page $PAGE: oldest entry at $OLDEST_DATE" >&2

  if [ "$COUNT" -lt "$LIMIT" ] || [ "$OLDEST_TS" -le "$PAGE_START_NS" ]; then
    # Window exhausted — advance to previous window or stop
    if [ "$PAGE_START_MS" -le "$START_MS" ]; then
      break
    fi
    CURRENT_END_MS=$PAGE_START_MS
    continue
  fi

  # Still within this window, paginate backward.
  # Do NOT subtract 1 before dividing: nanosecond precision is lost in the ms
  # API boundary, so (OLDEST_TS-1)/1e6 often equals OLDEST_TS/1e6, causing
  # entries that share the same millisecond to be silently skipped.
  # Instead, floor to the same millisecond and let the final sort -u deduplicate.
  NEXT_END_MS=$(( OLDEST_TS / 1000000 ))
  if [ "$NEXT_END_MS" -ge "$CURRENT_END_MS" ]; then
    # No progress possible at ms precision — avoid infinite loop.
    if [ "$PAGE_START_MS" -le "$START_MS" ]; then
      break
    fi
    CURRENT_END_MS=$PAGE_START_MS
    continue
  fi
  CURRENT_END_MS=$NEXT_END_MS
done

# Merge, sort by timestamp, deduplicate, output only log lines
echo "Merging and sorting..." >&2
cat "$TMP_DIR"/page_*.tsv 2>/dev/null \
  | sort -t$'\t' -k1,1n \
  | sort -t$'\t' -k1,1n -u \
  | cut -f2-

FINAL=$(cat "$TMP_DIR"/page_*.tsv 2>/dev/null | sort -t$'\t' -k1,1n -u | wc -l)
echo "Done. $FINAL unique entries written to stdout" >&2
