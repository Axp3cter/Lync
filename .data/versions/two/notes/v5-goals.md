# Lync v5: goals (draft)

Status: draft for review. Facts about v4 live in [v4-inventory.md](v4-inventory.md). Nothing here is
decided until you confirm it; open decisions are listed at the end.

## Direction as given

- v5 is a rewrite with no backward compatibility: API, wire format, file layout and tooling may all
  change.
- Fundamentals change aggressively, built on modern Luau (0.740 toolchain, current type solver) and
  the most advanced network compression that is technically available on Roblox.
- Logging and the whole failure surface (`print`, `warn`, `error`, `assert`, faults, tracebacks) are
  standardized: every situation has one defined handling and a clear trace back to its cause.
- The code follows the luau skill (`reference/style.md`) strictly, over any habit from v4.
- Test, bench and fixtures are redesigned so that coverage is known, not guessed.
- Code quality is never reduced to support a tool, a host or a legacy setting. Tools adapt to the
  code: no dropping `const` to keep a runtime, no weakening types for the old solver, and no roblox-ts
  support that costs the Luau code anything.

## Proposed goals

Each goal is phrased so that it can be checked.

1. **Smallest wire within a CPU budget.** Every encoding choice (bit packing, quantization, delta,
   entropy coding, batching) is justified by a measurement of bytes and CPU, taken on a host that runs
   the same VM settings as Roblox.
   - **Accuracy is declared per field:** exact, within a stated tolerance, or approximate for a while
     and then corrected. The encoder may use any scheme that meets the declaration.
   - **Values versus codec state:** values may be lossy. Codec state that both sides must mirror
     (adaptive models, entropy coder probabilities, shared predictors) must be identical on server and
     client.
   - **Floats across platforms: untested.** Whether float math gives identical bits on a Roblox server
     and on Windows, macOS, iOS and Android clients is a hypothesis, not a fact. Until it is tested,
     nothing assumes either answer.
     - **The probe:** `.data/probes/Determinism.luau` hashes the exact bits of 19 math operations over
       4401 inputs; equal hashes mean identical results.
     - **First result, checked:** on Windows with Luau 0.740, interpreted and native runs are
       bit-identical (`Determinism.windows-luau-0.740.txt`).
     - **Still to run:** a live Roblox server, and clients on Windows, macOS, iOS and Android.
   - **Preference:** exact by default, as the library's own preference.
2. **Modern Luau only.** `--!strict` everywhere, current solver, `const`, type functions, `read`
   fields, `buffer` and `vector`, the skill's file skeleton, naming molds and layout rules. No `any`
   outside documented boundaries.
3. **One failure model.** Designed in [v5-failures.md](v5-failures.md). Every situation the library can
   meet is in a catalogue that gives its channel (throw, assert, Result, drop, hook), its message mold
   and the test that proves it:
   - a caller's mistake throws a string at the caller's line;
   - a fault in user code (listener, responder, validator, transform) is contained and reported with
     the user's own traceback;
   - hostile input is dropped without letting anyone flood the output.
4. **Provable coverage.** Every claim in the spec and the docs maps to at least one test. Line coverage
   is measured on every run and gated. Tests are deterministic (seeded randomness, virtual time).
   v4's engine seam was never executed by any test; in v5 it is.
5. **Trustworthy benchmarks.** Sound statistics, stored baselines per host, a regression gate, and
   wire bytes per scenario as a first-class metric next to time and allocation.
6. **Hardened against exploiters.** Bounded CPU and memory per inbound frame, per-player limits, and
   fuzzing as a gate rather than a side test.
7. **Docs that cannot drift.** The reference is generated from or checked against source doc comments
   and the spec, and every example in the docs runs as a test.
8. **A joy to use.** Exact types and IntelliSense in Luau (luau-lsp, Studio) and roblox-ts, no
   boilerplate with traps in it, and errors that say what to do instead. The quality of `src` is
   never lowered for a tool: Luau types are written idiomatically, and the roblox-ts declarations
   are designed and tested on their own terms.

## Developer experience

Fixes target a class of problem, never one request.

### Principles

1. **Types are sound.** The type a codec carries is exactly the set of values it accepts and checks:
   never wider, never narrower. A user-supplied narrowing such as `packet<"1v1" | "2v2">(str(1, 3))`
   is ruled out, because the type would promise what the wire does not check.
2. **Types follow values.** Wherever a declaration holds a value that determines a type (member names,
   field names, tags, Enum items, instance classes), the type is derived from that value, with nothing
   spelled twice.
3. **Discoverable.**
   - Constructors are named for what they carry.
   - Every public symbol has hover documentation.
   - Misuse errors name the right construct. For example: "`str` bounds are byte lengths; for a
     fixed set of strings use …".
4. **No annotations in user code.** Handlers, replies, records and update patches are inferred from
   the schema.
5. **No boilerplate with traps.** v4 needed `start()` before sending, responders registered before
   `start`, and `flush` wired every frame, which failed when connected straight to a signal. Each
   rule is a trap. v5 removes such ordering rules, or makes them impossible to break.

### Case study: a closed set of values

The request: `str("1v1", "2v2")` should type the packet as `"1v1" | "2v2"`.

- v4 already had `enum({ "1v1", "2v2" })`, at 1 bit. The asker did not find it, which is a
  discoverability problem (principle 3).
- The general problem is a closed set of allowed values: string literals, numbers, booleans and
  Roblox Enum items. One codec family should cover all of them, inferring the exact type from the
  values (principle 2).

**What Luau 0.740 can infer** (checked with luau-analyze and Roblox definitions):

| Declaration | Carried type |
|---|---|
| `oneOf("1v1", "2v2")`, generic over arguments | `string`: literal arguments widen |
| `oneOf({ "1v1", "2v2" })`, generic over an array | `string` |
| `oneOf({ ["1v1"] = true, ["2v2"] = true })`, returning `keyof<T>` | `"1v1" \| "2v2"`, and writing `"3v3"` is a type error |
| `oneOf({ Lobby = true, Round = true })` | `"Lobby" \| "Round"` |
| `oneOf<<"1v1" \| "2v2">>("1v1", "2v2")`, explicit instantiation | exact, but every value is spelled twice |
| `oneOf(Enum.Material.Grass, Enum.Material.Rock)` | `Enum.Material` |
| `oneOf(Enum.Material)`, the whole Enum | not inferable: structural inference gives `unknown`, and type functions cannot read extern types |

**Direction.** A key-set table, `{ Lobby = true, Round = true }`, gives exact literal unions in Luau
through `keyof`, and in TypeScript through `keyof` on an object literal: one shape for both languages.
Enum items passed as values keep their Enum type.

**Open:**
- A whole Roblox Enum needs either an explicit type or a generated map of every Enum's item type,
  which goes stale with Roblox API updates.
- Number literal sets have no clean inference path yet.

### Same class of problem elsewhere

Each of these also needs a type derived from a literal argument, and argument widening blocks the
direct route. Each needs the same treatment as the case study.
- `keyBy("team")` should type `audience` keys as the field's type. In v4 only roblox-ts had this.
- `inst("Player")` should carry `Player?` rather than `Instance?`.
- Tagged unions: the discriminant name and variant names.

## Order of work

You proposed doing everything else first and `src` last. I recommend that order with one change: the
tests for each `src` module are written together with that module, not all up front.

1. **Spec.** The API, the wire format, the failure catalogue and the limits, written as numbered
   claims. Tests and docs both cite claim ids, which is what makes coverage traceable.
2. **Infrastructure.** None of it depends on `src`, and each piece is tested on its own:
   - toolchain, CI, the style checker and repo scripts;
   - the test runner, assertions, property engine, shrinker and coverage gate;
   - the simulated engine (remotes, players, clock, scheduler);
   - the bench harness and its statistics.
3. **`src`, bottom layer first.** For each module: tests from its claims, then the code, then the
   coverage gate for that module.
4. **Integration.** Model-based tests, fuzzing, and integration tests on real Roblox.
5. **Bench baselines and docs.** Recorded and generated last, once the numbers and surface are stable.

Why not literally `src` last: with no compatibility, the public API is new and the compression design
will reshape it (bounds, schema forms, delivery modes). Tests written in full against an imagined API
would be rewritten when the implementation teaches us something. Infrastructure and the spec carry no
such risk, so they can go first safely.

## Fixtures: first view

In v4, `fixtures/` holds six files, and only two are really shared between test and bench:

| v4 file | Used by | First view for v5 |
|---|---|---|
| `Doubles` (fake transport and roster) | tests and bench | becomes the simulated engine: one shared component with its own tests |
| `Faithful` (strict engine-like wire) | one stateful test | merged into the one simulated engine, so there is no second double |
| `Schemas` (sample schemas) | tests and bench | workloads; shared only if bench and test use the same ones |
| `Golden` (pinned bytes and hashes) | tests only | moves into `test/` |
| `Scenarios` (traffic scripts) | tests only, though its header says both | moves into `test/` unless bench adopts it |
| `Stage` (golden runner) | tests only | moves into `test/` |

So the case for a third folder is the simulated engine, not data.

The Studio decision weakens that case, because real remotes and players are now available. Two
needs remain:
- an in-process transport, for fast deterministic two-machine tests inside one VM;
- fault injection (loss, duplication, reorder, delay) for the lossy paths, which real remotes do not
  produce on demand.

If those stay small, `test/` and `bench/` are enough and `fixtures/` disappears. The research step
settles this, together with the internal design of `test/` and `bench/`.

## Areas of concern you have not raised yet

Not exhaustive.

### Toolchain and host

- **v4's host is gone.** The pinned Lune 0.10.5 rejects `const` with a syntax error (checked), so it
  could not run v5 code anyway; the Studio decision replaces it.
- **v4's benchmark numbers are not Roblox numbers.** Its Lune loader passes a custom environment,
  which deoptimizes every module and disables codegen. Benchmarks in Studio fix this.
- **The Luau 0.740 CLI** (checked: accepts `const`, `--coverage` writes lcov line hits) remains
  available if a pure module ever needs a local coverage run, but nothing depends on it.
- **StyLua conflicts with the skill.** The skill aligns runs of similar lines into columns with
  spaces after tabs, and StyLua rewrites spacing to its own layout. Dropped (decision 4).
- **Roblox type solver.** Roblox still runs `--!strict` scripts on the old solver unless a place opts
  in (per the skill's references, dated 2025-11). Under the quality principle, v5 targets the new
  solver and says so; it does not weaken its types for the old one.
- **Tests and benches run in Roblox Studio** (decided). Running outside Roblox is not a requirement,
  so no local Luau runtime is needed for them. Consequences:
  - **Real engine:** the real engine, remotes and players are under test, which removes v4's biggest
    blind spot. Studio's local server with several players gives real client-server traffic, and the
    `Stats` service gives real byte rates for the compression work.
  - **Automation:** this environment has the Roblox Studio MCP tools (run Luau, start and stop play,
    read console output), so suites can be driven from here.
  - **Coverage:** Roblox has no coverage tool. Feature coverage comes from the claims ledger, and line
    coverage needs our own source instrumentation (research).
  - **Repo tooling runs on Lute** (decision 2).
- **Pinned versions disagree.** v4 pins luau-lsp 1.69.0; the skill's toolchain is 1.70.1 with Luau
  0.740.
- **Require form.** The skill wants one require form throughout. String requires work on Roblox,
  but whether `.luaurc` aliases resolve on Roblox is unverified.

### Failure model and observability

- **v4 errors point nowhere.** Errors are raised with level 0 (`error(message, 0)`), so a misuse error
  carries no position at all.
- **Faults in user callbacks are not handled.** A validator or `:as` transform that throws on read
  escapes uncaught, is logged as a malformed frame (`drop.bounds`), and loses the rest of that frame.
- **`onLog` listeners are unprotected.** An error inside one is not caught.
- **The skill and v4 disagree** in three places, which need a library-specific reading of the skill:
  - the skill says no `[Module]` tags in messages; v4 prints `[lync]` and sends every kind
    through `warn`;
  - the skill says a rejected remote request returns silently, because logging it lets clients
    flood the output; v4 logs drops, rate-limited;
  - the skill reserves `warn` for recoveries.
- **Tracebacks across threads.** Listeners run on pooled threads, so the user's traceback has to be
  captured inside the thread (`xpcall` at the thread's entry), not where the error later surfaces.
- **Metrics.** A metrics surface (bytes per definition, queue depth, drops per code) would serve both
  users and the bench.

### Protocol and compression

- **Measure on Roblox.** Compression must be measured on Roblox itself: how a buffer is framed,
  per-remote overhead, and the 1000-byte unreliable cap. Lune cannot answer any of these.
- **Delta needs acks.** Delta against an acknowledged baseline needs acks, so the reliability model
  (what rides reliable versus unreliable) is a fundamental decision, not a detail.
- **Entropy coding costs CPU.** Range or ANS coders and adaptive models spend CPU per byte in Luau.
  The trade-off must be measured at server scale (for example 100 players), not per call.
- **Runtime composition or code generation.** v4 composes closures at runtime. Other Roblox libraries
  generate specialized Luau at build time. `loadstring` is unavailable on clients, so generating code
  at runtime is out.
- **The handshake carries too little.** It compares a single schema hash, with no protocol or layout
  version, so a mismatch cannot say which definition differs.
- **Float determinism.** Behaviour of floats, NaN and infinity across server and client needs a
  policy.

### Security

- Decode must bound allocation and CPU per frame and per player.
- Instance sidecars are attacker-controlled.
- Rate limits are per player and per definition.
- Fuzzing runs in CI.

### Testing, beyond what you raised

- **The engine seam was never run in v4.** No test called `Lync.start`, and the real
  `RemoteEvent`/`Players` path never executed. Testing in Studio covers it, but a Studio play session
  runs the server and each client in separate VMs, so multi-machine tests need orchestration across
  VMs.
- **Real time made tests depend on the wall clock.** v4 waits in real time in places. An injectable
  clock still matters in Studio, for deterministic tests of rates, deadlines and budgets.
- **Lossy paths need fault injection.** Real Studio remotes rarely lose or reorder anything, so the
  unreliable lane needs a fault-injecting transport to be tested at all.
- **Process-wide singletons block isolation.** These are the namespace registry, the log listeners
  and the thread pool. v5 scopes state to an instance or provides a reset.
- **No golden tooling.** v4 has no way to regenerate goldens, and a mismatch hides the differing byte
  unless it falls in the first 48 characters.
- **Mutation testing** is optional; it would show whether tests detect real faults, not just run
  lines.

### Benchmarks, beyond what you raised

- **Statistics.** Warmup, many samples, median with a spread, and a forced collection before allocation
  readings. v4 takes the minimum of 5 batches and has no spread.
- **Two kinds of bench.** Microbenchmarks and scenario benchmarks, the latter reporting bytes per
  player per second.
- **Comparison.** Optionally, compare against other Roblox networking libraries on the same scenarios.

### API under the skill's naming rules

Applying the skill strictly to the public API changes it a lot:

- **Abbreviations.** The skill forbids abbreviations, which rules out `str`, `int`, `vlq`, `vli`,
  `quant`, `inst`, `vec3` and `f32`.
- **No `get` or `set`.** The skill bans names built on `get`/`set`, which affects `Set:get` and the
  name `Set` itself.
- **Results and outcomes.** Expected failures return a `Result`, so query outcomes would change shape.
  Commands with several outcomes return singleton unions.

We need to decide how far the naming molds apply to a library's public surface.

### Packaging, docs, release

- **roblox-ts.** Is it in scope for v5? If yes, `index.d.ts` is generated or tested for parity. In
  v4 it is hand-written and drifts.
- **One version source.** v4's version is written in four places.
- **No changelog.** v4 has none.
- **Vendored typedefs.** v4 vendors about 19k lines of typedefs with no record of where they came
  from. They could be fetched at setup instead.

### Runtime scope to revisit

- Parallel Luau (actors);
- StreamingEnabled and the `inst` codec;
- deferred signal behaviour;
- players who joined before start;
- the 30-second limit of `BindToClose`.

## Self-review: where these drafts lowered quality

Places where an earlier draft traded away comfort (QOL) or code quality (QOC) to fit a tool, a
platform limit or a habit, with the correction. Items 1 and 14 were caught by you; the rest come from
a review prompted by item 1.

| # | What the draft said | Why it lowers quality | Correction |
|---|---|---|---|
| 1 | `src` uses relative requires, because Roblox has no aliases | Shaped source around a runtime limit that the build already solves | `.luaurc` aliases in `src`, converted by darklua (decision 9) |
| 2 | Shared test and bench code lives in one module under `test/` that bench requires | A cross-tree dependency and a layer-check exception, chosen only to avoid a folder | Aliases make a dedicated shared folder free. Decide its name and boundary in the folder design. |
| 3 | Carry over v4's `Rng`, shrinker and `Generate` unchanged | Imports v4 style into a rewrite that has no compatibility and follows the skill strictly | Keep the algorithms; rewrite them in skill style, with their own tests |
| 4 | Thrown messages carry a code token like `[LYNC-12]` | Codes in text are noise; code that branches needs structured data | Codes live in structured data (`onLog` records, LogService context). A source marker stays, as a deliberate deviation from the skill (see below). |
| 5 | Closed sets are declared as a key-set table, `{ Lobby = true, Round = true }` | Settled after three probes on a form clunkier than anything a user would write unprompted | Probe more signatures first; the natural call form wins if any signature gives exact types |
| 6 | Whole-Enum typing and `inst("Player")` typing dropped, because a generated type map "goes stale" | Staleness is a tooling problem, not a reason to drop exact types | A Lute script regenerates type maps from the pinned API dump on each toolchain bump |
| 7 | The single-file bundle shows darklua's `__DARKLUA_TYPE_x` names on hover, accepted as is | Users of that channel see internal names | The entry module re-exports every public type under its clean name (to verify on hover in Studio) |
| 8 | Type functions sit in a separate `Types` module, because "Luau cannot re-export a type function" (v4's belief) | One more require for every user who names a type | Checked on Luau 0.740: a generic alias (`export type Infer<C> = InferImpl<C>`) exports a type function across modules. Export `Infer`, `Schema` and `Update` from the main module. |
| 9 | roblox-ts served through duplicate Luau members (`size()`, `entries()`, `players()` beside `#` and `__iter`) | Bends the Luau surface for TypeScript, against the quality principle | The Luau surface stays idiomatic. TypeScript gets what it needs from a surface designed for it (roblox-ts research). |
| 10 | Tests need an in-process transport and a manual clock injected into `src` | Test-only hooks contort source | Only seams with product value: clock and transport as real constructor parameters with defaults. No hook that exists only for tests. |
| 11 | `get(id)` returns the live internal record, with a doc rule "read it, never change it" (v4) | A rule enforced only by documentation | Records are exposed with `read` fields, so a write is a type error |
| 12 | Per-function `@native` as the fallback because bundles drop hot comments | Lets the output generator dictate source annotations | Source annotations follow measurement and the skill. If shipped code needs a hot comment, use `append_text_comment` with `retain_lines` and accept a slightly larger file. |
| 13 | Line coverage through a Lute instrumentation transform | Machinery that is no longer needed | Native coverage measured working in a play-test server (research §6); drop the transform. Feature coverage by claim ids stays. |
| 14 | Codec state uses integer-only math because floats differ across platforms; tracebacks need the line-retaining generator | Stated as fact without a test; constrained the build for a need that does not exist | Floats are being tested on each platform (goal 1); diagnostics read user frames through `debug`, so lines in shipped code do not matter |

### Deliberate deviations from the skill

The skill is followed strictly unless it is wrong for a library. Each deviation is listed here with its
reason.

- **Source marker in messages.** The skill forbids `[Module]` tags, because a tag repeats the file's
  name and a message that names its subject can be found by searching. That holds for game code. A
  library's messages land in someone else's console, and their subject is the user's own definition
  name, so which code emitted the line is missing information, not repetition.
  - Every message Lync prints or throws starts with one fixed marker (form to decide, e.g. `[Lync] `).
  - Codes and details go in structured fields, never the text.
  - Checked in Studio: `LogService:GetLogger` is "not yet available", and `LogService:Warn` prints only
    the filled template. Nothing in Roblox marks a library's output today, so revisit when `GetLogger`
    ships.
- **Raising from private code in `src/`.** The skill raises only from public functions, at level 2,
  and never above level 1 from a private function, because inlining at `-O2` shifts the frames. Some
  of Lync's mistakes are found deep inside private code on behalf of a user's call, such as a value
  that fails its codec mid-encode. There the raise finds the user's frame by walking `debug.info`
  at raise time instead of counting levels ([v5-failures.md](v5-failures.md) §4.1). `scripts/`
  follows the skill as written.
- **A handler in Private.** The standard puts `on`-named handlers in Handlers, below Private, and
  forward-declares only for mutual recursion. A handler that private functions use must be defined
  above them, so it sits in Private directly above its first user, keeping its `on` name, with a
  note.
  - `harness/Properties.luau`'s `onCaseError`, an `xpcall` message handler, is called from four
    private attempt sites.
  - `harness/Link.luau`'s `onWaitTimeout`, a timer, is started from a private function.
- **A require inside `start()`.** `test/Boot.server.luau` requires the harness inside `start()`, not
  in Imports, so a driven run turns coverage on before the first require and the harness's own lines
  are counted.

## Decisions

| # | Question | Answer |
|---|---|---|
| 1 | Test and bench host | Roblox Studio only. CI does not run the suite. |
| 2 | Repo tooling host | Lute 1.0.0. Checked: it runs v5 syntax, lists directories, reads files and runs subprocesses. |
| 3 | roblox-ts | In scope. Research how to do it best with the latest roblox-ts. |
| 4 | Formatter | StyLua dropped. The skill's layout is held by agent review (decision 10). |
| 5 | Naming on the public API | Mine to decide, for the cleanest and clearest surface. |
| 6 | Code generation | Readers and writers composed at runtime, on Roblox, with no build-time code generation (my reading of "this is roblox"). |
| 7 | User type solver | The new solver, under the quality principle. |
| 8 | Folder layout | `src/`, `test/`, `bench/`, `harness/` (shared by test and bench), `scripts/`, `packaging/` (manifest templates), with all output in the git-ignored `build/`. Four darklua variants: test, bench (`src` byte-identical to release), release, bundle. |
| 9 | Require form | `.luaurc` aliases in `src`; darklua's `convert_require` rewrites them for Roblox (decided). Code synced into Studio for tests is therefore a darklua build too. |
| 10 | Verifying quality | A thorough agent review of every file against the Luau skill and these documents. Tool runs are evidence only, never the verdict, and there is no custom style or layer checker. Builds still refuse to package an artifact with an unconverted alias require, which guards correctness, not quality. |

## Toolchain

`rokit.toml` at the repo root (rokit 1.2.0), every tool at its latest release on 2026-10-02:

| Tool | Version | Role |
|---|---|---|
| rojo | 7.7.1 | sync to Studio, build the model |
| luau-lsp | 1.70.1 | analysis with Roblox definitions (same version as the skill's toolchain) |
| lute | 1.0.0 | host for repo scripts: style checker, layer check, build steps |
| wally | 0.3.2 | package publishing |
| darklua | 0.19.0 | the distribution build (see below) |

Not carried over from v4:
- **Lune:** it cannot parse `const`.
- **StyLua:** dropped (decision 4).

**Lute, verified against its source** (`.data/projects/lute-primary`):
- **Versions.** It embeds Luau 0.740 (`extern/luau.tune`). The source tree says 1.0.1; the latest
  release, the one installed, is 1.0.0.
- **Modules:** `@lute/fs`, `process`, `system`, `task`, `io`, `time`, `net`, `crypto`, `luau`, `vm`
  and syntax; `@std` adds `json`, `path`, `test` and syntax tooling.
- **Built-in commands:**
  - `lute test` finds `.test.luau` and `.spec.luau` files and runs them with `@std/test`;
  - `lute check` type-checks with the new solver in strict mode, with definition files supplied
    through `.config.luau`;
  - `lute lint` is a linter whose rules are Luau visitors over a syntax tree;
  - `lute run --profile` writes Perfetto traces.
- **`lute transform`** runs Luau codemods over a syntax tree that carries line and column spans and
  supports replacements. It can therefore insert coverage counters into source.
- **No coverage tool.** There is LCOV code in the tree, but nothing calls it.
- **Processes, probed on 1.0.0:**
  - `process.args[1]` is the running script's own path; a command's words start at `[2]`. A probe
    that ran `lute run process.args[1]` started itself without end and exhausted the machine's
    memory twice.
  - The `env` option of `process.run` merges with the parent's environment. It can set or override
    a variable but never remove one.
  - Assigning `process.env.X` changes the real environment, which children inherit, and assigning
    `nil` removes it from them.
  - `process.run` has no `timeout` option in 1.0.0; it is silently ignored, so a hung tool cannot
    be stopped. The option exists in the 1.0.1 nightlies.
  - `process.run` yields to the scheduler: two 2-second children in `task.spawn` threads finish in
    about 2 seconds together, so `dev` can run several tools at once.
  - There is no standard-error writer and no `warn`, and `io.write` hangs when standard output is a
    file, so scripts write through `print`.
  - `@std/json` decodes the escape `\u0000` as a backslash, so report strings must not carry NUL
    (binary goes through the hex window).
- **Waiting on 1.0.1.** These come back when the pin moves to 1.0.1:
  - `fs.move`, so `Files.write` can write a temporary sibling and rename it over the
    target. Until then it writes in place, and its documentation says so.
  - a printer that keeps `const`, which codemods need;
  - `lute check` accepting `read` indexers. Until then luau-lsp is the only checker for `scripts/`.
  - a `timeout` for `process.run`, so `Tool` can stop a tool that hangs.

**darklua, verified against its source** (`.data/projects/darklua-main`):
- **Parsing.** It parses with full_moon 2.2.0 into its own syntax tree. Support arrived for
  `read`/`write` modifiers, type functions and attributes in 0.18.0, and for `const` in 0.19.0.
- **Rules.** It has 32 rules (`src/rules/mod.rs`) plus a bundler.
- **Generators:**
  - `retain_lines` is the default. It tries to keep line numbers and keeps comments.
  - `dense` fills lines up to `column_span` (default 80) and drops every comment.
  - `readable` regenerates everything and also drops every comment.

## Distribution build

`src` is written for readers, in strict skill style. What users receive is a darklua build product,
transformed aggressively (decided). Nobody edits the output.

**Release channels** (decided):
- the Roblox model file;
- a single bundled `.luau` file that users drop in as one ModuleScript and require;
- the Wally package;
- the npm package for roblox-ts.

**darklua only (decided).** The build uses only darklua's own features, with no custom steps around
it. Whatever darklua cannot do is not worked around.

**The single file, as darklua delivers it** (verified in its source and tests):
- **Modules.** Each bundled module becomes a lazily called, cached function. Bundling accepts the
  `path` and `luau` require modes, which understand `./`, `@self/` and `.luaurc` aliases. A literal
  require it cannot resolve fails the build.
- **Exported types.** They are moved to the top of the file and renamed `Name__DARKLUA_TYPE_<id>`.
  A requirer sees only the types the entry module re-exports, and hover names carry that suffix.
- **Type functions survive** as generic aliases. Checked on Luau 0.740: an alias over a type function
  resolves to the real type and rejects wrong values. v4's comment that Luau cannot alias a type
  function is wrong for 0.740.
- **Hot comments do not survive.** `--!strict`, `--!native` and `--!optimize` in bundled modules
  become inert, and `dense` and `readable` drop every comment anyway.
  - darklua's `append_text_comment` can put one back at the top of the file, but only with the
    `retain_lines` generator and with no comment removal after it.
  - Per-function `@native` attributes survive, since they are syntax.
- **Open question:** the densest generator conflicts with keeping hot comments. Whether shipped code
  needs `--!strict`, `--!native` or `--!optimize` (rather than per-function `@native`) is part of the
  research.

**What it buys.** Comments, whitespace and local names make no difference to runtime speed on Roblox,
because the engine compiles to bytecode either way. Aggressive transforms buy a smaller package and
source that is hard to read or copy. Speed comes from how `src` is designed, not from the build.

**Three limits** keep the build from breaking goals set elsewhere:

1. **Diagnostics point at user code** (goal 3).
   - Lync builds its messages from the caller's frame, read with the `debug` library at the call (or
     at the declaration, for definition sites). User code is never transformed, so those lines are
     always right.
   - Lync's own internal lines and function names may be minified freely, since only maintainers read
     them, in the unminified test build.
   - So no message may depend on Lync's own lines or function names.
2. **Nothing gets slower or loses types.**
   - **Types stay.** Never `remove_types`: native code generation reads parameter types, and users'
     autocomplete and checking read the public types from the package.
   - **Attributes stay.** `remove_attribute` removes every attribute unless its `match` list says
     which to remove, so `@native` must never match.
   - **No syntax downgrades.** Never the rules that downgrade syntax for non-Luau targets:
     - `remove_compound_assignment`, `remove_interpolated_string`, `remove_if_expression`;
     - `remove_continue`, `remove_floor_division`;
     - `remove_method_definition`, `remove_method_call`;
     - `convert_luau_number`, `make_assignment_local`.
3. **Behaviour does not change.** A rule that removes failure checks (`remove_assertions`) is used
   only if the failure catalogue says those checks are development-only.

**Candidate rules**, each kept only if it passes the three limits and a size measurement:
- `remove_comments`, `remove_spaces`, and the densest generator;
- `rename_variables`, including function names;
- `remove_unused_variable`, `filter_after_early_return`, `remove_empty_do`, `remove_nil_declaration`;
- `convert_index_to_field`, `remove_function_call_parens`, `compute_expression`;
- `convert_require` (required): `src` uses `.luaurc` aliases, which Roblox cannot resolve.

**Build variants.** `inject_global_value` plus `remove_unused_if_branch` give one source and several
builds:
- **release:** stripped;
- **test:** keeps development instrumentation, for example coverage counters injected by a Lute
  transform, which answers Roblox's missing coverage tool.

**Rule details** (verified):
- `rename_variables` renames locals, parameters and loop variables, never globals. Function names are
  renamed only with `include_functions = true` (default `false`).
- `remove_assertions` removes calls to the global `assert`. In expression position `assert(x)`
  becomes `x`. Argument side effects are kept by default.
- `inject_global_value` replaces a global, or `_G.NAME`, with a constant or an environment value.
  `remove_unused_if_branch` then drops branches it can prove dead. Rule order matters: inject first.

**Research items:**
- **Size wins:** measure each candidate rule's.
- **Hot comments:** whether shipped code needs them, which decides the generator.
