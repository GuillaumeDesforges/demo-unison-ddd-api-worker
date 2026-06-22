# Project state — Demo: DDD + Algebraic Effects in Unison

> This file is maintained by Claude. Update it whenever goals shift, decisions are made, work is completed, or the roadmap changes.

## Goal

Demonstrate that Unison's Abilities (algebraic effects) enable a single application service layer — a **moderation saga** — to be shared between two execution backends:

- **Direct mode**: the HTTP API runs the saga inline, interpreting abilities as plain function calls
- **Restate mode**: the HTTP API fires-and-forgets to a Restate worker, which runs the same saga with abilities interpreted through Restate's durable execution (journaling, retries, awakeables)

The saga is written once against abstract Abilities. No saga code changes when switching backends — only the interpreters differ.

## Domain

**Content moderation queue.** Users submit text posts for moderation. An AI classifier (initially a stub) makes an auto-moderation decision. Uncertain content is escalated to a human reviewer.

### Types

```
type ContentId = ContentId Text   -- UUID, provided by client

type Content = {
  id        : ContentId,
  authorId  : Text,
  text      : Text,
  createdAt : Nat,              -- Unix timestamp ms
  status    : ContentStatus
}

type ContentStatus
  = Submitted
  | AutoModerated ModerationDecision
  | PendingHumanReview ModerationDecision   -- escalated AI decision preserved
  | Resolved ModerationDecision

type ModerationDecision
  = Approve
  | Reject Text      -- reason
  | Escalate Text    -- reason (AI uncertain, send to human)
```

### Abilities

```
ability ContentStore where
  getContent  : ContentId -> Optional Content
  saveContent : Content -> ()

ability AIClassifier where
  classify : Text -> ModerationDecision

ability Notifier where
  notify : Text -> ModerationDecision -> ()   -- authorId, outcome

ability HumanReview where
  waitForDecision : ContentId -> ModerationDecision
```

### Saga

```
moderationSaga : Content ->{ContentStore, AIClassifier, Notifier, HumanReview} ()
```

Steps (equivalent to Temporal activities):
1. Save content as `Submitted`
2. Call AI classifier → get `ModerationDecision`
3. If `Approve` or `Reject`: save final status, notify author
4. If `Escalate`: save as `PendingHumanReview`, wait for human decision, save final status, notify author

### HTTP API

```
POST /content                   -- submit { id, authorId, text }; returns 202
GET  /content/:id               -- returns current Content state
POST /content/:id/review        -- human moderator submits { decision, reason? }
```

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

The `AIClassifier` ability is initially interpreted by a stub that returns `Escalate "needs review"` for all input. The Claude API implementation can be added later as a second interpreter without touching the saga.

### 4. Notifier: HTTP webhook

The `Notifier` ability POSTs a JSON payload to the URL in the `WEBHOOK_URL` environment variable. In Restate mode, a failed webhook call is automatically retried by Restate.

### 5. HumanReview: awakeable in Restate mode

In Restate mode, `waitForDecision` creates a Restate awakeable, stores the awakeable ID in SQLite against the `ContentId`, and suspends. The `POST /content/:id/review` HTTP endpoint looks up the awakeable ID and completes it.

In direct mode, `waitForDecision` is not reachable in normal flow (the stub classifier never returns `Escalate` in automated tests), but can be given a test implementation.

### 6. Two entry points

- `Demo.Api.main` — HTTP server (port 8080), reads `--mode` flag, selects interpreters
- `Demo.Worker.main` — Restate service endpoint (port 9080), runs saga with Restate interpreters

### 7. Single scratch file

All Unison code lives in `scratch/main.u`. UCM codebase at `~/.config/unisonlanguage/` under project `@gdforj/demo-unison-ddd-api-worker`.

## Project structure

```
demo-unison-ddd-api-worker/
├── CLAUDE.md
├── PROJECT.md
├── shell.nix                   -- UCM, SQLite, Restate, curl, jq
├── .mcp.json                   -- Unison MCP server
├── .claude/settings.json
├── scratch/
│   └── main.u                  -- all Unison code
└── scripts/
    └── test-integration.sh
```

## Status

**Phase: scaffolding — not yet started.**

## Roadmap

### Stage 1 — Domain types and saga (unit tests)

- [ ] Define `Content`, `ContentId`, `ContentStatus`, `ModerationDecision`
- [ ] Define the four abilities
- [ ] Write `moderationSaga` against the abilities
- [ ] Unit test the saga with pure stub interpreters (no IO)

### Stage 2 — Direct interpreter (HTTP API, direct mode)

- [ ] SQLite interpreter for `ContentStore`
- [ ] Stub interpreter for `AIClassifier`
- [ ] HTTP webhook interpreter for `Notifier`
- [ ] Test-double interpreter for `HumanReview`
- [ ] `Demo.Api.main` HTTP server with all three routes
- [ ] Integration test: submit → poll → verify `Approved` or `Rejected`

### Stage 3 — Restate interpreter (worker, Restate mode)

- [ ] Restate `ctx.run` interpreter for `AIClassifier` and `Notifier`
- [ ] Restate awakeable interpreter for `HumanReview`
- [ ] `Demo.Worker.main` Restate service endpoint
- [ ] Integration test: submit via HTTP API → worker runs saga durably → poll HTTP API for result
- [ ] Integration test: human review flow via awakeable

### Stage 4 — Polish

- [ ] Claude API interpreter for `AIClassifier` (replaces stub)
- [ ] `scripts/test-integration.sh` covering both modes
- [ ] README with architecture diagram and quick-start
