#!/usr/bin/env bash
# Integration test for Restate mode.
#
# Prerequisites (run before this script):
#   Terminal 1: restate-server --base-dir $(mktemp -d)
#   Terminal 2: DB_PATH=/tmp/test.db ucm run Demo.Worker.main
#
# This script:
#   1. Creates the SQLite schema and inserts a test content row
#   2. Registers the worker with Restate
#   3. Invokes the saga via Restate ingress (synchronous)
#   4. Reads the result from SQLite and asserts correctness
set -euo pipefail

RESTATE_INGRESS="${RESTATE_INGRESS:-http://localhost:8080}"
RESTATE_ADMIN="${RESTATE_ADMIN:-http://localhost:9070}"
WORKER_URL="${WORKER_URL:-http://localhost:9080}"
DB="${DB_PATH:-/tmp/test-restate.db}"

CID="550e8400-e29b-41d4-a716-446655440002"

echo "=== Init DB and insert content ==="
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS content (id TEXT PRIMARY KEY, author_id TEXT NOT NULL, text_content TEXT NOT NULL, created_at INTEGER NOT NULL, status TEXT NOT NULL, decision TEXT, decision_reason TEXT, awakeable_id TEXT)"
sqlite3 "$DB" "DELETE FROM content WHERE id = '$CID'"
sqlite3 "$DB" "INSERT INTO content (id, author_id, text_content, created_at, status) VALUES ('$CID', 'alice', 'Hello world', 1234567890, 'Submitted')"

echo "=== Register worker with Restate ==="
curl -sf -X POST "$RESTATE_ADMIN/deployments" \
  -H 'content-type: application/json' \
  -d "{\"uri\": \"$WORKER_URL\", \"use_http_11\": true}"
echo ""

echo "=== Invoke ModerationService/moderate ==="
curl -sf -X POST "$RESTATE_INGRESS/ModerationService/moderate" \
  -H 'content-type: application/octet-stream' \
  --data-raw "$CID" \
  --max-time 30
echo ""

echo "=== Assertions ==="
STATUS=$(sqlite3 "$DB" "SELECT status FROM content WHERE id = '$CID'")
DECISION=$(sqlite3 "$DB" "SELECT decision FROM content WHERE id = '$CID'")

if [ "$STATUS" != "AutoModerated" ]; then
  echo "FAIL: expected status=AutoModerated, got $STATUS"
  exit 1
fi
if [ "$DECISION" != "Approve" ]; then
  echo "FAIL: expected decision=Approve, got $DECISION"
  exit 1
fi
echo "PASS: status=$STATUS, decision=$DECISION"

echo ""
echo "=== Human review flow (manual steps) ==="
echo "If the saga escalates to human review, the awakeable_id is stored in SQLite:"
echo "  sqlite3 $DB \"SELECT awakeable_id FROM content WHERE id = '$CID'\""
echo "Complete the awakeable via Restate:"
echo "  curl -X POST $RESTATE_INGRESS/restate/awakeables/<id>/resolve \\"
echo "    -H 'content-type: application/octet-stream' --data-raw 'Approve'"
