# DDD + Algebraic Effects in Unison

A demo showing that Unison's **Abilities** (algebraic effects) let a single
business-logic function run under two completely different execution backends,
without changing a line of saga code.

## The Core Idea

```
moderationSaga : Content ->{ContentStore, AIClassifier, Notifier, HumanReview} ()
```

This function is written once. The execution backend is selected at startup by
choosing which **interpreters** to wrap around it:

| Mode | ContentStore | AIClassifier | Notifier | HumanReview |
|------|-------------|--------------|----------|-------------|
| Direct | SQLite (inline) | stub (always Approve) | `printLine` | fixed decision |
| Restate | SQLite via `ctx.run` | stub via `ctx.run` | `printLine` via `ctx.run` | `ctx.awakeable` |

The saga is never touched. Only the `handle ... with` wrappers differ.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Client                                                      │
│   POST /content       GET /content/:id   POST .../review    │
└────────────┬─────────────────┬──────────────────────────────┘
             │                 │
┌────────────▼─────────────────▼──────────────────────────────┐
│  Demo.Api.main  (port 8080)                                  │
│  – HTTP routes: submit, get, review                          │
│  – Direct mode: runs moderationSaga inline                   │
│  – Restate mode: fires to ModerationService                  │
└────────────────────────┬─────────────────────────────────────┘
                         │  (Restate mode only)
┌────────────────────────▼─────────────────────────────────────┐
│  Restate  (admin :9070, ingress :8080)                       │
│  – Journals every operation                                  │
│  – Retries on failure                                        │
│  – Suspends/resumes for awakeables                           │
└────────────────────────┬─────────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────────┐
│  Demo.Worker.main  (port 9080)                               │
│  ModerationService/moderate                                  │
│  – Runs moderationSaga with Restate interpreters             │
│  – ctx.run wraps every side effect for durability            │
│  – ctx.awakeable suspends for human review                   │
└──────────────────────────────────────────────────────────────┘
             │
┌────────────▼──────────────────────────────────────────────────┐
│  SQLite  (shared DB_PATH file)                               │
│  – content table with status, decision, awakeable_id         │
└──────────────────────────────────────────────────────────────┘
```

## Domain

**Content moderation queue.** Users submit text posts; an AI classifier decides
whether to Approve, Reject, or Escalate to a human reviewer.

```
type ContentStatus
  = Submitted
  | AutoModerated ModerationDecision
  | PendingHumanReview ModerationDecision
  | Resolved ModerationDecision

type ModerationDecision
  = Approve
  | Reject Text    -- reason
  | Escalate Text  -- reason (AI uncertain)
```

## Quick Start

All tools come from `shell.nix`. Always work inside `nix-shell` — it sets
`SQLITE_LIB_PATH` and `LD_LIBRARY_PATH` automatically.

The Restate SDK requires a native Rust library. Build it once:

```bash
cargo build --release \
  --manifest-path ../restatedev-sdk-unison/crates/restate-sdk-unison-native/Cargo.toml
```

### Direct mode (single terminal)

```bash
nix-shell   # sets SQLITE_LIB_PATH for you

export DB_PATH=$(mktemp /tmp/mod-XXXXXX.db)
ucm run '@gdforj/demo-unison-ddd-api-worker/main:.Demo.Api.main' &

# Submit content
curl -X POST http://localhost:8080/content \
  -H 'content-type: application/json' \
  -d '{"id":"abc-123","authorId":"alice","text":"Hello world"}'

# Poll result
curl http://localhost:8080/content/abc-123
# → {"id":"abc-123","status":{"type":"AutoModerated"},"decision":{"type":"Approve"}, ...}
```

### Restate mode (three terminals, all inside `nix-shell`)

**Terminal 1 — Restate server:**
```bash
restate-server --base-dir $(mktemp -d)
```

**Terminal 2 — Restate worker:**
```bash
export DB_PATH=/tmp/mod-restate.db
ucm run '@gdforj/demo-unison-ddd-api-worker/main:.Demo.Worker.main'
```

**Terminal 3 — register and test:**
```bash
export DB_PATH=/tmp/mod-restate.db

# Register worker with Restate (once per worker start)
curl -X POST http://localhost:9070/deployments \
  -H 'content-type: application/json' \
  -d '{"uri":"http://localhost:9080","use_http_11":true}'

# Seed content in SQLite
sqlite3 $DB_PATH "CREATE TABLE IF NOT EXISTS content (id TEXT PRIMARY KEY, author_id TEXT NOT NULL, text_content TEXT NOT NULL, created_at INTEGER NOT NULL, status TEXT NOT NULL, decision TEXT, decision_reason TEXT, awakeable_id TEXT)"
sqlite3 $DB_PATH "INSERT INTO content VALUES ('abc-123','alice','Hello world',1234567890,'Submitted',NULL,NULL,NULL)"

# Invoke via Restate ingress
curl -X POST http://localhost:8080/ModerationService/moderate \
  -H 'content-type: application/octet-stream' \
  --data-raw 'abc-123'

# Check result
sqlite3 $DB_PATH "SELECT status, decision FROM content WHERE id='abc-123'"
# → AutoModerated|Approve
```

### Human review flow (Restate mode)

If the AI escalates (change the classifier stub to return `Escalate`):

```bash
# Get the awakeable ID Restate suspended on
AWAKE_ID=$(sqlite3 $DB_PATH "SELECT awakeable_id FROM content WHERE id='abc-123'")

# Deliver the human decision — worker resumes
curl -X POST "http://localhost:8080/restate/awakeables/$AWAKE_ID/resolve" \
  -H 'content-type: application/octet-stream' \
  --data-raw 'Approve'

sqlite3 $DB_PATH "SELECT status, decision FROM content WHERE id='abc-123'"
# → Resolved|Approve
```

## Running Tests

```bash
# Direct mode only (self-contained)
scripts/test-direct-mode.sh

# Restate mode (requires Restate server + worker running)
scripts/test-restate-mode.sh

# Combined
scripts/test-integration.sh
```

## Project Structure

```
scratch/main.u          — all Unison code (single file, pushed to UCM codebase)
scripts/
  test-direct-mode.sh   — direct mode integration test
  test-restate-mode.sh  — Restate mode integration test
  test-integration.sh   — combined test
shell.nix               — UCM, SQLite, Restate, curl, jq
PROJECT.md              — living design doc (goals, decisions, roadmap)
```

## Key Definitions

| Definition | Type | Purpose |
|---|---|---|
| `moderationSaga` | `Content ->{ContentStore, AIClassifier, Notifier, HumanReview} ()` | The saga — never changes |
| `ContentStore.sqliteHandler` | `DB -> '{g, ContentStore} a ->{g, IO, Exception} a` | Direct-mode store |
| `ContentStore.restateHandler` | `DB -> '{g, ContentStore} a ->{g, Ctx, IO, Exception} a` | Restate-mode store |
| `AIClassifier.approveAll` | `'{g, AIClassifier} a ->{g} a` | Stub classifier |
| `HumanReview.runPure` | `ModerationDecision -> '{g, HumanReview} a ->{g} a` | Test-double reviewer |
| `HumanReview.awakeableHandler` | `DB -> '{g, HumanReview} a ->{g, Ctx, IO, Exception} a` | Restate awakeable |
| `Demo.Api.main` | `'{IO, Exception} ()` | HTTP API server (port 8080) |
| `Demo.Worker.main` | `'{IO, Exception} ()` | Restate worker (port 9080) |
