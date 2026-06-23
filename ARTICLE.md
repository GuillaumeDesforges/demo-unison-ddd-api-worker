---
title: Truly composable and reusable business logic
subtitle: From Dependency Injection to Algebraic Effects
author: Guillaume Desforges <guillaume.desforges.pro@gmail.com> 
---

At my previous job, building a SaaS for B2B Sales, we had AI workflows that would be triggerable both by users from the UI and on a schedule.
When triggered by the UI, it was important to keep the attention of our distractable users, so we would want to use a single HTTP request with server-sent-events (SSE) to provide them with live feedback, streaming progress and output in real-time.
Some of these workflows would also be triggerable on a CRON or some events, and had to be thoroughly completed as to not break the user experience throughout the app, we used Temporal for these.

What some may call "AI workflows" or just "workflows" can also be seen as a "use case" or a "saga" even.
No matter the name, all of them have this idea of writing a sequence of business logic that needs to happen with a specific control flow.

In Domain-Driven Design and similar, we'd like to write this logic once as a pure expression, then inject behavior as dependencies.
Unfortunately, I've found it amazingly hard to do that at scale in mainstream languages such as Go, Python or TypeScript.
In my case, using Go and Temporal, it was not clear at all what kind of code architecture and convention could help us refactor this "business logic orchestration" code to be run in both the HTTP server with streaming and in Temporal with the Worflows/Activities boundaries (and wrapping).

So we wrote it twice.
Every time product changed something about a flow, you touched both.
Code duplication, even when documented, is a typical footgun I'd rather avoid.

In Go with Temporal, it would look something like this (discarding `err` handling):

```go
// HTTP handler version
func handleSubmit(w http.ResponseWriter, r *http.Request) {
    input := parseInput(r)
    context := streamGatherContext(w, input)
    output := streamGenerateOutput(w, context)
    score := streamScoreOutput(w, output)
    streamSave(w, context, output, score)
}

// Temporal workflow version
func Submit(ctx workflow.Context, input SubmitInput) error {
    context := workflow.ExecuteActivity(ctx, GatherContext, input)
    output := workflow.ExecuteActivity(ctx, GenerateOutput, context)
    score := workflow.ExecuteActivity(ctx, ScoreOutput, output)
    workflow.ExecuteActivity(ctx, Save, NewScoreInput(context, output, score))
}
```

Two source of truths to what "submit" means in our business logic.
Yikes.

Our first idea was to use interfaces to inject handlers that wrap with the right functions, but in the case of Go and Temporal that led to a rabbit-hole of problems. 

In order to make application services registerable and runnable as Temporal Workflows in a Go Temporal worker:
- to register business logic functions as workflows, we'd need to register them as wrapped functions to accept the first `ctx temporal.WorkflowContext`
- to register methods of dependencies as activities, we'd need to register them all
- for both workflows and activities, Temporal registers them as a flat list, so we must make sure there is no naming collision of methods across dependencies
- meanwhile the dependencies injected in the business functions used as workflows should be structs that re-declare methods with a boilerplate ExecuteActivity call each
- at this point, you don't even call other business logic functions as child workflows, which may or may not match your needs

This makes a lot of effort that is error-prone at scale and can't be linted statically.

## Algebraic effects are not that scary

What kind of abstraction would allow to write a logic once for different runtimes?

[Unison](https://unison-lang.org/) is a functional programming language that allows this through its concept of "*abilities*".

Using abilities, we can _declare_ what a function _requires_ in its **type signature**, binding behavior only when calling them.

```unison
ability Logger where
  log : Text ->{Logger} ()

greet : Text ->{Logger} ()
greet name =
  log ("Hello, " ++ name)
```

`greet` knows nothing about what `log` actually does.
The `{Logger}` in its type signature is a compile-time declaration: "I need someone to tell me what `log` does."
That someone is a _handler_, provided at the call site.

A handler provides a concrete implementation for an ability by intercepting the effect and deciding what to do with it.
You wrap the function call in handlers, one per ability, and the runtime threads them through automatically.
This can be seen as an extreme form of _late-binding_.

```unison
Logger.printHandler : '{g, Logger} a ->{g, IO} a
Logger.printHandler action =
  go = cases
    { a }            -> a
    { log msg -> k } -> printLine msg; handle k () with go
  handle action() with go

Logger.collectHandler : '{g, Logger} a ->{g} ([Text], a)
Logger.collectHandler action =
  go logs = cases
    { a }            -> (logs, a)
    { log msg -> k } -> handle k () with go (logs :+ msg)
  handle action() with go []

-- same function, two different behaviors:
Logger.printHandler do greet "Alice"        -- prints "Hello, Alice"
(logs, _) = Logger.collectHandler do greet "Alice"  -- logs = ["Hello, Alice"]
```

The two branches of `go` cover the two states the computation can be in.
`{ a }` matches when it's finished (`a` is the final result).
`{ log msg -> k }` intercepts a call to `log` mid-computation: `msg` is the argument, and `k` is a suspend-and-resume handle (everything that comes _after_ the `log` call, waiting to be picked back up).
The handler does its work (prints, or appends to a list), then resumes by calling `handle k () with go`, handing `()` back as `log`'s return value.

These "abilities" are Unison's implementation of _algebraic effects_, which is the abstraction that allows us to write some logic once and decide how it should run later.

## Let's get our hands dirty

A quick note before we go further: this demo uses [Restate](https://restate.dev/) rather than Temporal because Restate's surface is simpler, which made it feasible to build a Unison SDK for it, while Temporal's surface would have been considerably larger.

The demo uses a content moderation queue: users submit text posts, an AI classifier makes a moderation decision, and the author is notified of the outcome. Uncertain content is escalated to a human reviewer via a separate endpoint. The full source is available at [github.com/GuillaumeDesforges/demo-unison-ddd-api-worker](https://github.com/GuillaumeDesforges/demo-unison-ddd-api-worker).

Three abilities cover everything the saga needs:

```unison
ability ContentStore where
  getContent  : ContentId ->{ContentStore} Optional Content
  saveContent : Content   ->{ContentStore} ()

ability AIClassifier where
  classify : Text ->{AIClassifier} ModerationDecision

ability Notifier where
  notify : Text -> ModerationDecision ->{Notifier} ()
```

Each `ability` block is like an interface: it declares a set of operations.
The type signature `classify : Text ->{AIClassifier} ModerationDecision` says: "this function takes a `Text`, uses the `AIClassifier` ability, and returns a `ModerationDecision`".
The curly braces list the effects.

Now, the business logic itself:

```unison
moderationSaga : Content ->{AIClassifier, Notifier, ContentStore} ()
moderationSaga content =
  use Content.status set
  saveContent (set Submitted content)
  decision = AIClassifier.classify (Content.text content)
  match decision with
    Escalate _ ->
      saveContent (set (PendingHumanReview decision) content)
      notify (Content.authorId content) decision
    _ ->
      saveContent (set (AutoModerated decision) content)
      notify (Content.authorId content) decision
```

Nothing here talks about durable execution, just: save, classify, match on the decision, branch accordingly.
It almost reads like English.
Yet, it can run both with or without durable execution!

The type signature tells you everything: this function requires `AIClassifier`, `Notifier`, and `ContentStore` abilities.
The compiler will reject any call to `moderationSaga` that doesn't provide all three (unlike some languages that accept `nil` as an answer 👀).

Here's what the direct mode looks like, running inline inside an HTTP handler:

```unison
ContentStore.sqliteHandler db do
  AIClassifier.claudeDirectHandler do
    Notifier.printHandler do
      moderationSaga content
```

And here's the Restate mode, running as a durable workflow:

```unison
ContentStore.restateHandler db do
  Notifier.restateHandler do
    AIClassifier.restateHandler do
      moderationSaga content
```

**Same function. Zero changes.**

`moderationSaga` doesn't know whether it's running inline or inside a Temporal-style durable workflow.
`ContentStore.sqliteHandler` runs a plain SQLite query.
`ContentStore.restateHandler` wraps the same query in `ctx.run`, which journals it so Restate can replay it deterministically on retry.
The infrastructure lives entirely outside of the business logic, in the abilities' handlers.

This also makes testing straightforward.
You don't need a running server, a database, or a Restate instance.
Just like one may inject stub dependencies, we can stack pure stub handlers.
Each ability has a pure in-memory counterpart: `AIClassifier.runPure` returns a fixed decision, `Notifier.runPure` collects notifications into a list, and `ContentStore.runPure` works against an in-memory map.

```unison
Saga.runTest initialStore aiDecision content =
  noAI = do AIClassifier.runPure aiDecision do moderationSaga content
  (finalStore, (notifs, _)) = ContentStore.runPure initialStore do Notifier.runPure noAI
  (finalStore, notifs)
```

```unison
test> moderationSaga.tests.approve =
  content = Content (ContentId "c1") "alice" "hello world" 0 Submitted
  (store, notifs) = Saga.runTest Map.empty Approve content
  test.verify do
    ensureEqual (Some (Content.status.set (AutoModerated Approve) content)) (Map.get (ContentId "c1") store)
    ensureEqual [("alice", Approve)] notifs

test> moderationSaga.tests.reject =
  content = Content (ContentId "c2") "bob" "buy cheap pills" 0 Submitted
  (store, notifs) = Saga.runTest Map.empty (Reject "spam") content
  test.verify do
    ensureEqual (Some (Content.status.set (AutoModerated (Reject "spam")) content)) (Map.get (ContentId "c2") store)
    ensureEqual [("bob", Reject "spam")] notifs

test> moderationSaga.tests.escalate =
  content = Content (ContentId "c3") "carol" "maybe ok?" 0 Submitted
  (store, notifs) = Saga.runTest Map.empty (Escalate "uncertain") content
  test.verify do
    ensureEqual (Some (Content.status.set (PendingHumanReview (Escalate "uncertain")) content)) (Map.get (ContentId "c3") store)
    ensureEqual [("carol", Escalate "uncertain")] notifs
```

## Wrapping up

The insight here is not specific to Unison or Restate.
It's that *effects are a design tool*, not just a runtime concept.

Dependency injection is a well-proven pattern that solves the same core challenge: keep business logic decoupled from infrastructure so you can swap implementations and test in isolation.
And to be fair, with enough glue code (or reflection, in languages like Python or TypeScript), you can get a long way with DI too.

The genuine advantage of algebraic effects is that *composition is first-class and zero-cost*.
With DI, composing two services with different dependencies requires explicitly wiring them together, whether by hand or through a container.
With effects, if `sagaA` requires `{AIClassifier, ContentStore}` and `sagaB` requires `{Notifier, ContentStore}`, then `sagaA; sagaB` automatically requires `{AIClassifier, ContentStore, Notifier}`.
The type system tracks the union for free, and the compiler statically guarantees that all effects are handled before the program runs.
No glue, no registration, no runtime surprises.

The business logic is the unit of reuse, and composition has no seams.
In large and complex applications, this is a huge win.
