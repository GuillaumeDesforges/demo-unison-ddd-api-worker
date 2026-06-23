#!/usr/bin/env bash
# Integration test for Restate mode.
#
# Prerequisites (all inside nix-shell, before running this script):
#   Terminal 1: restate-server --base-dir $(mktemp -d)
#   Terminal 2: DB_PATH=/tmp/mod-restate.db \
#               ucm run '@guillaumedesforges/demo-unison-ddd-api-worker/main:.Demo.Worker.main'
#
# This script assumes the worker is already registered with Restate.
# If not, it will register it automatically.
set -euo pipefail

RESTATE_INGRESS="${RESTATE_INGRESS:-http://localhost:8080}"
RESTATE_ADMIN="${RESTATE_ADMIN:-http://localhost:9070}"
WORKER_URL="${WORKER_URL:-http://localhost:9080}"
DB="${DB_PATH:-/tmp/mod-restate.db}"
CID="550e8400-e29b-41d4-a716-000000000002"

echo "=== Init DB and insert content ==="
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS content (
  id TEXT PRIMARY KEY, author_id TEXT NOT NULL, text_content TEXT NOT NULL,
  created_at INTEGER NOT NULL, status TEXT NOT NULL,
  decision TEXT, decision_reason TEXT)"
sqlite3 "$DB" "DELETE FROM content WHERE id = '$CID'"
sqlite3 "$DB" "INSERT INTO content (id, author_id, text_content, created_at, status)
  VALUES ('$CID', 'alice', 'Hello Restate', 1234567890, 'Submitted')"
echo "Inserted $CID"

echo ""
echo "=== Register worker with Restate ==="
curl -sf -X POST "$RESTATE_ADMIN/deployments" \
  -H 'content-type: application/json' \
  -d "{\"uri\": \"$WORKER_URL\", \"use_http_11\": true}" \
  | jq -r '.services[0].name + " registered"'

echo ""
echo "=== Invoke ModerationService/moderate via Restate ingress ==="
curl -sf -X POST "$RESTATE_INGRESS/ModerationService/moderate" \
  -H 'content-type: application/octet-stream' \
  --data-raw "$CID" \
  --max-time 30
echo ""

echo ""
echo "=== Assertions ==="
STATUS=$(sqlite3 "$DB" "SELECT status   FROM content WHERE id = '$CID'")
DECISION=$(sqlite3 "$DB" "SELECT decision FROM content WHERE id = '$CID'")

[ "$STATUS"   = "AutoModerated" ] || { echo "FAIL: expected AutoModerated, got $STATUS";  exit 1; }
[ "$DECISION" = "Approve"       ] || { echo "FAIL: expected Approve, got $DECISION"; exit 1; }
echo "PASS: status=$STATUS, decision=$DECISION"

echo ""
echo "=== Human review flow (manual) ==="
echo "To test escalation: change the classifier stub to return Escalate,"
echo "then once content status is PendingHumanReview, resolve it via the API:"
echo "  curl -X POST \${API_URL:-http://localhost:8081}/content/$CID/review \\"
echo "    -H 'content-type: application/json' -d '{\"decision\":\"Approve\"}'"
