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

## Quick Start

```bash
git clone https://github.com/GuillaumeDesforges/restate-sdk-unison ../restatedev-sdk-unison
git clone <this-repo>
cd demo-unison-ddd-api-worker
```

**Direct mode** (single command):

```bash
scripts/test-direct-mode.sh
```

**Restate mode** (single command — starts Restate + worker + API automatically):

```bash
scripts/demo-restate-mode.sh
```

Both scripts auto-invoke `nix-shell` — no manual environment setup needed.
(`test-restate-mode.sh` and `test-integration.sh` require you to be inside `nix-shell` already.)
The first run builds the Restate native Rust library (~2 min); subsequent runs are instant.

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

## Prerequisites

All tools (UCM, SQLite, Restate, curl, jq, Rust) come from `shell.nix`.
The scripts auto-enter `nix-shell` — you don't need to do it yourself.

**Clone the Restate SDK sibling (required for Restate mode):**

```bash
git clone https://github.com/GuillaumeDesforges/restate-sdk-unison ../restatedev-sdk-unison
```

Direct mode works without this sibling. The first `nix-shell` entry after
cloning builds the Restate native Rust library (~2 min); subsequent entries
are instant.

## Direct Mode

The HTTP API runs the saga inline. Single process, synchronous.

**Run the self-contained test:**

```bash
scripts/test-direct-mode.sh
```

**Or manually (inside `nix-shell`):**

```bash
nix-shell

export DB_PATH=$(mktemp /tmp/mod-XXXXXX.db)
ucm run '@guillaumedesforges/demo-unison-ddd-api-worker/main:.Demo.Api.main' &

# Wait for server to be ready (~10 seconds on first run)
until [ "$(curl -so /dev/null -w '%{http_code}' http://localhost:8080/content/probe 2>/dev/null)" = "404" ]; do
  echo "waiting..."; sleep 1
done

curl -X POST http://localhost:8080/content \
  -H 'content-type: application/json' \
  -d '{"id":"c1","authorId":"alice","text":"Hello world"}'
# → {"id":"c1"}

curl http://localhost:8080/content/c1
# → {"status":{"type":"AutoModerated","decision":{"type":"Approve"}},...}
```

## Restate Mode

The saga runs in a durable worker; the API layer forwards requests to it via Restate.

**Run the self-contained demo (starts everything automatically):**

```bash
scripts/demo-restate-mode.sh
```

**Or manually — three terminals, all inside `nix-shell`:**

> **Note:** UCM allows only one process to hold the codebase lock at a time.
> `Demo.Restate.main` solves this by running the Restate worker (port 9080)
> and the HTTP API (port 8081) in a single UCM process.

**Terminal 1 — Restate server:**

```bash
restate-server --base-dir $(mktemp -d)
```

**Terminal 2 — worker + HTTP API (single UCM process):**

```bash
export DB_PATH=/tmp/mod-restate.db
DB_PATH=$DB_PATH RESTATE_INGRESS=http://localhost:8080 \
  ucm run '@guillaumedesforges/demo-unison-ddd-api-worker/main:.Demo.Restate.main'
```

**Terminal 3 — register and test (after both services are up):**

```bash
# Register worker with Restate (once per start)
curl -X POST http://localhost:9070/deployments \
  -H 'content-type: application/json' \
  -d '{"uri":"http://localhost:9080","use_http_11":true}'

# Submit content
curl -X POST http://localhost:8081/content \
  -H 'content-type: application/json' \
  -d '{"id":"c2","authorId":"bob","text":"Hello Restate"}'
# → {"id":"c2"}

# Poll until moderated (Restate is async)
curl http://localhost:8081/content/c2
# → {"status":{"type":"AutoModerated","decision":{"type":"Approve"}},...}
```

### Human Review Flow (Restate mode)

The default stub classifier always returns `Approve`. To test the awakeable
(human review) path, swap `AIClassifier.restateHandler` for one that returns
`Escalate`, or resolve the awakeable manually:

```bash
AWAKE=$(sqlite3 $DB_PATH "SELECT awakeable_id FROM content WHERE id='c2'")

curl -X POST "http://localhost:8080/restate/awakeables/$AWAKE/resolve" \
  -H 'content-type: application/octet-stream' \
  --data-raw 'Approve'

curl http://localhost:8081/content/c2
# → {"status":{"type":"Resolved","decision":{"type":"Approve"}},...}
```

## Scripts

| Script | What it does |
|---|---|
| `scripts/test-direct-mode.sh` | Self-contained direct mode test (starts/stops API) |
| `scripts/demo-restate-mode.sh` | Self-contained Restate demo (starts Restate + combined worker+API) |
| `scripts/test-restate-mode.sh` | Restate test against pre-started Restate + worker |
| `scripts/test-integration.sh` | Both modes; Restate portion skipped if not running |

`test-direct-mode.sh` and `demo-restate-mode.sh` auto-invoke `nix-shell` when run outside of one.
`test-restate-mode.sh` and `test-integration.sh` require you to already be inside `nix-shell`.

## Project Structure

```
scratch/main.u     — all Unison code (single file)
scripts/           — integration test and demo scripts
shell.nix          — UCM, SQLite, Restate, curl, jq, cargo, rustc
PROJECT.md         — living design doc (goals, decisions, roadmap)
```
