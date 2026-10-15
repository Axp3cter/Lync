# Lync v5: tests and benchmarks

What runs where, how results reach the terminal, how coverage is known, and the order to build it in.
Status: proposal for review. It builds on [v5-goals.md](v5-goals.md), [v5-failures.md](v5-failures.md),
[v5-research.md](v5-research.md) and [v4-inventory.md](v4-inventory.md) §9 and §10.

**How to read.** A fact names its source. **(U)** marks something unverified; §11 step 0, one Studio
session, settles every (U). `W-12` and `A-3` are spec claim ids (§4); `H-n` are the harness's own
(§12). Names follow the skill: a class is a singular noun, a library module a plural, nothing is
abbreviated, a command is a verb phrase.

## 1. Decisions

| # | Question | Decision |
|---|---|---|
| 1 | `fixtures/` folder? | No. `harness/` holds machinery shared by test and bench (simulated engine, sample workloads); `test/` and `bench/` hold content. Goldens are machine-written data in `test/golden/`. |
| 2 | Spec claims | Tests cite claim ids as data. A Lute command checks ids both ways without Studio; a run report proves each claim with a passing test. |
| 3 | Results | One report per run: always in Output, and by HTTP POST to a receiver inside `dev test` and `dev bench`. Rojo carries source only. **Studio measures, Lute judges.** |
| 4 | In-process transport | `Network`, `Timeline` and `Roster`, composed by `World`; a frame's fate is a list of delivery delays. |
| 5 | Coverage | Native, server DataModel only, enabled before the first require. Gate: every executable line, less exclusions that record the line's text and a reason. |
| 6 | Bench statistics | Warm-up, 30 samples, median with a bootstrap interval, Tukey fences that flag and keep, Mann-Whitney against a baseline keyed by host. |
| 7 | Optimization level | Fingerprint rows record the level a host really runs at. No comparison across fingerprints; absolute CPU claims need one live-server run. |

## 2. What the platform decides

| Fact | Source | Consequence |
|---|---|---|
| `ScriptContext:EnableCoverage` works in the play-test server DataModel, per line (-1 non-code, 0 uncovered); clients and `--!native` untested; it needs plugin security | research §1.3, §6 | Coverage is server-only, and a driver makes the call (§8) |
| An error in a `task.spawn` thread is reported natively | failures §9 | A test fails on an uncaught error it did not claim (§5.5) |
| `test.json5` uses `retain_lines` and injects `IS_DEVELOPMENT = true`; `bench.json5` injects `false` and bench `src` is built by `release.json5` | `.darklua/` | Test traces and coverage lines are the repository's lines. Bench code touches `src` only through shipped surface. |
| `emitLegacyScripts` is `false` | `default.project.json` | `*.server.luau` is a Script with `RunContext` set. Running from ReplicatedStorage is (U). |
| Lute has non-blocking `net.server.serve` with request bodies (source tree 1.0.1; the pin is 1.0.0) | `.data/projects/lute-primary` | The terminal can host a receiver; confirm on 1.0.0 |
| A Studio log carries `FLog::Output` lines (engine messages seen; script `print` lines (U)) | checked here | A fallback return path |
| The Studio MCP's `execute_luau` reaches server and client DataModels | research §1.3 | Driven runs use it; a human can use the command bar (U) |

## 3. Layout

```
harness/                modules in the table below, and Boot.client.luau (starts an Agent)
test/
  Boot.server.luau      starts the Conductor on this folder
  Exclusions.luau       coverage exclusions, as data
  src/  harness/        one suite per module, at the module's relative path
  behavior/             spec promises through the public API on a World, by spec area
  hostile/              malformed and adversarial input, fuzz budgets
  live/                 pair tests on real remotes and players
  models/               reference models for stateful properties
  generators/           Lync-specific generators: codec trees, corrupted frames
  golden/               pinned values written by tooling, at the path of the suite that reads them
  types/                files whose deliberate type errors are the proof (§4)
    ts/                 .ts files checked against index.d.ts: the roblox-ts declaration proofs (spec README)
bench/
  Boot.server.luau      starts the Conductor on this folder
  micro/                one operation through the public surface and seam parameters
  scenarios/            virtual-time runs on a World
  anchors/              reference rows that are not Lync (§10.5)
  baselines/            stored results, one folder per host label
```

| Group | Module | Is |
|---|---|---|
| Declare and check | `Suite`, `Check`, `Recorder` (classes) | a file's declarations; the assertions a body gets; capture of observer events, `LogService.MessageOut` and `ScriptContext.Error` |
| Run | `Conductor`, `Agent`, `Link` (classes) | server coordination; per-DataModel execution; the channel between a pair's halves |
| Properties | `RandomSource` (class) | seeded draws that record and replay a tape |
| | `Generators`, `Tapes`, `Properties` | combinators; shrinking; the case loop |
| Simulated engine | `Timeline`, `Network`, `Roster`, `World` (classes) | virtual time, the fault-injecting transport, players, their composition |
| | `Workloads` | named sample schemas with seeded value and traffic generators, shared by tests and bench |
| Reporting | `Reports`, `Printouts`, `Deliveries` | the report record; its text; sending it out |
| | `Hits`, `Endpoints` | coverage calls; the receiver's port, one data module |
| Measuring | `Statistics`, `Comparisons` | the arithmetic; baseline verdicts |
| | `Sampler`, `Benchmark`, `Gauge` (classes), `Fingerprints` | the timing loop; row declarations; wire-byte measurement; host fingerprint |

**Names.** No abbreviations: `RandomSource`, not v4's `Rng`. Assertion methods are verbs (`holds`,
`equals`, `approximates`, `throws`, `includesEvent`, `matchesGolden`), never question-shaped like `isNear`,
which would promise a boolean. Entry scripts are `Boot` because a script cannot share a name with a sibling
module.

**Layers**, held by agent review (goals decision 10), with no checker:
- `src` requires nothing from the other folders; the release holds `src` alone.
- `harness` requires `src` for types, and for the public API in `Workloads`. Never a private module.
- `test/behavior`, `test/hostile`, `test/live` and `bench/` touch `src` only through the public surface and
  the seam parameters; only `test/src` suites require their own module.
- `Statistics`, `Comparisons`, `Reports` and `Printouts` use no Roblox global, so `scripts/` may require
  them.

## 4. Spec claims and the ledger

**Ids.** `<area>-<number>`, one prefix per spec document (`W` wire, `A` API; the spec assigns the rest),
numbers never reused. A claim is one checkable sentence. `H` is this document's.

**Proof kinds**, recorded per claim in the ledger:

| Kind | Meaning |
|---|---|
| Tested (default) | at least one passing test cites it |
| Typed | a file in `test/types/`; each deliberate mistake follows the note `-- proves A-9; the checker must report an error on the next line`. `claims` runs luau-lsp on the folder and fails on a marked line without a diagnostic or an unmarked line with one (as in `.data/probes/ApiTypes.luau`) |
| Reviewed, Waived | judged by agent review; waived with a recorded reason that every report shows |

**Tags are data.** A declaration cites its claims as the first argument, and an empty list throws:

```luau
-- Sketch; ids are illustrative.
local suite = Suite.new("Varint", "Everywhere")

suite:prove({ "W-12" }, "writes 300 in two bytes", function(check: Check): ()
	check:equals(buffer.len(Varint.write(300)), 2)
end)

suite:proveForAll({ "W-13" }, "reads what it wrote", Generators.wholeNumber(), readsWhatItWrote)
```

**Two checks.**
1. **`claims`, static, no Studio.** It reads the spec files and the tags in `test/` through the syntax
   tree (`lute transform` gives one). An unknown tag is an error; an uncited claim is `Untested`.
2. **`judge`, on a full run's report.** A claim is `Proved` when a cited test passed in a full run. A
   skipped test counts for nothing. States: `Proved`, `Failing`, `Untested`, `Skipped`, `Waived`.

The output is a table per area, a line per claim with its tests, and the reverse view. A tag says a test
is about a claim, not that it could fail; that is review, and mutation testing (optional, goals) can follow
the first `src` module.

## 5. The test runner

### 5.1 Processes

- **`test/Boot.server.luau`** asserts `RunService:IsStudio()` and `IS_DEVELOPMENT`, waits for a driver when
  the run is driven (§8), then starts a `Conductor` on its own folder. The bench's `Boot` asserts
  `IS_DEVELOPMENT` is false, so a mis-mounted build cannot time a test variant.
- **`harness/Boot.client.luau`** starts an `Agent`, which serves tests and bench rows alike.
- **`Conductor`** walks its folder's modules in sorted path order, filters them, and plans work items
  `{ id, suite, title, where, clients }`. It runs server items through its own `Agent`, sends client items
  out, merges the outcomes into one report and delivers it.
- **`buildId`**, a hash of the sorted ids and `VERSION`, is echoed by every client; a mismatch stops the run
  and names the stale side.
- **Remotes.** The Conductor creates `HarnessChannel` (`WorkAssigned`, `WorkReported`) in ReplicatedStorage;
  Lync's own remotes never orchestrate Lync's tests.

| Session | DataModels | What runs |
|---|---|---|
| Run | server | server runs; pairs and live tests are skipped |
| Play | server and one client | client runs, and one-client pairs |
| Clients and Servers, N clients | server and N | pairs needing up to N (`StudioTestService:ExecuteMultiplayerTestAsync` allows 8) |

The Conductor waits 30 s for the clients the plan needs. A pair without them is `Skipped` with the reason,
never passed.

### 5.2 Declarations

| Form | Runs |
|---|---|
| `suite:prove(claims, title, body)` | one body; it builds a `World` when it needs one |
| `suite:proveForAll(claims, title, generator, property)` | a property over generated values (§6) |
| `suite:provePair(claims, title, serverHalf, clientHalf)` | both halves, in the server and in a client; only in `test/live` |

- `Suite.new(name, where)` takes `"Server"` or `"Everywhere"`, which runs the suite in the server and in
  every client DataModel. `test/src` and `test/hostile` use it, because interpreter and native code both
  ship and a native bug has been seen upstream (luau#1468, research §1.2). `behavior` suites use `Server`,
  since a `World` holds both sides.
- Titles are unique per suite. There are no hooks: a body builds what it needs, so its setup is in view.
- A pair takes its halves as two named functions (the style allows one function literal per call). They
  meet through `Link`: `barrier(name)`, `post(topic, value)`, `await(topic)`, each with a real timeout
  (10 s) that reports `TimedOut`, apart from `Failed`.

### 5.3 Isolation and time

- The run order is shuffled with the run seed, so state leaking between tests fails reproducibly (goals
  already require `src` state scoped to an instance or reset).
- No test calls `os.clock`, `task.wait` or `math.random`; `Timeline` and `RandomSource` replace them. Only
  `live/` waits in real time.
- A watchdog marks a body `TimedOut` after 5 s (30 s for live). The Conductor yields after each test and
  every 8 ms inside a property run, so Studio's script timeout never fires.

### 5.4 Verdicts

`Passed`, `Failed` (an assertion), `Crashed` (any other error, with its traceback), `TimedOut`, `Skipped`.
A failed assertion throws a string and is recorded in its `Check`; the runner reads the `Check` afterwards,
which tells a failure from a crash without a thrown table.

### 5.5 Taps

Every body runs under two taps from `Recorder`.
- **Output.** `LogService.MessageOut` is watched. Lync output the test did not declare
  (`check:expectOutput`) fails it, which enforces failures principle 4 (silent in normal operation)
  everywhere. It starts once the marker's form is fixed (failures §10, question 4).
- **Faults.** `ScriptContext.Error` is watched. An uncaught error the test did not claim fails it; a test
  that deliberately breaks a listener claims the error with `world:expectFault(pattern)`.

### 5.6 Assertions

| Method | Checks |
|---|---|
| `holds(condition, message)` | a boolean; the message is in the requirement mold |
| `equals(actual, expected)` | structurally: NaN equals NaN, `-0` differs from `0`, buffers byte by byte, datatypes by component |
| `approximates(actual, expected, tolerance)` | a number within a tolerance |
| `throws(action, expectation)` | the position names the test's own file (failures §4.1), and the text names the subject and path the user wrote, not the prose |
| `includesEvent(recorder, expected)`, `excludesEvent(...)` | an observer event by `kind` and the fields given, as exact singletons (failures §6), never by message text |
| `matchesGolden(name, value)` | against `test/golden/`; a mismatch prints the first differing index with a hex window and records an update candidate |

Wording is proved once, in the suite for the message table (failures §5), so a rewording changes one test.
Failure text keeps 200 characters and the first difference (v4 cut at 48).

## 6. The property engine

- **`RandomSource`.** xoshiro128** seeded through SplitMix32 on `bit32` alone, so one seed gives one
  sequence on every host (v4's choice). It records the words drawn, the tape; built from a tape, it replays
  them and hands out zeros past the end.
- **`Generators`.** A generator is a function from a `RandomSource` to a value. Combinators: integer
  ranges, booleans, choice, frequency, arrays, records, `map`, dependent draws. A filter retries a bounded
  number of times, then fails the case loudly; recursion depth is drawn from the tape. Lync-specific
  generators (codec trees, values in and out of domain, corrupted frames, fates) are test content in
  `test/generators/`; `Workloads` carries what the bench shares.
- **`Properties`.** Each case is seeded from the run seed, the test id and the case number, so one case
  replays alone. Cases per property: 300 at `standard`, 0.1 times that at `quick`, 20 times at `deep`. The
  default run seed is a committed constant (`0x4C796E63`, v4's); `seed=fresh` explores.
- **Shrinking.** `Tapes` keeps v4's algorithm: shortlex order, which is well founded; passes that delete
  runs (halving widths), zero runs, and bisect each word toward zero; repeated to a fixed point or 1000
  calls (10,000 at `deep`). Every shorter tape is valid, since a generator reads zeros past its end, so a
  minimized case keeps its invariants.
- **Changed from v4.** The message and traceback come from the shrunk case (v4 printed the unshrunk one). A
  failure prints the seed, case, shrunk tape as a Luau literal and a replay line, `filter=<id> tape={...}`.
- **Stateful tests** are properties over a generated command list (sends, joins, leaves, fates, time
  advances) that runs the real system and a model from `test/models/`. One shrinker covers it. v4 had two
  models of set replication; v5 has one per replicated primitive.

## 7. The simulated engine

**What `src` must offer (open for the spec).** Goals self-review 10 allows only seams with product value:
transport and clock as constructor parameters with defaults. The rig also needs the roster, and manual
flushing (v5-api §7). The spec should list all three as parameters. With no scheduler seam, tests drive
time through the clock, and `task.spawn` dispatch runs a listener at once until its first yield.

**`Timeline`.** Virtual `now()`, `delay(seconds, callback, ...)` mirroring `task.delay`, and
`advance(duration)`, which fires what falls due in (time, insertion) order. No real time.

**`Network`.** A reliable and an unreliable lane per direction. Every frame has a **fate**: the delays, in
seconds from the send, at which copies are delivered.

`{}` is lost, `{0}` delivered at once, `{0, 0.05}` duplicated, `{0.2}` delayed; a later frame given a
smaller delay overtakes an earlier one, which is reordering.

- One model covers all four faults, and the shrinker minimizes a fate toward `{0}`.
- The unreliable lane obeys fates. The reliable lane takes only the delays, delivers in send order and
  never loses, as its contract says.
- An unreliable frame over 1000 raw bytes is dropped and counted, as the engine drops it. The real rule
  applies after compression, so raw length is the conservative reading.
- Fates come from a **plan**: an explicit list per lane and frame index, for exact regressions ("the third
  frame is lost"), or `Generators.fate` drawn from a tape, so the shrinker minimizes the schedule.
- Tallies (calls, payload bytes, lost, duplicated, reordered, delayed) feed accounting tests and benches.
- v4's `Faithful` (order, the cap, reordering) is `Network`'s default, not a second double. The perfect
  plan is `{0}` for every frame.

**`Roster`.** Stand-in players with names and ids; `join` and `leave` fire its events. How `src` recognizes
a player (v4 used Folder stand-ins) is open for the spec.

**`World`.** `World.new({ seed, plan })` builds the three. `world:server()` and `world:client(player)`
return the parameter record for one endpoint; `world:advance(duration)` moves time and delivers what falls
due. Both views run in the server DataModel, which is how client code gets covered (§8).

**Real remotes** appear only in `test/live`, under Studio's `NetworkSettings` delay, jitter and loss (loss
caps at 0.5%, research §1.1), to check that the engine agrees with `Network`: the seam v4 never ran.

## 8. Coverage and the gate

**Collection.** The harness cannot call `EnableCoverage`, which needs plugin security. A driver does: the
Studio MCP, or a human at the command bar in the server context (U).

1. The driver sets the attribute `Driven` on `ReplicatedStorage.Lync` in the Edit DataModel, then starts
   play.
2. `Boot.server` sees `Driven` and requires nothing until the driver answers, 30 s at most. Coverage
   counts only after it is enabled, so nothing may run first.
3. In the server DataModel the driver calls `Hits.enable(options)`, which enables coverage on every
   ModuleScript under `src` and `harness`, then releases `Boot`.
4. After the run, the driver calls `Hits.read()`: per script, its line count, executable-line count and
   uncovered lines (a map of every line would be about 150 KB).

Without a driver the run still passes or fails, and its report says `coverage = Absent`; the gate cannot
pass on that.

**Mapping.** `test.json5` uses `retain_lines`, so line 40 of `ReplicatedStorage.Lync.src.wire.Varint` is
line 40 of `src/wire/Varint.luau`. The gate refuses a module whose line count differs from its file's,
which catches a build rule that moved lines.

**Only the server DataModel counts.** Client views run in the server DataModel on a `World`; real clients
run the `Everywhere` suites for behavior, since client coverage is untested. If `--!native` defeats coverage
(U), the test variant needs a comment-removing rule, which keeps lines under `retain_lines`.

**Gate.** `judge` fails a module while any executable line is uncovered and not excluded; `judge src/wire`
scopes it to a prefix, for the close of a module's step. Roots are `src` and `harness`, so the harness is
gated too. The test variant injects `IS_DEVELOPMENT = true`, so development-only branches are built and must
be covered.

`test/Exclusions.luau` lists `{ file, lineText, reason }`. Each entry's trimmed text must match exactly one
line of its file, so an edit that stales an exclusion is an error. A whole module can be excluded with a
reason (`Hits`, which runs before it can enable coverage). Exclusions are reviewed decisions, not a ratchet.

**Profiles.** `quick`, `standard` and `deep` scale case counts; `deep` adds fuzz seconds per `hostile/`
suite. The report records the profile, and `judge --gate` requires a full `standard` or `deep` run, which
makes goal 6's fuzzing a gate without CI.

## 9. Getting results to the terminal

One **report** per run: a header (kind, `buildId`, `VERSION`, seed, profile, filter, Studio version,
DataModels, native state); an outcome per work item per DataModel (verdict, duration, claims, failure with
the test's own frames, shrunk tape); golden candidates; coverage; for benches, the raw samples.

| Channel | How | When |
|---|---|---|
| Output | `Printouts` text, then the report as lines `[LyncReport] i/n <JSON chunk>` (at most 4000 characters, checksummed); a reader tolerates repeated or reordered lines | always |
| HTTP | `POST http://127.0.0.1:<port>/report`, after `GET /ping` and `GET /options` at start | `HttpService.HttpEnabled` is true and the receiver answers (U) |
| Driver read | `Deliveries.take()` returns the last report as a string to `execute_luau` | driven runs |

**The Studio MCP and Rojo.** The MCP serves driven runs: it arms coverage, starts play and reads the report.
A Lute script is not an MCP client, so the terminal path is HTTP. Rojo's sync runs one way, source to Studio,
so it carries no results.

**The receiver** is a Lute `net.server` thread inside `dev test` and `dev bench`, beside the darklua
watchers and Rojo, so a Studio run's verdict prints where `dev` runs.
- It serves the options (filter, seed, profile, clients, golden update) that the `dev` words set. Without
  it the harness takes `Hits.enable`'s options, then defaults.
- On a report it prints the text, runs the judgments (claims, coverage, benchmark comparison) and writes
  `build/reports/<kind>-<time>.json`. Exit code 0 is a pass, 1 a failure, 2 an incomplete run.
- `--update-golden` writes golden candidates into `test/golden/`, for review as a diff.
- `judge --from-log` and `judge --text <file>` read Output lines from the newest Studio log or a pasted
  block, so Output works alone, a live server's log included.

**New `scripts/` work:** `claims`, `judge`, the receiver. Both project files need
`HttpService.HttpEnabled` (U that Rojo applies it). The port lives in `Endpoints`, clear of Rojo's 34872
and the bench's 34873.

## 10. The benchmark harness

### 10.1 Row kinds

- `Micro`: one operation through the public surface or a seam parameter, in nanoseconds.
- `Scenario`: a virtual-time run on a `World` (for example 100 players): bytes per player per second, and
  CPU per virtual second, server and clients combined.
- `Weigh`: bytes alone, deterministic, one pass.
- `Anchor`: a reference row that is not Lync (§10.5).

Rows run in the server and in each client DataModel; a client's numbers are the interpreter's, since native
code on live clients is unconfirmed (research §1.2). Baselines are keyed by DataModel.

### 10.2 Sampling, `Sampler`

1. **Batch size.** Measure the smallest nonzero `os.clock` step over 10,000 calls; a batch lasts at least
   max(10 ms, 1000 steps). Probe, then scale. Setup runs outside the timer, and each call's answer goes to
   a sink, so no call is dead code.
2. **Warm-up.** At least 3 batches, until two consecutive batch medians agree within 5%, at most 30. This
   absorbs native compilation and cache warming.
3. **Samples.** 30 batches, at least 9 for a comparison, which interleaves the two sides in random order.
   A relative interval over 5% extends sampling to a time cap and marks the row `noisy`.
4. **Allocation.** `collectgarbage("count")` around each batch; a negative delta means a collection ran, so
   the sample is dropped. The figure is a lower bound, since a collection cannot be forced (research §3.3).

These are defaults to tune in step 7. Studio sends raw samples and Lute computes the verdicts, so the
arithmetic is one tested module on both ends.

### 10.3 Statistics and comparison

- **Per row:** median, MAD, a 95% bootstrap interval of the median (2000 resamples, seeded from
  `RandomSource`), and Tukey outliers at 1.5 and 3 IQR, flagged and kept.
- **Against a baseline:** the ratio of medians with its bootstrap interval, and a Mann-Whitney test (normal
  approximation with tie correction, 9 or more samples each). A row is `slower` or `faster` only when
  p < 0.05 and the change exceeds max(3%, twice the baseline's interval half-width); otherwise `same`.
- **Gating.** A row tagged `gate` fails on `slower`. Payload and estimated bytes are exact and fail on any
  increase, unless the baseline is updated on purpose.
- **Baselines** are `bench/baselines/<host label>/<key>.json`. The key is Studio version, DataModel, native
  state and fingerprint class. The label comes from the `dev` words (`host=ryzen-7900x`), since a place
  cannot read hardware. A comparison across keys is refused, with the reason.

### 10.4 Bytes on the wire

| Column | Source | Use |
|---|---|---|
| `payload` | exact buffer length at the transport seam, and call count | gated, deterministic |
| `estimate` | `EncodingService:CompressBuffer` with zstd over each frame, plus per-call overhead (about 9 B server to client, 14 B client to server: community figures) | gated; `EncodingService` at script security is (U) |
| `wire` | measured on a real remote | calibration only |

Roblox compresses buffers transparently, zstd per staff (research §1.1), so compressed size is what
matters. `Gauge` measures `wire` two ways:
- **Per frame.** Fire the frame plus a random tail over the unreliable cap, read "Payload went over by: N
  bytes" from `LogService.MessageOut`, and subtract a tail-only measurement. That the message gives the
  exact call size is verified; that the subtraction is accurate on structured data is (U), measured first.
- **Per scenario.** Replay the scenario's frames over one real remote for 20 s and average
  `Stats.DataSendKbps`, which is aggregate and coarse: a check on the estimate, never a gate.

`Gauge` also picks the zstd level `estimate` uses, and answers the research's open byte questions.

### 10.5 The optimization-level caveat

Studio may run scripts at a lower level than a live server. Level 2 adds inlining, unrolling and
library-call folding (skill, performance). The release build carries no hot comments (`dense` drops them),
so shipped `src` runs at the host's default level, which may differ between Studio and live. The design
assumes neither that the gap is zero nor its size.
1. **Fingerprint.** `Fingerprints` runs `Anchor` rows on every bench run: a small function called through a
   local (inlined at level 2) against the same call through a table field (never inlined), and an
   arithmetic loop in a `--!native` module against the same loop interpreted. The two ratios go in the
   report header and the baseline key; bucket edges come from the first measurements, then freeze.
2. **Relative first.** Gates compare equal fingerprints only; rows also print as multiples of anchors.
3. **Absolute claims need a live run.** Goal 1's CPU budget, and any choice between designs that differ in
   inlining (closure composition against tables, say), is confirmed once on a live private server: the
   bench `Boot` runs there, the report goes out through Output, and the user pastes it into
   `judge --text`. If the fingerprints match Studio's, Studio's numbers stand; if not, they are marked
   `studio-grade`: good for regressions, not for budgets.
4. **Bytes depend on none of this**, which is why they are the primary gate.

## 11. Order of build

Each step is done when the harness claims (§12) of what it builds are `Proved`, and none needs `src`.

| Step | Build | Done when |
|---|---|---|
| 0 | One Studio session of probes: a `RunContext` script runs from ReplicatedStorage on server and client; an HTTP POST from the play-test server reaches a Lute `net.server` on 1.0.0, `HttpEnabled` set by the project file; Output chunks read back through `get_console_output` and the Studio log; `EnableCoverage` after the `Driven` handshake, then in a client and under `--!native`; `os.clock` granularity; `EncodingService` at script security; fingerprint ratios on server and client | every (U) is confirmed or its fallback chosen |
| 1 | `RandomSource`, `Tapes`, `Generators`, `Properties`; `Check`, `Suite`, `Agent`, `Reports`, `Printouts`, Output delivery; both `Boot` scripts, server only | `dev test` and Play show results in Output; self-tests in `test/harness/` pass |
| 2 | `Deliveries`, `Endpoints`, the receiver in `dev`, exit codes, golden update | the same run prints in the terminal |
| 3 | The `claims` command and the type-test runner | the claims of steps 1 to 3 show `Proved` in its output |
| 4 | `Hits`, the driver flow, `judge`, `Exclusions` | the harness passes its own gate |
| 5 | `Timeline`, `Network`, `Roster`, `World` | determinism and fate tests pass |
| 6 | `Conductor` across DataModels, `Link`, `Recorder`; one live test on a dummy echo remote | a pair passes with one client and with several |
| 7 | `Statistics`, `Sampler` on a `Timeline` clock, `Comparisons`, `Benchmark`, `Fingerprints`, anchors, baselines; a calibration row that doubles a known loop and expects a ratio of 2 | a recorded baseline compares `same` against itself |
| 8 | `Gauge` and the byte calibration | the error of `estimate` against `wire` is known |

Then `src`, bottom layer first (goals, order of work 3): per module, claims into tests, then code, then
`judge <module>`; then models, `hostile/` fuzz and `live/` tests (order step 4), and baselines (step 5).

## 12. The harness's own claims

| Id | Claim |
|---|---|
| H-1 | One seed gives one draw sequence, by integer arithmetic only; a tape replays its draws, with zeros after its end |
| H-2 | The shrinker returns a failing tape no longer than its input, the known minimum on the probe properties, within its budget |
| H-3 | A property failure reports the seed, case, shrunk tape and the shrunk case's message |
| H-4 | `equals` follows §5.6 |
| H-5 | An assertion failure and any other error are different verdicts |
| H-6 | An uncaught error the test did not claim fails it |
| H-7 | A fate behaves as §7 says; the reliable lane neither loses nor reorders |
| H-8 | One seed and plan give one delivery trace |
| H-9 | `Timeline` fires due callbacks in (time, insertion) order and skips none |
| H-10 | `Statistics` returns the known values on fixed inputs |
| H-11 | `Sampler` sizes batches and ends warm-up as specified, on a virtual clock |
| H-12 | `Comparisons` says `same` for equal samples, `slower` for a clear shift, and never gates on noise |
| H-13 | A chunked report reassembles from repeated or reordered lines |
| H-14 | `claims` finds an uncited claim, an unknown tag and an unmarked type error |
| H-15 | The coverage gate refuses a line-count mismatch and a stale exclusion |

## 13. Needs from the user or Studio

**Studio** (step 0): every (U) above.

**The user:**
1. Approve `HttpService.HttpEnabled` in both project files, or choose the log-reading path alone.
2. Settle with the spec: the three `src` seams as constructor parameters; how `src` recognizes a stand-in
   player; the message marker's form; where the spec files live; the claim grammar.
3. Decide on baselines: the build copies `bench/baselines` into the place (JSON becomes ModuleScripts), so
   either the build skips that folder or the copy is accepted.
4. Let `check` skip `test/types`, whose deliberate errors would otherwise fail it.
5. Run the live private-server confirmation once (§10.5); it can also give the pending float-determinism
   result on a live server.
6. Say whether a small Studio plugin is acceptable for coverage without the MCP.
