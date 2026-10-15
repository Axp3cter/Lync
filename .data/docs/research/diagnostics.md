# Lync v5 diagnostics: research

2026-10-15. Covers errors, warnings, logging, reporting and codes for the runtime, compiler, Studio plugin and
roblox-ts. It is grounded in v4 (`.data/versions/one`), the failed attempt (`.data/versions/two`), draft 2
(`design/v5.md`, read as context), and the reference projects in `.data/projects/`.

**Labels.** **[verified]**: I ran it or read the source. **[documented]**: official docs say so. **[reported]**: a
third party says so. **[unverified]**: inference or unknown.

**Toolchain.** Luau 0.740 CLI from the luau skill; Roblox API dump 0.741.19; Intel Xeon 2.1 GHz. Probes, outputs
and a README are in `.data/docs/probes/diagnostics/`. CLI timings are relative evidence only: Roblox builds differ.

---

## 1. Luau and Roblox error mechanics

### 1.1 `error` levels and positions [verified, `probes/diagnostics/levels.luau`, `levels.O1.out`, `levels.O2.out`]

Output from a user chunk (`=UserScript`) calling library functions:

| Case | -O1 (Studio default) | -O2 (live default) |
|---|---|---|
| public `function Lib.direct` raises `error(msg, 2)` | `UserScript:7:` correct | `UserScript:7:` correct |
| public fn calls private `local function check` that raises `error(msg, 2)` | `./levels.luau:16:`, **inside the library** | `UserScript:8:`, correct only because `check` was inlined |
| `debug.info` walk to the first frame whose source is not the library's | `UserScript:9:` | `UserScript:9:` |
| `pcall(Lib.direct, 2)`: the level-2 frame is `pcall` (C) | **no position** | **no position** |
| `pcall(Lib.walked, 2)`: walk skips C frames (`line <= 0`) | `UserScript:16:` | `UserScript:16:` |
| `error(msg, 0)` (v4's `Log.refuse`/`Log.error`) | no position | no position |

- **The same code points at different lines in Studio and live.** Roblox compiles at level 1 in Studio testing and
  level 2 in live games [documented, [Luau comments](https://create.roblox.com/docs/luau/comments), 2026-10-15].
  A level that is right in a Studio test can be wrong on a live server, and the reverse.
- **The `debug.info` walk is the only method that holds at every level, natively too** (`levels.native.out`).
  Inlining never crosses a module boundary (Luau inlines only local functions within a module [documented in the
  skill's `performance.md`]). So "first frame whose source is outside Lync" survives any inlining inside Lync.
- **Which frames to skip.** Lync's package root is the prefix of every Lync module's `debug.info(1, "s")`. Each
  generated shard registers its own source when it loads (one `debug.info` call). C frames have `line == -1`
  [verified, client-security §2.2 and the probe].
- **A multi-line call reports its first line.** `debug.info(2, "l")` inside a constructor reports the line where the
  call starts (`Lync.event({` at line 7, `t.int(` at line 10, at -O0, -O1 and -O2) [verified, `callline.out`].
  Recording that line in each schema constructor gives a definition-precise source position for free (§6.2).
- **Inlining also drops function names from tracebacks.** At -O2 a dead coroutine's traceback lost the inlined
  `function deep` frame name but kept the line (`levels.O1.out` and `levels.O2.out`, last line) [verified]. Native
  tracebacks of user code keep their lines; frame names inside inlined helpers are not reliable.

### 1.2 Error values that are tables [verified unless marked]

- `error(tbl)` gets no position. `pcall` returns the table itself; `tostring` gives `table: 0x…` unless it has a
  `__tostring` (`levels.O2.out`).
- **`xpcall(f, debug.traceback)` breaks on any table error, even one with `__tostring`.** The result is
  `false, "error in error handling"`, because `debug.traceback` requires a string (`tableerr.out`). Game code uses
  this idiom widely, so a Lync API that throws tables would break its users' error handlers.
- `LogService:Error(template, context)` always throws a table with `message`, `template`, `context` and `stack`
  fields and a `__tostring` [documented,
  [LogService.yaml](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/LogService.yaml),
  fetched 2026-10-15]. That object hits the same `xpcall(f, debug.traceback)` failure.
- How Roblox's Output, `ScriptContext.Error` and the Error Report show an *uncaught* table error is
  **[unverified]**: neither docs nor DevForum searches answered it.
- **Conclusion.** Everything Lync throws is a string. Anything a caller should branch on is a return value (§4).

### 1.3 Cost of the stack walk [verified, `bench.O2.out`, `bench.native.out`]

| Operation | -O2 interpreted | -O2 native |
|---|---|---|
| `debug.info(2, "sl")`, one read | 49 ns | 54 ns |
| walk to the first non-Lync frame, Lync depth 1 / 2 / 3 / 4 / 5 | 133 / 211 / 286 / 404 / 492 ns | 191 / 290 / 418 / 523 / 619 ns |
| `debug.traceback()` | 126 ns | 99 ns |

The walk runs only when a raise is already certain, so it costs nothing on the success path. That is about 100 ns
per frame, next to the 2–3 µs of the raise itself (§9).

### 1.4 `xpcall`, threads and native tracebacks

- **`coroutine.resume` swallows errors** (it returns `false, err`) [verified, probe]. On Roblox, an error in a thread
  started by `task.spawn`/`task.defer` is reported by the engine with that thread's traceback and fires
  `ScriptContext.Error` [reported; this is common knowledge, and Roblox's docs do not state it; the attempt's
  harness relied on it, `versions/two/harness/Recorder.luau`].
- **A pooled thread dies when its call throws**, so the pool must not get it back. v4's pool already handles this:
  a raise never reaches the line that returns the thread to the pool (`versions/one/src/kernel/Threads.luau`).
- **v4 caught callback faults with `xpcall` and printed them with `warn`** (`kernel/Log.luau`: `Log.call` →
  `reportRaise` → `onLog` → `Lync.console` → `warn("[lync] file:line …")`). User bugs therefore appeared yellow,
  with the traceback flattened into the message text and no `ScriptContext.Error` event [verified by reading].
  Running callbacks under `task.spawn` without `xpcall`, as draft 2 §3.8 says, gives a red error with a native,
  clickable stack.
- **Detecting a throwing `handle`** without `xpcall`, exactly and cheaply (the attempt's F-16): the wrapper marks
  the slot answered when the handler returns; a thread `dead` after `task.spawn` with its slot unanswered has thrown;
  a `suspended` one (async handler) joins an in-flight list checked with `coroutine.status` once per flush (at most
  16 slots per connection, draft 2 §5.6). The engine reports the error natively; the asker gets `unanswered` by the
  next flush.

### 1.5 Where output goes: Studio, live server, client [documented unless marked]

| Surface | Studio | Live server | Live client |
|---|---|---|---|
| `print`/`warn`/uncaught error | Output window | Developer Console, Server tab: "Only the game owner or group members with editing permission can view server output" ([Developer Console](https://create.roblox.com/docs/studio/developer-console)) | the player's own F9 Client tab, so **any player, cheaters included, reads client output** (same page) |
| Error Report (Creator Hub) | — | "Luau system errors and warnings for both server and client" ([Error Report](https://create.roblox.com/docs/production/analytics/error-report)) | same |
| `ScriptContext.Error(message, stackTrace, script)` | per peer | per peer | per peer [API dump 0.741.19] |
| `LogService.MessageOut(message, messageType, context)` | per peer | per peer | per peer [API dump]; the class "might have unexpected or unreliable behavior and content might be truncated" ([LogService.yaml](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/LogService.yaml)) |

**The Error Report shapes Lync's output design.**
- Rows are grouped by **exact message**: "Player 12345 failed to load and Player 67890 failed to load count as two
  separate entries".
- It keeps "up to 500 unique errors and 500 unique warnings … These counts reset every 6 hours".
- Its custom rules allow regex Ignore/Group, at most 100 per experience
  ([Error Report](https://create.roblox.com/docs/production/analytics/error-report), fetched 2026-10-15).
- Consequence: **any printed line whose text varies with a value an attacker controls lets the attacker fill the
  500-row cap, so the developer's real warnings are dropped until the 6-hour reset.** Lync's printed lines must have constant text per code, with values
  outside the text (§5.6, §8).
- Staff also report that unique warnings past the cap are dropped and still counted in the chart
  ([thread](https://devforum.roblox.com/t/analytics-error-report-showing-the-wrong-number-of-total-warnings/3828793))
  [reported].

**Unknowns [unverified].** Output line-length truncation (reported to exist, no limit named:
[thread](https://devforum.roblox.com/t/stop-truncating-strings-in-output/2880217)), `print`/`warn` rate limits and
their server CPU cost. No primary source gives either; the attempt's 3,900-character chunking (H-59..H-69) rested on
an unmeasured limit.
Lync should depend on none of these: one line, at most 200 bytes, at most 2 lines per code per window (§5.6).

### 1.6 Roblox structured logging, as of 2026-10-15

- **The API.** `LogService:Output/Info/Warn/Error(message, context?)` and `LogService:Log(messageType, message,
  context?)` exist in API dump 0.741.19, as does `LogService.MessageOut(message, messageType, context)` [verified,
  `api`].
  - Messages use `{key}` placeholders. `{{` and `}}` are literal braces.
  - `MessageOut` delivers the rendered text plus `context` [documented, LogService.yaml].
- **Release.** Full release was 2026-06-04
  ([announcement](https://devforum.roblox.com/t/full-release-debug-faster-with-new-structured-logging-methods/4668415)).
  - Context is viewable in F9 and in Studio.
  - "Creator Analytics will aggregate your error reports based on the message template".
  - Cloud features "cap context tables at 1KB"; Creator Hub server logs are "soon" [documented in the
    announcement].
- **Reported defects:** an `Instance` in the context raises "Unsupported serialization type"
  ([thread](https://devforum.roblox.com/t/logservice-supported-types-parse-error/4686595)); LogService lines lack
  script and line and are not clickable
  ([thread](https://devforum.roblox.com/t/logservice-output-doesnt-have-correct-context-or-source-metadata-in-output-widget/4711364)).
- **`LogService:GetLogger(name) -> Logger`.** It is in the dump, and `Logger` has `Info/Warn/Error/Output/Log`,
  `MessageOut`, `FullPath` and `GetLogger` [verified, `api`]. The creator-docs LogService page has no `GetLogger`
  entry and the launch post does not mention it. The attempt found it unavailable in Studio
  (v5-attempt §7, "GetLogger … unavailable [V]"). Status: **present in the dump, undocumented, not usable as of the
  attempt's test** [unverified for today].
- **What Lync should do.** Print its summary lines with `LogService:Warn(template, context)`, where `context`
  holds only numbers and strings (a `UserId`, never a `Player`). The template is the grouping key in Creator
  Analytics. Studio must confirm two things in milestone 2 before this is relied on: whether `LogService:Warn`
  lines enter the Error Report grouped by template, and their cost.

### 1.7 Memory categories and profiler labels

- `debug.setmemorycategory/resetmemorycategory` and `debug.profilebegin/profileend` exist [documented,
  [debug library](https://create.roblox.com/docs/reference/engine/libraries/debug), signatures only]; the CLI lacks
  them, so their cost is **[unverified]**.
- A memory category set on a Lync thread must be reset before user callbacks run, or the game's allocations are
  charged to Lync (attempt F-78). MicroProfiler labels stay opt-in (draft 2) until their idle cost is measured.

---

## 2. Error codes: what real systems do

| System | Shape and namespace | Stability and deprecation | Doc per code | Machine reading |
|---|---|---|---|---|
| rustc | `E` + 4 digits, one flat space, allocated sequentially in `rustc_error_codes/src/lib.rs` ([dev guide](https://rustc-dev-guide.rust-lang.org/diagnostics/error-codes.html)) | never reused; a retired code keeps its page with `#### Note: this error code is no longer emitted by the compiler`; deleting an explanation fails CI ([tidy](https://raw.githubusercontent.com/rust-lang/rust/master/src/tools/tidy/src/error_codes.rs)) | yes, Markdown with a `compile_fail` doctest; `rustc --explain E0308` | `--error-format=json` ([rustc JSON](https://doc.rust-lang.org/rustc/json.html)) |
| TypeScript | `TS` + number, banded by thousands: 2130 messages in 6.0.2 (1xxx 465, 2xxx 539, 6xxx 490, …) [verified, `ts_codes.out`] | informal; the key embeds the number (`…_2345`) | **none official** | LSP `code` |
| ESLint / selene | rule names (`no-unused-vars`, `plugin/rule`; selene `unused_variable`) | `meta.deprecated` with `replacedBy` ([ESLint](https://eslint.org/docs/latest/extend/custom-rules)) | `meta.docs.url`; selene has one page per lint [reported] | `--format json`; config by name |
| Luau lints | name plus number (`LocalUnused` = 7; 29 lints, `LinterConfig.h`); `--!nolint Name` | the enum is append-only; superseded lints stay (`UnknownGlobal = 1, // superseded`) [verified] | luau-lsp links `https://luau.org/lint#<name>-<n>` (`luau-lsp/src/LuauExt.cpp:462`) [verified] | `--formatter=plain\|gnu` only [verified, `CLI/src/Analyze.cpp`] |
| Luau type errors | `1000 + variant index` (`Error.cpp`: `TypeError::code`) [verified] | stable only while the variant list is append-only; nothing enforces that | one generic link, `https://luau.org/types` | LSP `code` |
| roblox-ts | id = **module-load order** (`result.id = id++`); `code` is the literal `" roblox-ts"` (`createDiagnosticWithLocation.ts`) [verified] | ids unstable by construction; names (`noAny`) are what tests use | none | tests name the diagnostic by file name (`tests/src/diagnostics/<name>.N.ts`) and assert every emitted id equals it [verified, `compile.test.ts`] |
| Node.js | `ERR_*` names, one flat space | "`error.code` is the most stable way to identify an error. It will only change between major versions"; messages "may change between any versions"; deprecated codes stay with `Stability: 0` ([errors](https://nodejs.org/docs/latest/api/errors.html)) | an anchor per code | `err.code` |
| Postgres SQLSTATE | 5 characters: a 2-character class plus a 3-character subclass, from the SQL standard | standard-fixed | appendix table ([errcodes](https://www.postgresql.org/docs/current/errcodes-appendix.html)) | on the wire |
| gRPC | 17 numeric codes; seven are "never generated by the library, only by user code" ([status codes](https://grpc.io/docs/guides/status-codes/)) | fixed set | one page | numeric |
| RFC 9457 | `type` URI, `title`, `status`, `detail`, `instance`, plus extension members that clients "MUST ignore" if unknown; avoid exposing "a stack dump" ([RFC 9457](https://www.rfc-editor.org/rfc/rfc9457.html), July 2023) | the type URI is the identity | the URI should resolve to docs | JSON |
| .NET analyzers | prefix per package (`CA`, `IDE`, `SYSLIB0xxx`, `EXTOBS0xxx`); `ObsoleteAttribute.DiagnosticId` + `UrlFormat` ([obsoletions](https://learn.microsoft.com/en-us/dotnet/fundamentals/syslib-diagnostics/obsoletions-overview)) | `AnalyzerReleases.Shipped.md`/`Unshipped.md` tables (Rule ID, Category, Severity, Notes; New/Removed/Changed), enforced by analyzers ([help](https://github.com/dotnet/roslyn-analyzers/blob/main/src/Microsoft.CodeAnalysis.Analyzers/ReleaseTrackingAnalyzers.Help.md)) | a help link per ID | SARIF |

**What works, and why:**
1. **The code is the contract and the prose is not** (Node states it outright; ESLint's `messageId`). Every system
   that kept codes stable separated them from wording.
2. **One page per code, and CI that enforces it.** Only rustc and .NET enforce it mechanically. rustc requires a doc
   for every code, an error if a code is defined and never emitted, an error if one is emitted and never defined,
   and an error if a doc is deleted. TypeScript has no per-code docs, and users fall back on search engines.
3. **Position-derived numbers decay.** roblox-ts ids depend on load order, and Luau type codes depend on variant
   order. Neither is safe to document. A code must be written down, not computed.
4. **Names beat numbers below a few hundred codes.** ESLint, selene, Luau lints, Node and gRPC use names, and people
   read them. rustc and TypeScript have 500–2000 codes, and numbers are the price of that count. Lync will have
   about 80–120 codes.
5. **One identifier per fact.** Luau lints carry a name and a number, and luau-lsp needs both to build one URL.
   That is a second identifier with no second user.

**Recommended scheme for Lync:**

- **One identifier: a lowerCamelCase name, unique across Lync** (`valueRefused`, `overLimit`, `unknownOption`). It
  is the observer `reason`, the result `error`, the LSP/plugin/JSON `code` and the docs slug at once. Draft 2's
  reasons are already camelCase. No numeric alias, no prefix in the name.
- **Families are a registry field, not part of the name.** They are: `declaration`, `caller`, `fact`, `outcome`,
  `fault`, `build`, `internal`. A family fixes the channel (table in Implications).
- **Registry.** One Markdown file per code, `docs/codes/<code>.md`, with front matter: `family`, `since`,
  `retired?`, `evidence` (for facts) and `example` (the exact rendered output).
- **Raise sites take a typed code.** v4's `Catalog.Code` union made an unlisted code a type error (`kernel/Catalog.luau`);
  keep that. The union is generated from the registry for Luau and for `.d.ts`.
- **Stability.** Never renamed or reused; a retired code keeps its page with "no longer emitted since x.y" (rustc);
  a new code ships with its page and a test; wording may change in any release, codes and evidence fields only in a
  major one.
- **Docs.** Each code has a page at `https://lync.dev/codes/<code>` (LSP `codeDescription.href`). `lync explain
  <code>` prints the same Markdown, embedded in the CLI, so it works offline.
- **Thrown messages carry the code after the marker**, as `[Lync] valueRefused: …`. The attempt's F-58 ("no code or
  tag other than the marker") is reversed: the code is what makes a pasted error findable.

---

## 3. Message design

### 3.1 Sources and rules

- **rustc** ([guide](https://rustc-dev-guide.rust-lang.org/diagnostics.html)):
  - Messages start lowercase, end with no punctuation, and must "make sense even in isolation".
  - "The error or warning portion should *not* suggest how to fix the problem, only the help sub-diagnostic should".
  - No "did you mean"; "illegal" is banned.
  - Suggestions declare their applicability (`MachineApplicable`, `MaybeIncorrect`, `HasPlaceholders`).
- **Elm**: sentences, the user's own code quoted, one concrete next step. **Luau's type errors**: the expected type
  and the given type, both named (`Type 'x' could not be converted into 'y'`).
- **RFC 9457 `detail`** "ought to focus on helping the client correct the problem, rather than giving debugging
  information".

**Rules for Lync** (one grammar, enforced by tests as in §10):
1. **Prefix.** `[Lync] <code>: ` after the engine's or the walk's `source:line: ` position. The bracket marker stays:
   the Recorder needs it to find Lync output, and players and developers use it to find Lync in Output.
2. **Subject.** The user's own names: `namespace.definition:method`, then the value path (`data.items[3].count`,
   `data.tags["red"]`). The argument root is `data`, `record`, `patch` or `reply`, matching draft 2's option names.
3. **Requirement.** `must` plus the requirement in schema terms, then `, got ` and the value.
4. **Fix.** Optional: `; ` and one imperative clause, given only when there is exactly one fix
   (rustc's `MachineApplicable`). Otherwise no fix: a guess is worse than none.
5. **Length.** One line, at most 200 bytes after the position. The only multi-line text is a traceback the engine
   adds.
6. **Words.** No judgement words: no "suspicious", "illegal", "invalid", "bad", "exploit", "flagged" (v4 docs:
   `print("suspicious", …)`; client-security §6.3's console "N players flagged"). Name what was observed.
7. **Thrown messages hold only the caller's own values. Printed lines hold constant text per code**, with counts and
   ids in the LogService context (§1.5).

### 3.2 Printing values safely

Values are rendered by one function, `show(value)`, and run only on the failure path (§9):

| Value | Rendered |
|---|---|
| string | double-quoted. `\n \r \t \\ \"` escaped; other bytes < 0x20 or 0x7F, and every byte of invalid UTF-8 (`utf8.len` fails), as `\xNN`; cut at 40 bytes plus `…(+N bytes)` |
| number | integers by `%d`; others by `%.17g`; `nan`, `inf`, `-inf`; `-0` as `-0` |
| boolean, nil | `true`, `false`, `nil` |
| buffer | `buffer(N bytes)`, never the contents |
| table | `table` plus `(N keys)` when counting is cheap; never recursive |
| Vector3, CFrame, Color3 | `Vector3(x, y, z)` with components by the number rule; a CFrame by its position only |
| Instance | `Instance(ClassName)`, never `GetFullName()`: names are player-controlled for characters and tools |
| other userdata | `typeof(value)` |

**Log injection.**
- **What it is.** A client-controlled string reaching the server's Output, the Error Report or analytics can forge
  lines with `\n[Lync] …`. With distinct values it also fills the 500-unique-warnings cap, so real warnings
  are dropped until the 6-hour reset. Every value it logs also becomes a per-player fingerprint.
- **What draft 2 already guards.** Evidence is numbers only, names come from the receiving side's schema, and
  `validate` returns a boolean, not a reason string (unlike v4's `drop.validate` reason and the attempt's F-29
  `detail`).
- **What remains.**
  - **A caller mistake on the server whose value came from a client.** Example: the server echoes a 300-byte chat
    string into `fire`, past `t.string(200)`. `show` escapes the value and cuts it to 40 bytes, so it stays one
    line and one row per distinct 40-byte prefix. It is the game's own bug, and it surfaces once per call.
  - **A validator's error text.** Draft 2 reports `validatorError` with a native report. The text is the
    developer's, but its rate is the client's. Hence: at most one native report per definition per window (§4).

### 3.3 Before and after, on real Lync cases

| Case | Before | After |
|---|---|---|
| v4 `Scalars.luau:37`, a declaration mistake | `int takes its bounds in order, not 10 to 1` (no position, no path: `error(msg, 0)`) | `ReplicatedStorage.Net.schema:23: [Lync] intBounds: arena.fighters.data.health: t.int(min, max) must have min <= max, got t.int(10, 1)` |
| draft 2 §3.1, an option typo | `arena.chat: unknown option "rtae"` | `ReplicatedStorage.Net.schema:7: [Lync] unknownOption: arena.chat has no option "rtae"; options are from, data, lane, limit` (a list, not a "did you mean" guess) |
| draft 2 §3.8, a caller mistake | `[Lync] arena.buy:invoke data.item must be one of "sword" \| "shield", got "axe"` | `StarterPlayer.StarterPlayerScripts.Shop:41: [Lync] valueRefused: arena.buy:invoke data.item must be one of "sword", "shield", got "axe"` |
| v4 `Boundary.luau` → `Log.drop`, a malformed frame | `[lync] Lync:1 a frame ran past the bytes it arrived with, and said <internal error text>`: a fake position, internal text, one line per drop up to 8 per player per code per 10 s | no per-drop line. Observer `malformed` with `rule = 2`. Console: `[Lync] malformed: {count} frames refused in {seconds} s from {players} players` (a template, so one Error Report row) |
| v4 `Handshake.luau:79`, mismatch on the client | `this namespace hashes 1234 and the other machine says 5678` | native error: `[Lync] schemaMismatch: namespace "arena" was refused by the server; this client's schema hash is 9f3c2a10e4b7d551; sends on "arena" are dropped`. Known causes are on the docs page, not in the line |
| v4 `Packet.luau:37`, a wrong-side call | a warning: `X:onServer is the server's call, and this is the client, so nothing is attached` | generated path: a type error. Runtime path: the view's `__index` miss throws `[Lync] wrongSide: arena.buy:handle is a server method; this is the client view`. Cost is zero on hits (a metatable miss only) |
| draft 2 §3.2, a stale shard | `[Lync] arena shard is stale: run lync build` | `ReplicatedStorage.Net.client:1: [Lync] staleShard: arena shard was built from schema hash 41aa… but the schema now hashes 9f3c…; run lync build` |

---

## 4. Failure taxonomy and channels

### 4.1 The channels, each defined once

| Channel | Mechanism | Who sees it | Bound |
|---|---|---|---|
| **throw at the declaration** | string `error`, position = the recorded constructor line (§1.1) | whoever evaluates the schema (`require`, CLI, plugin) | once per evaluation |
| **throw at the caller** | string `error`, position = the first non-Lync frame | the caller's thread; Output; Error Report | one per bad call (the game's bug) |
| **result value** | `{ ok = false, error = <code> }` | the caller | — |
| **fact** | counter (always) + observer event (coalesced, capped) + console line (≤ 2 per code per window) | game code; Output; Error Report | §5.2 caps |
| **native report** | the error is raised in its own thread: user code runs under `task.spawn`, Lync's own reports under `task.spawn(error, msg, 0)` | Output (red), `ScriptContext.Error`, Error Report | engine; Lync's own reports at most 1 per code per definition per window |
| **build diagnostic** | CLI human/JSON/GitHub output; plugin `RegisterScriptAnalysisCallback` | the developer | per build |

### 4.2 Classes and their channel (draft 2's names, with the merges proposed by the redundancy review applied)

| Class | Examples (codes) | Channel | Notes |
|---|---|---|---|
| Declaration mistakes | `unknownOption`, `missingOption`, `intBounds`, `numberStepIsInt`, `newestPlacement`, `newestWidth`, `unreliableTooLarge`, `upstreamTooLarge`, `unionKindField`, `duplicateName` | throw at the declaration line on the runtime path; the **same code** is a build diagnostic in the CLI and plugin | one planner gives one code set for three hosts |
| Caller mistakes | `valueRefused`, `unknownPatchKey`, `wrongSide`, `recordLimit` (past `maxRecords`), `unknownTarget`, `decoyKeyLive`, `canaryWrite`, `configureLocked` (a `WELCOME` option changed after the first `WELCOME`), `configureRange` | throw at the caller | v4 split these over `Log.refuse` (throw only; 43 sites) and `Log.error` (record and throw; 16 sites) [verified, `v4_counts.out`]: two channels for one class |
| Stale shard | `staleShard` | throw at the `require` (Studio); build diagnostic (`lync check`) | one code, two hosts |
| User callback faults: `connect` handlers, collection signals, observers | the game's own error | native report from the callback's thread | Lync adds nothing. v4 printed these as warnings through `onLog` (§1.4) |
| `handle` faults | the game's error, plus `unanswered` to the asker | native report + result value | detected by thread status (§1.4) |
| Validator faults | `validatorError` | native report with a captured traceback, ≤ 1 per definition per window; the message is dropped (counter `validatorErrors`); an ask is answered `rejected` | validators must run under `xpcall` to finish the frame; success cost +18–38 ns per call (§9) |
| Validator yields | `validatorYielded` | native report, ≤ 1 per definition per window | detected by a re-entrancy flag around validator calls (about 1 ns); frames are decoded into locals, so a yield delays only its own frame |
| Validator returns `false` | (no code) | counter only; an ask is answered `rejected` | the game made this decision and already knows it [redundancy review 6]; draft 2's `validateFalse` event is a second channel |
| Inbound refusals and observations | `malformed` (rules 1–11, incl. direction and lane), `overBudget`, `tagMismatch`, `frameGap`, `desync`, `replayed`, `impossibleAck`, `repeatedHello`, `unknownReply`, `earlyAnswer`, `overLimit`, `unresolved`, `unreachable`, `clientReport`, `clockRate`, `decoyReferenced`, `canaryEchoed` | fact | numbers-only evidence |
| Decoder raised unexpectedly | `decoderRaised` | fact (frame refused) + native report ≤ 1 per window (a Lync bug) | v4 folded these into `drop.bounds` with the error text in the message |
| Local send-side facts | `sendDropped` (`queue` 1 = pre-`WELCOME` hold, 2 = limit FIFO), `missedFlush`, `remotesMissing` (no remotes after 10 s; v4's client `start()` waited forever) | fact on the local peer: counter, observer, console | not throws: the call was valid when it was made, and a transient join stall must not kill game loops |
| Budget deferrals of `:newest()` rows | (no code) | counter `rowsDeferred` only | normal scheduling, not an irregularity |
| Request outcomes | `timeout`, `rejected`, `unanswered`, `left`, `shutdown` | result value | registry entries of family `outcome`, so `lync explain unanswered` works |
| Handshake mismatch | `schemaMismatch` | client: native report once per namespace, then its sends drop (counter); server: fact `schemaMismatch` with the client's hash bits as evidence | draft 2's "the client view prints one error" becomes a defined channel |
| Resource caps | observer caps → `suppressed`; request slots full → `invoke` waits (no code); hold and limit queues → `sendDropped`; `maxRecords` → `recordLimit` (caller) | as listed | |
| Internal invariants | `internal` | native report: `[Lync] internal: <invariant>; please report this with the trace` | the Rojo panic hook is the model (`rojo/src/main.rs`) |
| Build findings | `staleShard`, `rawRemote`, `solverOff`, `configInvalid`, `schemaThrew`, every declaration code | build diagnostic | §6 |
| Plugin findings | the same codes as the CLI | `RegisterScriptAnalysisCallback` diagnostics | §6.3 |
| TS-side errors | tsc's own errors (`TS2339`, `TS2345`) for API misuse; Lync's runtime throws are unchanged in compiled code | tsc; the runtime channels | §6.5 |

### 4.3 Where earlier versions used two channels for one thing, or none

- **v4.**
  - `Log.error` both recorded to `onLog` and threw, while `Log.refuse` only threw: the same class split over two
    channels.
  - Server drops were `warn` and client drops were `error` (`Boundary.luau`: `HOSTILE = "warn"`,
    `TRUSTED = "error"`). That is a severity chosen by side, which is a judgement.
  - Callback faults went to `onLog` as text and never reached the native channel.
  - Request rejection showed up as `timeout`.
- **The attempt.** A validator fault was a `CheckRaised` drop reason, a `CheckRaised` event kind, *and* a native
  report (F-18..F-21): three channels. `Recovered` and `Pressure` events duplicated console warnings and metrics.
- **Draft 2.**
  - `validateFalse` and `validatorError` are anomalies as well as `rejected` and native reports.
  - The `trap` "printed there" in Studio is an ad hoc Studio-only print.
  - `MISMATCH` "prints one error", with the channel undefined.
  - **No channel at all for:** internal invariants, a decoder that raises unexpectedly, a throwing or yielding
    observer, a yielding validator, console output, the build-diagnostic format, plugin diagnostics, and remotes
    that never appear.

---

## 5. Runtime reporting surface

### 5.1 The observer event

```luau
-- One event type: every event is a fact. Draft 2's `kind = "frame" | "anomaly"` is dropped (§5.3), which also
-- removes the clash with union payloads' `kind` [review-2 taste 1].
export type Fact<Code, Evidence> = {
	read reason: Code,           -- the registry code; discriminant
	read player: Player?,        -- the sender (server); nil for local facts on a client
	read namespace: string?,     -- receiving side's own schema names, never bytes from a client
	read definition: string?,
	read count: number,          -- occurrences this event stands for (>= 1)
	read first: number,          -- GetServerTimeNow() of the first occurrence it covers
	read last: number,           -- ... and of the last
	read evidence: Evidence,     -- frozen; numbers only; fields fixed per reason
}
export type Event =
	  Fact<"overLimit", { read perSecond: number, read burst: number }>
	| Fact<"malformed", { read lane: number, read rule: number }>
	| Fact<"suppressed", { read [string]: number }>   -- counts per suppressed reason
	| ...                                             -- generated from the registry
```

- **Freezing.** Both tables are frozen; one event is two allocations. A build plus a direct call costs 259 ns native
  and 425 ns interpreted [verified, `bench`]. Events are capped (§5.2), so this never sits on a per-message path.
- **Evidence of a coalesced event** (open in review-2 M8.8): the first occurrence is emitted at once with its own
  evidence. The event at window close carries the **last** occurrence's evidence and `count` = the occurrences since.
  Overwriting costs O(1), and both ends of the window are exact.
- **Delivery.** Each observer is called in a pooled thread (`task.spawn`) per event, so:
  - an observer that throws is reported natively and cannot break Lync's loop (draft 2 leaves this unspecified);
  - one that yields holds only its own thread;
  - each one sees events in occurrence order unless it yields.

  A pooled resume costs 88–131 ns [draft 2 §3.8 cite]. Recursion is bounded: events caused by an observer's own
  calls are subject to the same caps.

### 5.2 Coalescing, caps and memory, stated exactly

- **Keys and windows.** A key is (player, reason, definition). A window opens at the key's first occurrence and
  closes `observe.window` s later. Closed windows are swept once per flush, at a cost proportional to open keys.
- **Caps.**
  - At most `observe.perPlayerEvents` events per player per window, and `observe.serverEvents` per server.
  - Occurrences past a cap are counted **per player and reason only, not per key**. At window close, one
    `suppressed` event per player carries those counts; it is exempt from the caps.
- **Memory per player** is at most `perPlayerEvents` keys plus one counter per reason (about 25). It is independent
  of the number of definitions, and freed on leave. Draft 2 keyed counts per (player, reason, definition) even past
  the cap, which is bounded only by reasons × definitions.
- **Occurrence cost under attack.** A key lookup plus increment is 20.5 ns native and 33 ns interpreted [verified].
  At 240 frames/s from each of 100 players that is about 0.5–0.8 ms per second.

### 5.3 Counters instead of `frame` events

Draft 2's `frame` event ("bytes sent or received per definition, for the inspector") fires per frame:
60 flushes × N players × namespaces, each costing about 260–420 ns plus a thread resume, with garbage on every
frame. A counter costs 3–4 ns native (array slot or buffer `u32`) or 22–30 ns interpreted; a per-player hash
lookup plus increment costs 17 / 45 ns [verified].

**Recommended read API:** `Lync.counters(player: Player?) -> Counters`.
- It returns a fresh frozen snapshot.
- Without `player` it covers the whole server or client: per definition `messagesSent`, `messagesReceived`,
  `bytesSent`, `bytesReceived`; per reason `facts` (uncapped totals); and `rowsDeferred`, `validatorErrors`,
  `validatorRejections`, `heldBytes`.
- With `player` it gives the same totals for that player, not per definition, which keeps memory bounded.
- Cost is O(definitions) allocation per call. It is documented for polling at 1 Hz or slower in game code, and up to
  4 Hz in the Studio inspector.

**Naming.**
- Luau fields are camelCase.
- The docs map each one mechanically to OpenTelemetry (`lync.messages.sent`, unit `{message}`; `lync.bytes.sent`,
  unit `By`; attributes `lync.definition`, `lync.lane`) ([OTel metrics](https://opentelemetry.io/docs/specs/semconv/general/metrics/):
  units in UCUM, `{packet}`-style annotations, `By`) and to Prometheus (`lync_messages_sent_total`,
  `lync_sent_bytes_total`) ([naming](https://prometheus.io/docs/practices/naming/): base units, plural unit suffix,
  `_total`).
- Exporters must never use the player as a label. Prometheus: "Do not use labels to store dimensions with high
  cardinality … such as user IDs".

### 5.4 Export to the developer's backend

**Lync exports nothing itself.** Every route has quotas the game must budget across all its own uses:
- `HttpService`: 500 requests per minute per server [documented,
  [HTTP service](https://create.roblox.com/docs/cloud-services/http-service)].
- `AnalyticsService:LogCustomEvent(player, eventName, value, customFields)`: "Events can only be sent from the server
  and in published games", "up to 100 custom events", charts populate within 24 h, and custom fields have "a much
  tighter cardinality limit" on names than on fields [documented,
  [custom events](https://create.roblox.com/docs/production/analytics/custom-events)].
- MemoryStore: quota figures not re-verified here.

The docs give one recipe: an observer plus a 60 s `Lync.counters()` poll, sending one custom event name
(`lync_fact`) with the reason in a custom field, and HTTP batches. Draft 2's `telemetry` extension is a different
product (gameplay feature streams) and should not grow a diagnostics exporter.

### 5.5 What Creator Hub captures today

Thrown caller mistakes and native reports appear as Error Report errors, grouped by exact text, with stacks. Console
lines appear as warnings, aggregated by template when printed with `LogService:Warn` [documented in the
announcement; unverified for the Error Report page, §1.6]. Client lines arrive too: aggregated for the developer,
and visible in F9 to the player.

### 5.6 Default console output

- **What prints.**
  - A fact's first occurrence per (code) per window prints one line at once.
  - If more occurred, one summary line prints at window close.
  - So at most 2 lines per code per window per peer: about 25 codes means at most 50 lines per 30 s, whatever the
    number of players or attackers.
  - The key is the code alone (not player or definition), so the count of distinct definitions and players goes in
    the context.
- **Template.** `LogService:Warn("[Lync] overLimit: {count} in {seconds} s, {players} players, {definitions}
  definitions", ctx)`. `ctx` holds numbers plus a capped list of at most 8 `UserId`s and 8 definition names (names
  come from the schema, never from bytes). The text is constant per code, so it makes one Error Report row.
- **Where.**
  - On the server: every fact.
  - On a client: only local facts (`sendDropped`, `missedFlush`, `remotesMissing`), never facts about integrity
    (`clientReport` counts and refused frames). Players read their own F9, and Lync never tells a client what was
    observed (draft 2 §6.2).
- **Silencing.** One server-only boolean, `console` (§Implications knobs). Client local facts always print: they
  are the game's own bugs, bounded by the same rule.
- **Why one boolean and no verbosity levels.**
  - Every line is already bounded and constant-text.
  - A developer who wants per-code policy writes an observer, which is the one way to do policy.
  - Levels would be a second way, with no definition that is not a judgement.

---

## 6. Build and tool diagnostics

### 6.1 One structure, three renderings

The planner produces diagnostics shaped as **LSP `Diagnostic`**:
- `range` (0-based), `severity`, `code`, `codeDescription.href`, `message`, `source = "lync"`;
- `relatedInformation` (e.g. the other definition of a duplicate name);
- a `data` field holding the value path, which the plugin uses.

The CLI renders it three ways:

| `--format` | For | Shape |
|---|---|---|
| `human` (default) | terminals | `error[unknownOption]: arena.chat has no option "rtae"` / `--> src/shared/Net/schema.luau:7:2` / the source line with a caret / `= help: options are from, data, lane, limit`. It ends with `run lync explain <code>` once per distinct code. Prior art: lute lint's printer (`lute/cli/commands/lint/printer.luau`) and rustc |
| `json` | tools | **JSON Lines**, one object per line: the LSP Diagnostic plus `uri`. lute's `--json` emits an LSP `workspaceDiagnosticReport` [verified, `lute/cli/commands/lint/init.luau`]. JSON Lines streams under `watch` |
| `github` | Actions | `::error file=…,line=…,endLine=…,col=…,endColumn=…,title=lync <code>::<message>` ([workflow commands](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands)). GitHub shows at most 10 errors and 10 warnings per step and 50 per job ([Checks API](https://docs.github.com/en/enterprise-server@3.13/rest/checks/runs), [problem matchers](https://raw.githubusercontent.com/actions/toolkit/HEAD/docs/problem-matchers.md)), so the CLI also writes the human report to `$GITHUB_STEP_SUMMARY` |

- **SARIF: not yet.** Code scanning supports SARIF 2.1.0 with `shortDescription` and `help` per rule and
  `partialFingerprints` ([GitHub SARIF](https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/sarif-support-for-code-scanning)).
  It fits persistent security or quality alerts, not build errors in a schema that already fail CI. Add it when a
  user asks; it is about 100 lines over the same structure.
- **Severity in builds** is defined by effect, not judgement.
  - `error`: the build writes no outputs, and the exit code is 1.
  - `warning`: outputs are written.
  - Declaration and stale-shard codes are always errors. `lync.toml [check]` entries (`rawRemotes = "off" | "warn"
    | "error"`) set the rest, as ESLint and selene configure rules by name.
- **Exit codes**, after ESLint ([CLI](https://eslint.org/docs/latest/use/command-line-interface): 0 clean, 1 lint
  errors, 2 configuration or internal error) and tsc's `ExitStatus` (0–4, verified in TypeScript 6.0.2):

  | Code | Meaning |
  |---|---|
  | 0 | no diagnostics of severity error |
  | 1 | one or more errors (including stale shards in `check`) |
  | 2 | usage or configuration error: bad flags, unreadable or invalid `lync.toml` (`configInvalid`) |
  | 3 | internal error: a Lync bug, printed Rojo-style ("This is probably a Lync bug … please file an issue", `rojo/src/main.rs`) |

### 6.2 Source locations

- **Schema.** Every public constructor (`Lync.event`, `Lync.request`, `Lync.collection`, `t.*`) records
  `debug.info(2, "sl")`, the line where its call starts (§1.1). That is one read of about 50 ns per constructor, once.
  - Plain record tables have no call, so a field-level error uses its codec constructor's line. An option-table
    typo uses the definition's line.
  - Columns are not available from `debug.info`. The CLI and plugin locate the column by searching the line for the
    option key or codec name, or else span the whole line.
  - The CLI on Lune/mlua names chunks by file path, so positions are real paths. In the plugin, the module is
    required from a clone whose full name maps back to the original script [unverified, milestone 6].
- **Runtime path.** The same recorded positions prefix declaration throws, so `require(schema)` reports
  `schema:23:` instead of the `Lync.schema(...)` return line.
- **Shards.** Shard frames are skipped by the walk, so caller mistakes point at game code. Each definition's
  comment names its schema origin (draft 2 §8.1). `manifest.json` should record each definition's
  `schemaPath:line`, so runtime messages that name `arena.chat` can be resolved to a line by the inspector and by
  `lync explain`.

### 6.3 Studio plugin

- `ScriptEditorService:RegisterScriptAnalysisCallback(name, priority, callback)` is PluginSecurity. The callback
  receives `{ script }` and returns `{ diagnostics = { { range, code?, message, severity?, codeDescription?:
  { href } } } }` [documented, [ScriptEditorService](https://create.roblox.com/docs/reference/engine/classes/ScriptEditorService)].
  So Lync codes and docs links show natively in Studio's editor.
- The plugin evaluates the schema with the shared planner. It returns the same diagnostics as `lync check` for the
  schema script, plus `staleShard` on shards and `solverOff` (draft 2 §3.2) on scripts using the runtime path.
- Priority semantics are undocumented. Register once and deregister on unload [unverified].

### 6.4 Type-function errors

- Review-2 found that `error()` inside a type function crashes the new solver through cross-module use.
- **Rule:** type functions return a marker type whose name is the diagnostic, e.g. the string singleton
  `"[Lync] expected a codec at chat.data"`, and never call `error()` on user-derived input [review-2, `crash_fix/`].

### 6.5 roblox-ts users

- **API misuse** is a tsc error with TypeScript's own codes (`TS2339` wrong-side member, `TS2345` wrong payload).
  Lync cannot add codes there. Its job is readable type names: draft 2's milestone 1 proof of "side-split error
  readability".
- **rbxtsc's own diagnostics** print as `code " roblox-ts"`, with ids by load order (§2).
- **Runtime throws** are the same Luau strings. Positions refer to the compiled Luau in `out/`; rbxtsc emitting no
  source maps is **[unverified]**.
  - The message's `namespace.definition:method` subject is what lets a TS user find the call.
  - The shard's `.d.ts` JSDoc should name the schema line of each definition.

---

## 7. Prior art in networking libraries and engines

| Library | Bad input | Misuse | Callback faults | Source |
|---|---|---|---|---|
| Zap 0.6.x | `error("Unknown event id")` thrown inside `OnServerEvent`: a client fills the server's Error Report at will and kills the rest of the batch. Instance checks are `assert(…, "received instance is nil!")` | `error(...)` at load | n/a | `zap/src/output/luau/server.rs:582`, `irgen/des.rs:483` [verified, fetched] |
| Blink | ``error(`Unexpected enum: {Index}`)`` with a client-chosen number in the text: **every distinct value is a new Error Report row**. A nil instance drops the rest of the batch | load errors | `pcall` around function handlers, then ``warn(`"Name" encountered an error, {Error}`)``: no traceback, yellow; the asker throws `"There was an exception while processing …"` | `src/Generator/init.luau:213, 705, 751` [verified, fetched]; issue #102 asks for an error policy ([issues](https://github.com/1Axen/blink/issues)) |
| ByteNet | no checks: an unknown id indexes nil inside `OnServerEvent`, so it is an engine error at ByteNet's line; non-buffers are silently ignored | — | listeners on a reused thread via `task.spawn` (native) | `src/process/read.luau`, `server.luau` [verified, fetched] |
| Warp 1.1 | silent drops (byte budget, XOR decode); the byte budget is **disabled in Studio** (`if not RunService:IsStudio()`); serdes ``error(`(serdes) unknown type: {tag}`)`` with client-chosen tags | ``warn("[Warp.Schema]: …")`` | not isolated | `src/Server/init.luau:194-211`, `Util/Buffer/init.luau:1018` [verified, fetched] |
| Packet | users report "firing the same packet twice in a frame … drop ALL packets" and a coroutine-resume security hole | | | landscape §1.4, §1.7 [reported] |
| Red, QuickNet | not examined beyond landscape §1 | | | — |
| Unreal | `UE_LOG(Category, Verbosity, …)`; verbosities `Fatal` (crashes), `Error`, `Warning`, `Display`, `Log` (file only), `Verbose`, `VeryVerbose`; per-category runtime control (`log LogNet verbose`, `-LogCmds=`) ([docs](https://dev.epicgames.com/documentation/en-us/unreal-engine/logging-in-unreal-engine)) | | | [documented] |
| Unity NGO | one global `LogLevel` with `Developer`, `Normal`, `Error`, `Nothing` ([API](https://docs.unity3d.com/Packages/com.unity.netcode.gameobjects@2.0/api/Unity.Netcode.LogLevel.html)) | | | [documented] |
| Mirror, FishNet, Photon | not researched: searches found no primary docs within budget | | | gap |

**Copy:** native callback threads (ByteNet, draft 2); Unreal's *category*, which in Lync is the code, with
per-code policy in the observer; Zap's constant-text checks, as counted refusals rather than throws.
**Avoid:** throwing inside `OnServerEvent` (Zap, ByteNet, Blink, Warp), which lets a client raise server errors at
will and, with value-bearing text (Blink, Warp), fill the Error Report's unique-row cap; `pcall` plus `warn` for
user faults (Blink, v4), which loses the stack and the colour; Studio-versus-live differences (Warp's budget);
global verbosity levels (NGO, Unreal), whose levels are vague bundles (`Normal` is "medium verbose").

---

## 8. Security and abuse

- **Flooding Output or the Error Report.**
  - Lync never prints per message.
  - Printed lines are at most 2 per code per window per peer, with constant text, so they make one Error Report row
    per code (§5.6).
  - Lync's own native reports are capped at 1 per code per definition per window.
  - v4 allowed 8 lines per player per code per 10 s with no server-wide cap (`Protocol.DROP_BURST = 8`,
    `DROP_WINDOW = 10`, `Boundary.heeded`), so its output grew with the number of attacker accounts [verified].
- **Flooding the observer, and memory.** The caps and per-player bounds of §5.2 and §5.3 apply. Each occurrence
  costs 20–33 ns, and all per-player state is freed on `PlayerRemoving`.
- **Client strings never reach logs.**
  - Evidence is numbers only, and names come from the local schema.
  - `show()` escapes and truncates values in thrown messages.
  - Console contexts hold `UserId`s, never display names (which players choose).
  - No decoded string is ever interpolated.
- **Throwing or yielding user code.**
  - Observers and handlers are isolated by their own threads (§5.1, §1.4).
  - A validator's throw drops only its message, unlike v4 [2], where it killed the frame. A yield is detected and
    delays only its own frame (§4.2).
- **Client-side silence.** No client print mentions integrity facts, so a cheat reading F9 learns nothing
  (draft 2 §6.2).

---

## 9. Performance [verified: `bench.luau`, `bench2.luau`; medians of 7–9 runs, ns per operation]

| Operation | -O2 interpreted | -O2 native |
|---|---|---|
| loop baseline (no check) | 14.9 | 3.6 |
| range check + cold `fail(path, value)` call (message built only on failure) | 46.6 | 9.1 |
| same check as `assert(cond, "constant")` | 45.3 | 7.1 |
| same check as `assert(cond, `…{v}`)`, **eager interpolation** | **163.5** | **103.8** |
| validator called directly / inside `pcall` | 12.5 / 50.5 | 7.1 / 25.0 |
| `pcall(ok)` / `xpcall(ok, handler)`, no error | 22.6 / 25.2 | 18.2 / 28.7 |
| `pcall` catching `error(string, 0)` | 2,439–3,001 | 1,954–2,301 |
| `pcall` catching `error(string, 1)` (adds the position) | 2,560 | 3,001 |
| `pcall` catching a shared frozen table / a fresh table | 2,266 / 1,679 | 2,919 / 2,420 |
| `xpcall` catching with a traceback handler | 2,361 | 3,722 |
| `string.format` / interpolation / `..`, 3 values | 206 / 201 / 203 | 244 / 181 / 193 |
| counter `+= 1`: array slot / buffer u32 / per-player hash then slot | 22.5 / 29.8 / 45.1 | 4.3 / 3.0 / 17.2 |
| event: build frozen table + 1 listener | 425 | 259 |
| coalesced occurrence (key lookup + count) | 33.2 | 20.5 |

**Readings:**
1. **Never build a message on the success path.** An eager interpolated `assert` costs +117 ns (interpreted) or
   +95 ns (native) per checked value over a guard with a cold failure call. At 10,000 checked values per frame
   that is about 1 ms per frame. Checks are written `if not ok then fail(code, path, value) end`, and `fail` alone
   builds strings.
2. **Raising costs 2–3 µs in this build**, with no meaningful difference between strings and tables or levels 0 and 1
   (run-to-run spread is ±0.5 µs). Inbound refusals should therefore be *return values* from the decoder (a rule
   number), not throws, as draft 2's whole-frame refusal allows.
   - v4 raised a table per rejected value (`Log.reject`), so each one cost about 2 µs at a rate the attacker
     chose.
   - Keep one `pcall` per frame (+18–28 ns) for unexpected errors (`decoderRaised`).
3. **Protected validators cost +18–38 ns per call**, which is cheap insurance against v4's frame-killing [2].
   `xpcall` with a handler costs the same as `pcall` on success, so the traceback is captured only on failure.
4. **Formatting choice does not matter for cost.** Interpolation is equal or faster and reads better.
5. **Counters, not events, for anything per message or per frame**: 3–45 ns against 260–425 ns plus dispatch (§5.3).
6. **Unmeasured:** the cost of `debug.profilebegin`/`end`, `setmemorycategory` and `LogService:Warn` on Roblox,
   and the raise cost in Roblox's own build. All belong in milestone 2's Studio probes.

---

## 10. Testing diagnostics

- **v4 asserted on prose.**
  - 193 `Expect.throws` sites, 127 of them closed with a prose substring (`end, "rate above zero")`), plus 11
    `string.find(message, …)` checks [verified, `v4_counts.out`].
  - `Expect.throws` matched `string.find(message, contains, 1, true)`.
  - Any rewording broke tests, and nothing checked positions (all were `error(msg, 0)`).
- **What replaces it:**
  1. **Assert codes and positions, not prose.** `expectThrow(fn, { code = "valueRefused", at = "<this test file>:<line>",
     subject = "arena.buy:invoke", path = "data.item" })`. It parses `^(%S+:%d+): %[Lync%] (%a+): (.*)$`, and the
     subject and path appear as whole tokens (the attempt's H-40/H-41 `Check.throws`, kept).
  2. **Facts by code and evidence.** `expectFact(world, { reason = "overLimit", player = p, count = 3, evidence =
     { perSecond = 5, burst = 5 } })`. This never compares message text (attempt H-42).
  3. **Unclaimed output fails the test.** Every `[Lync]` line and every native report must be claimed by the test
     (attempt `Recorder.luau`). Headlessly, the console sink and the native-report sink are a test seam, not a
     public option.
  4. **Golden messages live in the docs.** Each `docs/codes/<code>.md` has an `example` block with the exact rendered
     output for a canonical trigger. A test runs the trigger and compares byte for byte. Prose changes are then
     reviewed as doc diffs, and docs cannot drift (rustc's `.stderr` UI tests plus its doctests).
  5. **A registry that lints itself** (rustc tidy, .NET release tracking, roblox-ts's per-diagnostic test files).
     CI fails when:
     - a code literal is used in `src/` and absent from the registry;
     - a registered code that is not retired appears in no raise site;
     - a code that is not retired has no test asserting it;
     - a code page is deleted (it must be marked retired instead);
     - the generated Luau and TS `Code`/`Event` unions differ from the registry;
     - a code changes family without a major version bump.
  6. **Message-grammar test.** Every `example` matches `^%[Lync%] %l%w*: ` (after the position), is one line, is at
     most 200 bytes, and contains none of the banned judgement words of §3.1.
  7. **Adversarial reachability.** Draft 2 §9's adversarial client asserts each fact fires on exactly its trigger and
     never for the honest client. The registry lint checks that every `fact` code is covered.

---

## 11. Critique: where v4, the attempt and draft 2 are weak here

| Where | Defect | Evidence |
|---|---|---|
| v4 | positions lost: `error(msg, 0)` at all 59 `refuse`/`error` sites | `kernel/Log.luau:138-147`; `v4_counts.out` |
| v4 | drop records carry a fake `Lync:1` position and internal error text (`said`) | `Log.drop` |
| v4 | a throwing validator or `:as` lift kills the rest of the frame | v4 brief [2]; `shape/emit/init.luau:40-51` |
| v4 | `onLog` `data` is one unfrozen table shared by every listener; listeners run via `Threads.spawn` without `xpcall`, so their errors reach the engine (the brief's [3]) while Lync's own callback faults were printed as warnings: two fault channels | `Log.said`, `Listeners.fan`, `Log.call` |
| v4 | the validator's free-text `reason` is printed, so client-derived text can reach logs | `Catalog`: `"{path} was turned away: {reason}"` |
| v4 | output scales with the number of attackers (no server-wide cap) | `Boundary.heeded` |
| v4 | the docs teach verdicts (`print("suspicious", …)`) | `docs/guide/logging.md` |
| v4 | 127 tests coupled to wording | `v4_counts.out` |
| attempt | 12 claims (H-13, H-59..H-69) for base64/CRC Output chunking built on an unmeasured line limit | `spec/harness.md` |
| attempt | six event kinds with six shapes; three channels for one validator fault; F-58 forbids codes | `spec/failures.md` F-18..F-21, F-58, F-60..F-66 |
| attempt | `Pressure`/`Backlog` events every flush under load: a hot-path event | F-42 |
| draft 2 | per-frame `frame` events, which are hot (§5.3); no field list (review-2 M8.7) | §6.3 |
| draft 2 | coalesced `evidence` undefined (review-2 M8.8); answered in §5.1 | §6.3 |
| draft 2 | no console definition, no observer dispatch semantics, no channel for internal or unexpected decoder errors, no build output format, no codes | §3.8, §6.3, §8 |
| draft 2 | `validateFalse` and `validatorError` give the game's own outcomes two channels; `trap` has an ad hoc Studio print; `MISMATCH` "prints one error" | §6.3, §4.4; redundancy-2 findings 6 and 13 |
| draft 2 | wording that still judges: evidence named `elevated`/`foreign` (review-2 M9); the word "anomaly" itself characterises | §6.2.7, §6.3 |

---

## Implications

**Codes** (§2):
- Use **one lowerCamelCase code per fact, unique across Lync**. It is at once the observer `reason`, the result
  `error`, the LSP/JSON `code` and the docs slug. Use no numbers and no aliases.
- Example codes by family (`family` is a registry field that fixes the channel):

  | Family | Example codes |
  |---|---|
  | declaration | `unknownOption`, `intBounds`, `newestWidth` |
  | caller | `valueRefused`, `unknownPatchKey`, `wrongSide`, `recordLimit` |
  | fact | `malformed`, `overLimit`, `sendDropped`, `suppressed` |
  | outcome | `timeout`, `unanswered` |
  | fault | `validatorError`, `schemaMismatch` |
  | build | `staleShard`, `rawRemote`, `configInvalid` |
  | internal | `internal` |

- **Allocation and stability.** One `docs/codes/<code>.md` per code, with `family`, `since`, `retired?`, `evidence`
  and `example`. A new code ships with its page and a test. Codes are never renamed or reused; retired pages stay.
  Codes and evidence fields change only in a major release; wording may change in any release (§2, §10).
- **`lync explain <code>`** prints the embedded page, and `https://lync.dev/codes/<code>` is the
  `codeDescription.href` for the CLI, LSP and plugin (§2, §6).

**Messages** (§3):
- Write `source:line: [Lync] <code>: <subject> must <requirement>, got <value>[; <fix>]`: one line, at most 200
  bytes, rendered by `show()`.
- Lync throws strings only. Table errors break `xpcall(f, debug.traceback)` [verified] (§1.2, §3).
- Raise at the caller through the `debug.info` walk: no `error(msg, 2)` anywhere in Lync, because Studio (-O1) and
  live (-O2) disagree on what a level points at (§1.1).
- Record `debug.info(2, "sl")` in every schema constructor and use it as the position of declaration throws and build
  diagnostics (§1.1, §6.2).

**Failure taxonomy table** (§4):

| Class | Channel |
|---|---|
| declaration mistake | throw at the declaration line; the same code as a build diagnostic |
| caller mistake (incl. `staleShard` in Studio) | throw at the caller |
| connect / signal / observer fault | native report from its own thread |
| `handle` fault | native report + `unanswered` (thread-status detection) |
| validator throw / yield | native report ≤ 1 per definition per window + counter; message dropped; ask `rejected` |
| validator `false` | counter; ask `rejected` (no event) |
| inbound refusals and observations | fact (counter + coalesced event + console) |
| decoder raised | fact `decoderRaised` + native report ≤ 1 per window |
| local send-side facts (`sendDropped`, `missedFlush`, `remotesMissing`) | fact on the local peer |
| budget deferral | counter only |
| request outcomes | result value |
| schema mismatch | client: native report once per namespace; server: fact |
| internal invariant | native report `internal` |
| build and plugin findings | build diagnostic (LSP shape) |
| TS misuse | tsc errors; runtime channels unchanged |

**Observer** (§5.1, §5.2):
- One fact shape: `{ reason, player?, namespace?, definition?, count, first, last, evidence }`, frozen, with
  numbers-only evidence. Drop the `kind` discriminant.
- A coalesced event carries the last occurrence's evidence.
- Deliver each event to each observer on a pooled thread.
- Count past caps per player and reason only, so memory per player is at most `perPlayerEvents` + about 25 numbers.

**Counters** (§5.3):
- Replace the `frame` event with `Lync.counters(player?)`: a frozen snapshot, documented for polling at 1 Hz or
  slower.
- Map field names to OTel and Prometheus in the docs. Never use the player as an exported label.

**Knobs** (server-only `Lync.configure`, §5.2, §5.6):

| Option | Type, unit | Range | Default | Cost |
|---|---|---|---|---|
| `observe.window` | number, s | 5–600 | 30 | one sweep per flush over open keys; window for events and console |
| `observe.perPlayerEvents` | integer, events per player per window | 1–64 | 16 | ≤ 16 keys + ~25 counters per player |
| `observe.serverEvents` | integer, events per window | 16–4096 | 256 | ≤ 256 × ~260–425 ns + dispatch per window |
| `console` | boolean | — | true | ≤ 2 `LogService:Warn` lines per code per window on the server; client local facts always print |
| `profile` | boolean | — | false | `debug.profilebegin`/`end` per namespace flush and decode; cost unmeasured (milestone 2) |

Fixed, not knobs: the value truncation (40 B), the line cap (200 B), the native-report rate (1 per code per
definition per window), and the evidence fields.

**Build** (§6):
- `--format human|json|github`. JSON is JSON Lines of LSP Diagnostics; `github` also writes the step summary.
- Exit codes: 0 clean, 1 errors, 2 usage or config, 3 internal.
- The plugin returns the same diagnostics through `RegisterScriptAnalysisCallback` with `code` and `href`.

**Hot path** (§9):
- Checks call a cold `fail()` and never format eagerly (+95–117 ns per value otherwise).
- Decoder refusals are return values, with one `pcall` per frame.
- Validators run in `xpcall` (+18–38 ns).

**Testing** (§10):
- Assert code, position and evidence.
- Golden output lives in each code page.
- The registry lint fails CI on an unregistered, unemitted, untested or deleted code.
- Unclaimed `[Lync]` output fails a test.

**Measure in Studio, milestone 2** (§1.5–§1.7):
- whether `LogService:Warn` lines reach the Error Report grouped by template;
- the cost of `warn`/`LogService:Warn`, `profilebegin` and `setmemorycategory`;
- how an uncaught table error renders;
- whether `GetLogger` works.

**Cut:**
- Draft 2's `frame` event and the `kind` field.
- `validateFalse` as an event.
- The Studio-only `trap` print.
- Ad hoc `MISMATCH` printing.
- v4's `onLog`, `Lync.console` connection and side-dependent warn/error.
- The attempt's six event kinds, `Recovered`/`Pressure`, `trace` printing, `metrics()` tree and Output chunking.
- Validator reason strings.
- Severities and verbosity levels at runtime.
- Per-code console switches.
- SARIF until requested.
- Any built-in exporter.
