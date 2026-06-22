# CLAUDE.md — Demo: DDD + Algebraic Effects in Unison

**Project state (goals, roadmap, decisions, status): see [PROJECT.md](PROJECT.md).**
Update PROJECT.md whenever decisions are made, work is completed, or the roadmap changes — treat it as a living wiki page, not a snapshot.

## Dev environment

NixOS with a per-project Nix shell. **No global installs of any kind** — all tools (UCM, SQLite, Restate, etc.) come exclusively from `shell.nix`. Always work inside `nix-shell`.

To add a new tool: add it to `shell.nix` `buildInputs`, never install it globally.

The `.mcp.json` configures the Unison MCP server — it starts automatically when Claude Code is launched from this directory. UCM creates a codebase at `~/.config/unisonlanguage/` on first run. To install libraries, use the MCP `lib-install` tool.

## Unison coding conventions

These are mandatory. Violations cause type errors or subtly wrong behaviour.

**Pattern matching — always use `match/with` or `cases`, never LHS patterns:**
```
-- CORRECT
List.head = cases
  [] -> None
  hd +: _ -> Some hd

-- WRONG (invalid Unison syntax)
List.head [] = None
List.head (hd +: _) = Some hd
```

**Looping — tail recursion with accumulating parameter, build lists forward:**
```
-- CORRECT: O(1) append with :+
List.map f as =
  go acc = cases
    [] -> acc
    x +: xs -> go (acc :+ f x) xs
  go [] as

-- WRONG: not tail-recursive
List.map f = cases
  [] -> []
  x +: xs -> f x +: List.map f xs
```

**No `let`, no `where` — bindings go directly in the block:**
```
foo x =
  y = x + 1   -- CORRECT
  y * 2

-- WRONG
foo x = let y = x + 1 in y * 2
foo x = y * 2 where y = x + 1
```

**Abilities — make higher-order functions ability-polymorphic:**
```
-- CORRECT
List.map : (a ->{g} b) -> [a] ->{g} [b]

-- WRONG: locks out effectful functions
List.map : (a -> b) -> [a] -> [b]
```

**No typeclasses — use explicit dictionary passing:**
```
type Serde a = { encode : a -> Bytes, decode : Bytes -> Either Text a }
-- pass Serde as an argument, don't use implicit resolution
```

**Record field access is via generated functions, not dot notation:**
```
Serde.encode mySerde value   -- CORRECT
mySerde.encode value         -- WRONG
```

**Optional uses `None`/`Some`, not `Nothing`/`Just`.**

**Helper functions:** `go` or `loop` for recursive helpers, `f`/`g` for function args, `acc` for accumulators, `rem` for remainder.

**Tests:** named `foo.tests.examples` (input/output) and `foo.tests.props` (property-based). Use `test>` watch expressions.

## Testing methodology — red-green-refactor

**Nothing works until it is tested.** Typechecking proves type consistency, not correctness. Every public function must have a test before it is considered done.

**The loop:**
1. **Red** — write a failing test first. Run it with `run-tests` MCP tool and confirm it fails for the right reason (not a crash or type error).
2. **Green** — write the minimal implementation that makes the test pass. No extra logic.
3. **Refactor** — clean up the implementation while keeping tests green.

**Test levels:**

- **Unit tests** (`test>` expressions in `scratch/main.u`): pure functions, domain types, saga logic with stub interpreters. Run entirely in UCM.
- **Integration tests** (`scripts/test-integration.sh`): start both the HTTP API and Restate worker, submit content, poll for state, assert outcomes. Require a running SQLite file and Restate binary.

**Commit rule:** a commit that adds or changes behaviour must include a test that was red before the change and is green after.

## Running integration tests

All tools are in the Nix shell (`nix-shell`). Open three terminals inside it.

**Terminal 1 — Restate server:**
```
restate-server --base-dir $(mktemp -d)
```

**Terminal 2 — HTTP API + Restate worker:**
```
# Direct mode
ucm run Demo.Api.main -- --mode direct

# Restate mode (also serves as the Restate service endpoint)
ucm run Demo.Worker.main
ucm run Demo.Api.main -- --mode restate
```

**Terminal 3 — test driver:**

Register the worker endpoint with Restate (once per worker start):
```bash
curl -X POST http://localhost:9070/deployments \
  -H 'content-type: application/json' \
  -d '{"uri": "http://localhost:9080", "use_http_11": true}'
```

Submit content:
```bash
curl -X POST http://localhost:8080/content \
  -H 'content-type: application/json' \
  -d '{"id": "550e8400-e29b-41d4-a716-446655440000", "authorId": "alice", "text": "Hello world"}'
```

Poll state:
```bash
curl http://localhost:8080/content/550e8400-e29b-41d4-a716-446655440000
```

Submit human review:
```bash
curl -X POST http://localhost:8080/content/550e8400-e29b-41d4-a716-446655440000/review \
  -H 'content-type: application/json' \
  -d '{"decision": "Approve"}'
```

## Using the Unison MCP server

Key tools:

- `typecheck-code` — typecheck a `.u` scratch file; use constantly, never show untypechecked code
- `docs` — read docs for any definition
- `view-definitions` — view source of a definition
- `search-definitions-by-name` / `search-by-type` — discover definitions
- `list-project-definitions` / `list-project-libraries` — inspect local codebase
- `lib-install` — install a library from Unison Share
- `update-definitions` — push definitions into the codebase

**Workflow for writing Unison code:**
1. Confirm type signatures before implementing (show user, wait for approval)
2. Write code in `scratch/main.u`
3. Typecheck with MCP after each function — never accumulate unchecked code
4. Only show typechecked code to the user

## Git workflow

- **Linear history** — atomic commits only; each commit must compile, pass tests, and represent one logical change. No merge commits.
- **Commit autonomously** — when a task is complete and tests pass, commit without asking. Concise message focused on the why.
