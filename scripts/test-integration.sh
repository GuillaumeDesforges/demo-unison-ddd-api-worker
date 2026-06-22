#!/usr/bin/env bash
# Combined integration test: runs direct-mode (self-contained) then Restate-mode
# (skipped if Restate server / worker are not running).
set -euo pipefail

PASS=0
FAIL=0

check() {
  local label=$1 expected=$2 actual=$3
  if [ "$actual" = "$expected" ]; then
    echo "  PASS $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $label: expected='$expected' got='$actual'"
    FAIL=$((FAIL + 1))
  fi
}

# ── Direct mode ───────────────────────────────────────────────────────────────
echo ""
echo "=== Direct mode ==="

DB_DIRECT=$(mktemp /tmp/mod-direct-XXXXXX.db)
CID_DIRECT="550e8400-e29b-41d4-a716-000000000001"

DB_PATH="$DB_DIRECT" \
  ucm run '@guillaumedesforges/demo-unison-ddd-api-worker/main:.Demo.Api.main' &
API_PID=$!
trap 'kill "$API_PID" 2>/dev/null || true; rm -f "$DB_DIRECT"' EXIT

for i in $(seq 1 40); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://localhost:8080/content/$CID_DIRECT" 2>/dev/null || true)
  [ "$STATUS" = "404" ] && echo "  Server up after ${i}s" && break
  sleep 0.5
done

curl -sf -X POST http://localhost:8080/content \
  -H "content-type: application/json" \
  -d "{\"id\":\"$CID_DIRECT\",\"authorId\":\"alice\",\"text\":\"Hello world\"}" \
  -o /dev/null

STATE=$(curl -sf "http://localhost:8080/content/$CID_DIRECT")
check "direct/status"   "AutoModerated" "$(echo "$STATE" | jq -r '.status.type')"
check "direct/decision" "Approve"       "$(echo "$STATE" | jq -r '.status.decision.type')"

kill "$API_PID" 2>/dev/null || true
trap 'rm -f "$DB_DIRECT"' EXIT

# ── Restate mode ─────────────────────────────────────────────────────────────
echo ""
echo "=== Restate mode ==="

RESTATE_INGRESS="${RESTATE_INGRESS:-http://localhost:8080}"
RESTATE_ADMIN="${RESTATE_ADMIN:-http://localhost:9070}"
WORKER_URL="${WORKER_URL:-http://localhost:9080}"
DB_RESTATE="${DB_PATH:-/tmp/mod-restate.db}"
CID_RESTATE="550e8400-e29b-41d4-a716-000000000002"

if ! curl -sf "$RESTATE_ADMIN/health" >/dev/null 2>&1; then
  echo "  SKIP Restate server not running"
  echo "       Start with: restate-server --base-dir \$(mktemp -d)"
elif ! curl -sf "$WORKER_URL/discover" >/dev/null 2>&1; then
  echo "  SKIP Worker not running"
  echo "       Start with: DB_PATH=$DB_RESTATE ucm run '@guillaumedesforges/demo-unison-ddd-api-worker/main:.Demo.Worker.main'"
else
  sqlite3 "$DB_RESTATE" "CREATE TABLE IF NOT EXISTS content (
    id TEXT PRIMARY KEY, author_id TEXT NOT NULL, text_content TEXT NOT NULL,
    created_at INTEGER NOT NULL, status TEXT NOT NULL,
    decision TEXT, decision_reason TEXT, awakeable_id TEXT)" 2>/dev/null || true
  sqlite3 "$DB_RESTATE" "DELETE FROM content WHERE id = '$CID_RESTATE'"
  sqlite3 "$DB_RESTATE" "INSERT INTO content (id, author_id, text_content, created_at, status)
    VALUES ('$CID_RESTATE', 'bob', 'Hello Restate', 1234567890, 'Submitted')"

  curl -sf -X POST "$RESTATE_ADMIN/deployments" \
    -H 'content-type: application/json' \
    -d "{\"uri\":\"$WORKER_URL\",\"use_http_11\":true}" -o /dev/null

  curl -sf -X POST "$RESTATE_INGRESS/ModerationService/moderate" \
    -H 'content-type: application/octet-stream' \
    --data-raw "$CID_RESTATE" --max-time 30 -o /dev/null

  STATUS_R=$(sqlite3 "$DB_RESTATE" "SELECT status   FROM content WHERE id = '$CID_RESTATE'")
  DECISION_R=$(sqlite3 "$DB_RESTATE" "SELECT decision FROM content WHERE id = '$CID_RESTATE'")
  check "restate/status"   "AutoModerated" "$STATUS_R"
  check "restate/decision" "Approve"       "$DECISION_R"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ] || exit 1
