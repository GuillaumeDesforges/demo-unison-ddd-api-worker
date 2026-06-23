#!/usr/bin/env bash
# Integration test for direct mode: start API, submit content, verify AutoModerated Approve.
# Safe to run directly — auto-invokes nix-shell if needed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${IN_NIX_SHELL:-}" ]; then
  exec nix-shell "$SCRIPT_DIR/../shell.nix" --run "bash $0 $*"
fi

set -euo pipefail

DB=$(mktemp /tmp/moderation-XXXXXX.db)
API_PID=""
trap 'kill "$API_PID" 2>/dev/null || true; rm -f "$DB"' EXIT

BASE="http://localhost:8080"
CID="550e8400-e29b-41d4-a716-000000000001"

echo "=== Starting API server (direct mode) ==="
DB_PATH="$DB" ucm run '@guillaumedesforges/demo-unison-ddd-api-worker/main:.Demo.Api.main' &
API_PID=$!

# Wait for the server to respond with 404 (means it's up)
for i in $(seq 1 40); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/content/$CID" 2>/dev/null || true)
  [ "$STATUS" = "404" ] && echo "Server up after ${i}s" && break
  sleep 0.5
done

echo ""
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
STATUS_VAL=$(echo "$STATE" | jq -r '.status.type')
DECISION=$(echo "$STATE" | jq -r '.status.decision.type')

[ "$STATUS_VAL" = "AutoModerated" ] || { echo "FAIL: expected AutoModerated, got $STATUS_VAL"; exit 1; }
[ "$DECISION"   = "Approve"        ] || { echo "FAIL: expected Approve, got $DECISION"; exit 1; }
echo "PASS: status=$STATUS_VAL, decision=$DECISION"
