#!/usr/bin/env bash
# Self-contained Restate mode demo.
# Starts restate-server + saga worker, runs a full roundtrip, then cleans up.
# Safe to run directly — auto-invokes nix-shell if needed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${IN_NIX_SHELL:-}" ]; then
  exec nix-shell "$SCRIPT_DIR/../shell.nix" --run "bash $0 $*"
fi

set -euo pipefail

DB=$(mktemp /tmp/mod-restate-XXXXXX.db)
RESTATE_BASE=$(mktemp -d)
RESTATE_PID=""
WORKER_PID=""

cleanup() {
  echo ""
  echo "=== Cleanup ==="
  [ -n "$WORKER_PID"  ] && kill "$WORKER_PID"  2>/dev/null || true
  [ -n "$RESTATE_PID" ] && kill "$RESTATE_PID" 2>/dev/null || true
  rm -f "$DB"
}
trap cleanup EXIT

CID="550e8400-e29b-41d4-a716-000000000003"

# ── Restate server ─────────────────────────────────────────────────────────────
echo "=== Starting Restate server ==="
restate-server --base-dir "$RESTATE_BASE" >/tmp/restate-server.log 2>&1 &
RESTATE_PID=$!

for i in $(seq 1 20); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9070/health 2>/dev/null || true)
  [ "$STATUS" = "200" ] && echo "Restate up after ${i}s" && break
  sleep 1
done

# ── Worker ─────────────────────────────────────────────────────────────────────
echo ""
echo "=== Starting saga worker (port 9080) ==="
DB_PATH="$DB" ucm run '@guillaumedesforges/demo-unison-ddd-api-worker/main:.Demo.Worker.main' \
  >/tmp/worker.log 2>&1 &
WORKER_PID=$!

for i in $(seq 1 30); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9080/discover 2>/dev/null || true)
  [ "$STATUS" = "200" ] && echo "Worker up after ${i}s" && break
  sleep 1
done

# ── Register + seed ────────────────────────────────────────────────────────────
echo ""
echo "=== Register worker with Restate ==="
curl -sf -X POST http://localhost:9070/deployments \
  -H 'content-type: application/json' \
  -d '{"uri":"http://localhost:9080","use_http_11":true}' \
  | jq -r '.services[0].name + " registered"'

echo ""
echo "=== Seed SQLite ==="
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS content (
  id TEXT PRIMARY KEY, author_id TEXT NOT NULL, text_content TEXT NOT NULL,
  created_at INTEGER NOT NULL, status TEXT NOT NULL,
  decision TEXT, decision_reason TEXT, awakeable_id TEXT)"
sqlite3 "$DB" "INSERT INTO content (id, author_id, text_content, created_at, status)
  VALUES ('$CID', 'alice', 'Hello Restate', $(date +%s)000, 'Submitted')"
echo "Inserted $CID"

# ── Invoke saga via Restate ingress ────────────────────────────────────────────
echo ""
echo "=== Invoke ModerationService/moderate via Restate ingress ==="
curl -sf -X POST http://localhost:8080/ModerationService/moderate \
  -H 'content-type: application/octet-stream' \
  --data-raw "$CID" \
  --max-time 30
echo ""

# ── Assertions ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Assertions ==="
STATUS_VAL=$(sqlite3 "$DB" "SELECT status   FROM content WHERE id='$CID'")
DECISION=$(sqlite3   "$DB" "SELECT decision FROM content WHERE id='$CID'")

[ "$STATUS_VAL" = "AutoModerated" ] || { echo "FAIL: expected AutoModerated, got $STATUS_VAL"; exit 1; }
[ "$DECISION"   = "Approve"       ] || { echo "FAIL: expected Approve, got $DECISION"; exit 1; }
echo "PASS: status=$STATUS_VAL, decision=$DECISION"
