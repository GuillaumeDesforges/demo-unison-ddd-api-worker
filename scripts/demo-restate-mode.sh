#!/usr/bin/env bash
# Self-contained Restate mode demo.
# Starts restate-server + combined worker+API process, runs a full HTTP roundtrip,
# then cleans up.
# Safe to run directly — auto-invokes nix-shell if needed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${IN_NIX_SHELL:-}" ]; then
  exec nix-shell "$SCRIPT_DIR/../shell.nix" --run "bash $0 $*"
fi

set -euo pipefail

DB=$(mktemp /tmp/mod-restate-XXXXXX.db)
RESTATE_BASE=$(mktemp -d)
RESTATE_PID=""
MAIN_PID=""

cleanup() {
  echo ""
  echo "=== Cleanup ==="
  [ -n "$MAIN_PID"    ] && kill "$MAIN_PID"    2>/dev/null || true
  [ -n "$RESTATE_PID" ] && kill "$RESTATE_PID" 2>/dev/null || true
  rm -f "$DB"
  rm -rf "$RESTATE_BASE"
}
trap cleanup EXIT

BASE="http://localhost:8081"
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

# ── Worker + HTTP API (single UCM process) ─────────────────────────────────────
echo ""
echo "=== Starting worker + HTTP API (port 9080 / 8081) ==="
DB_PATH="$DB" RESTATE_INGRESS="http://localhost:8080" \
  ucm run '@guillaumedesforges/demo-unison-ddd-api-worker/main:.Demo.Restate.main' \
  >/tmp/restate-main.log 2>&1 &
MAIN_PID=$!

for i in $(seq 1 30); do
  W=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9080/discover 2>/dev/null || true)
  A=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/content/$CID" 2>/dev/null || true)
  [ "$W" = "200" ] && [ "$A" = "404" ] && echo "Worker + API up after ${i}s" && break
  sleep 1
done

# ── Register worker with Restate ───────────────────────────────────────────────
echo ""
echo "=== Register worker with Restate ==="
curl -sf -X POST http://localhost:9070/deployments \
  -H 'content-type: application/json' \
  -d '{"uri":"http://localhost:9080","use_http_11":true}' \
  | jq -r '.services[0].name + " registered"'

# ── Submit content via HTTP API ────────────────────────────────────────────────
echo ""
echo "=== Submit content ==="
SUBMIT=$(curl -sf -X POST "$BASE/content" \
  -H "content-type: application/json" \
  -d "{\"id\":\"$CID\",\"authorId\":\"alice\",\"text\":\"Hello Restate\"}")
echo "$SUBMIT"

# ── Poll until moderated (Restate processes async) ─────────────────────────────
echo ""
echo "=== Polling content state ==="
STATE=""
for i in $(seq 1 30); do
  STATE=$(curl -sf "$BASE/content/$CID" 2>/dev/null || true)
  TYPE=$(echo "$STATE" | jq -r '.status.type' 2>/dev/null || true)
  echo "  [${i}s] status=$TYPE"
  [ "$TYPE" != "Submitted" ] && [ -n "$TYPE" ] && break
  sleep 1
done
echo "$STATE"

# ── Assertions ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Assertions ==="
STATUS_VAL=$(echo "$STATE" | jq -r '.status.type')
DECISION=$(echo "$STATE" | jq -r '.status.decision.type')

[ "$STATUS_VAL" = "AutoModerated" ] || { echo "FAIL: expected AutoModerated, got $STATUS_VAL"; exit 1; }
[ "$DECISION"   = "Approve"       ] || { echo "FAIL: expected Approve, got $DECISION"; exit 1; }
echo "PASS: status=$STATUS_VAL, decision=$DECISION"
