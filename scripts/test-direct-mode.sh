#!/usr/bin/env bash
# Integration test for direct mode: submit → poll → verify AutoModerated Approve
set -euo pipefail

DB=$(mktemp /tmp/moderation-XXXXXX.db)
trap "rm -f '$DB'" EXIT

API_PORT=18080
BASE="http://localhost:$API_PORT"
CID="550e8400-e29b-41d4-a716-446655440001"

# Start the API server in the background
DB_PATH="$DB" ucm run Demo.Api.main &
API_PID=$!
trap "kill $API_PID 2>/dev/null; rm -f '$DB'" EXIT

# Wait for the server to be ready
for i in $(seq 1 30); do
  if curl -sf "$BASE/content/$CID" >/dev/null 2>&1; then
    break
  fi
  # 404 from our server means it's up
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/content/$CID" 2>/dev/null || true)
  if [ "$STATUS" = "404" ]; then
    break
  fi
  sleep 0.5
done

echo "=== Submit content ==="
SUBMIT=$(curl -sf -X POST "$BASE/content" \
  -H "content-type: application/json" \
  -d "{\"id\": \"$CID\", \"authorId\": \"alice\", \"text\": \"Hello world\"}")
echo "$SUBMIT"

echo ""
echo "=== Poll content state ==="
STATE=$(curl -sf "$BASE/content/$CID")
echo "$STATE"

echo ""
echo "=== Assertions ==="

STATUS_VAL=$(echo "$STATE" | jq -r '.status')
DECISION=$(echo "$STATE" | jq -r '.decision.type')

if [ "$STATUS_VAL" != "AutoModerated" ]; then
  echo "FAIL: expected status=AutoModerated, got $STATUS_VAL"
  exit 1
fi

if [ "$DECISION" != "Approve" ]; then
  echo "FAIL: expected decision=Approve, got $DECISION"
  exit 1
fi

echo "PASS: status=$STATUS_VAL, decision=$DECISION"
