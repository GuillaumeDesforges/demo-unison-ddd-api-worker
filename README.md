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
| Direct | SQLite (inline) | stub → Approve | `printLine` | fixed decision |
| Restate | SQLite via `ctx.run` | stub via `ctx.run` | `printLine` via `ctx.run` | `ctx.awakeable` |

The saga is never touched. Only the `handle ... with` wrappers differ.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Client  POST /content  GET /content/:id  POST .../review        │
└────────────────────┬──────────────────────────────────────────────┘
                     │
       ┌─────────────▼──────────────────────┐
       │  Demo.Api.main  (port 8080 / 8081)  │
       │  – submit, get, review              │
       │  – Direct: runs saga inline         │
       │  – Restate: POSTs to ModerationSvc  │
       └─────────────────────┬──────────────┘
                             │  RESTATE_INGRESS set
          ┌──────────────────▼──────────────────────────┐
          │  Restate  (ingress :8080  admin :9070)       │
          │  – journals every operation                  │
          │  – retries on failure, resumes on awakeables │
          └──────────────────┬──────────────────────────┘
                             │
          ┌──────────────────▼──────────────────────────┐
          │  Demo.Worker.main  (port 9080)               │
          │  – runs moderationSaga with Restate          │
          │    interpreters (ctx.run / ctx.awakeable)    │
          └──────────────────────────────────────────────┘
                     │
          ┌──────────▼─────────────────────────────────┐
          │  SQLite  (DB_PATH file, shared)             │
          └────────────────────────────────────────────┘
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

## Prerequisites

All tools come from `shell.nix` — always work inside `nix-shell`.

```bash
cd demo-unison-ddd-api-worker
nix-shell
```

The nix shell sets `SQLITE_LIB_PATH` and `LD_LIBRARY_PATH` for you.

**Restate mode only** — build the native Rust SDK once:

```bash
cargo build --release \
  --manifest-path ../restatedev-sdk-unison/crates/restate-sdk-unison-native/Cargo.toml
```

## Direct Mode

Single terminal. The HTTP API runs the saga inline on every `POST /content`.

```bash
nix-shell

export DB_PATH=$(mktemp /tmp/mod-XXXXXX.db)
ucm run '@guillaumedesforges/demo-unison-ddd-api-worker/main:.Demo.Api.main' &

# Submit content
curl -X POST http://localhost:8080/content \
  -H 'content-type: application/json' \
  -d '{"id":"c1","authorId":"alice","text":"Hello world"}'
# → {"id":"c1"}

# Poll result — saga runs synchronously, so it's already done
curl http://localhost:8080/content/c1
# → {"id":"c1","authorId":"alice","text":"Hello world","createdAt":...,
#    "status":{"type":"AutoModerated","decision":{"type":"Approve"}}}
```

## Restate Mode

Three terminals, all inside `nix-shell`. The saga runs in the worker via
Restate's durable execution; the HTTP API layer forwards requests to it.

> **Note:** Restate mode requires two concurrent `ucm run` processes. If you
> are using the Unison MCP server (e.g. via Claude Code), a third UCM process
> cannot obtain the codebase lock. Stop the MCP server before running Restate
> mode, or test it with the raw Restate ingress commands below.

**Terminal 1 — Restate server:**

```bash
restate-server --base-dir $(mktemp -d)
```

**Terminal 2 — saga worker (port 9080):**

```bash
export DB_PATH=/tmp/mod-restate.db
ucm run '@guillaumedesforges/demo-unison-ddd-api-worker/main:.Demo.Worker.main'
```

**Terminal 3 — register, start API, test:**

```bash
export DB_PATH=/tmp/mod-restate.db

# Register worker with Restate (once per worker start)
curl -X POST http://localhost:9070/deployments \
  -H 'content-type: application/json' \
  -d '{"uri":"http://localhost:9080","use_http_11":true}'

# Start the HTTP API on port 8081 (Restate takes 8080)
API_PORT=8081 RESTATE_INGRESS=http://localhost:8080 \
  ucm run '@guillaumedesforges/demo-unison-ddd-api-worker/main:.Demo.Api.main' &

# Submit content — API saves to SQLite, then invokes ModerationService via Restate
curl -X POST http://localhost:8081/content \
  -H 'content-type: application/json' \
  -d '{"id":"c2","authorId":"bob","text":"Hello Restate"}'
# → {"id":"c2"}

# Poll result
curl http://localhost:8081/content/c2
# → {"id":"c2","authorId":"bob","text":"Hello Restate","createdAt":...,
#    "status":{"type":"AutoModerated","decision":{"type":"Approve"}}}
```

### Human Review Flow (Restate mode)

The default stub classifier always returns `Approve`. To test the awakeable
(human review) path, swap `AIClassifier.restateHandler` for one that returns
`Escalate`, or resolve the awakeable manually:

```bash
# Get the awakeable ID stored by the worker when it suspended
AWAKE=$(sqlite3 $DB_PATH "SELECT awakeable_id FROM content WHERE id='c2'")

# Deliver the human decision — worker resumes immediately
curl -X POST "http://localhost:8080/restate/awakeables/$AWAKE/resolve" \
  -H 'content-type: application/octet-stream' \
  --data-raw 'Approve'

curl http://localhost:8081/content/c2
# → {"status":{"type":"Resolved"},"decision":{"type":"Approve"}}
```

### Without the API (Restate ingress directly)

If you can only run one UCM process (e.g. MCP server already active), skip
starting `Demo.Api.main` and interact with Restate directly:

```bash
export DB_PATH=/tmp/mod-restate.db

# Seed SQLite (the API would normally do this on POST /content)
sqlite3 $DB_PATH "CREATE TABLE IF NOT EXISTS content (
  id TEXT PRIMARY KEY, author_id TEXT NOT NULL, text_content TEXT NOT NULL,
  created_at INTEGER NOT NULL, status TEXT NOT NULL,
  decision TEXT, decision_reason TEXT, awakeable_id TEXT)"
sqlite3 $DB_PATH "INSERT INTO content VALUES (
  'c3','alice','Hello world',1234567890,'Submitted',NULL,NULL,NULL)"

# Invoke the worker via Restate ingress
curl -X POST http://localhost:8080/ModerationService/moderate \
  -H 'content-type: application/octet-stream' \
  --data-raw 'c3' --max-time 30

# Check result in SQLite
sqlite3 $DB_PATH "SELECT status, decision FROM content WHERE id='c3'"
# → AutoModerated|Approve
```

## Running Tests

```bash
# Direct mode only (fully self-contained, starts/stops its own server)
scripts/test-direct-mode.sh

# Restate mode (requires Restate server + worker already running)
DB_PATH=/tmp/mod-restate.db scripts/test-restate-mode.sh

# Both
scripts/test-integration.sh
```

## Project Structure

```
scratch/main.u          — all Unison code (single file)
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
| `moderationSaga` | `Content ->{ContentStore, AIClassifier, Notifier, HumanReview} ()` | The saga — same in both modes |
| `ContentStore.sqliteHandler` | `DB -> '{g, ContentStore} a ->{g, IO, Exception} a` | Direct-mode store |
| `ContentStore.restateHandler` | `DB -> '{g, ContentStore} a ->{g, Ctx, IO, Exception} a` | Restate-mode store |
| `AIClassifier.approveAll` | `'{g, AIClassifier} a ->{g} a` | Stub (always Approve) |
| `AIClassifier.claudeDirectHandler` | `Text -> '{g, AIClassifier} a ->{g, IO, Exception} a` | Claude API (direct) |
| `AIClassifier.claudeRestateHandler` | `Text -> '{g, AIClassifier} a ->{g, Ctx, IO, Exception} a` | Claude API (Restate) |
| `HumanReview.awakeableHandler` | `DB -> '{g, HumanReview} a ->{g, Ctx, IO, Exception} a` | Restate awakeable |
| `Demo.Api.main` | `'{IO, Exception} ()` | HTTP API — direct (no env) or Restate (`RESTATE_INGRESS` set) |
| `Demo.Worker.main` | `'{IO, Exception} ()` | Restate worker (port 9080) |

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `DB_PATH` | required | Path to SQLite database file |
| `API_PORT` | `8080` | Port for `Demo.Api.main` |
| `RESTATE_INGRESS` | unset | If set, enables Restate mode in `Demo.Api.main` |
