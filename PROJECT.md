# Project state — Demo: DDD + Algebraic Effects in Unison

> This file is maintained by Claude. Update it whenever goals shift, decisions are made, work is completed, or the roadmap changes.

## Goal

Demonstrate that Unison's Abilities (algebraic effects) enable a single application service layer — a **moderation saga** — to be shared between two execution backends:

- **Direct mode**: the HTTP API runs the saga inline, interpreting abilities as plain function calls
- **Restate mode**: the HTTP API fires-and-forgets to a Restate worker, which runs the same saga with abilities interpreted through Restate's durable execution (journaling, retries, awakeables)

The saga is written once against abstract Abilities. No saga code changes when switching backends — only the interpreters differ.

## Domain

**Content moderation queue.** Users submit text posts for moderation. An AI classifier (initially a stub) makes an auto-moderation decision. Uncertain content is escalated to a human reviewer.

See `scratch/main.u` for the domain types (`Content`, `ContentStatus`, `ModerationDecision`), the four abilities (`ContentStore`, `AIClassifier`, `Notifier`, `HumanReview`), and the saga implementation.

## Architecture decisions

### 1. Single saga, two interpreters

The moderation pipeline is a single `moderationSaga` function. The execution backend is selected at startup via a config flag:

- `--mode direct` — abilities run inline within the HTTP request
- `--mode restate` — abilities are interpreted through Restate's durable execution

**Why**: this is the core demo. The saga code never changes; only the interpreter passed to `handle ... with` differs.

### 2. Shared SQLite database

Both the HTTP API and the Restate worker connect to the same SQLite file (path from env var `DB_PATH`). The HTTP API writes the initial `Submitted` record; the worker reads it and updates state as the saga progresses.

**Why**: in-memory state cannot be shared across processes. SQLite requires no infrastructure beyond the file.

### 3. AI classifier: stub first

The `AIClassifier` ability is initially interpreted by `AIClassifier.approveAll`, a stub that returns `Approve` for all input. The Claude API implementation (`claudeDirectHandler` / `claudeRestateHandler`) can be swapped in as a second interpreter without touching the saga.

### 4. Notifier: print to stdout

The `Notifier` ability prints the author ID and decision to stdout. In Restate mode (`Notifier.restateHandler`) the print is wrapped in `ctx.run` so it is journaled and not re-executed on replay.

### 5. HumanReview: awakeable in Restate mode

In Restate mode, `waitForDecision` creates a Restate awakeable, stores the awakeable ID in SQLite against the `ContentId`, and suspends. The `POST /content/:id/review` HTTP endpoint looks up the awakeable ID and completes it.

In direct mode, `waitForDecision` is not reachable in normal flow (the stub classifier never returns `Escalate` in automated tests), but can be given a test implementation.

### 6. Three entry points

- `Demo.Api.main` — HTTP server (`API_PORT`, default 8080); reads `RESTATE_INGRESS` env var to select mode
- `Demo.Worker.main` — Restate service endpoint (port 9080), runs saga with Restate interpreters
- `Demo.Restate.main` — combined process: runs the Restate worker (port 9080) **and** the API server (`API_PORT`, default 8081) in the same UCM process, avoiding UCM's codebase lock when two `ucm run` calls would race; `RESTATE_INGRESS` defaults to `http://localhost:8080`

### 7. Single scratch file

All Unison code lives in `scratch/main.u`. UCM codebase at `~/.config/unisonlanguage/` under project `@guillaumedesforges/demo-unison-ddd-api-worker`.

## Status

**Phase: Stage 4 — Polish — complete. Demo fully reproducible.**

## Roadmap

- [ ] Integration test: human review flow via awakeable (manual steps currently documented in `scripts/test-restate-mode.sh`)
