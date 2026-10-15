# Lync v5: research

Findings beyond v4, gathered 2026-10-02. The goals they inform are in [v5-goals.md](v5-goals.md); facts
about v4 are in [v4-inventory.md](v4-inventory.md).

**How to read this.**
- Every claim names its source. Official sources are Roblox docs and staff posts, luau.org, roblox-ts
  docs, and project repos. Community measurements are marked as such.
- Web pages were read through a summarizing fetch, so quote wording before relying on it for a hard
  constraint.
- **Checked** means the experiment was run here. **(U)** means unverified.

**Contents:** 1 Roblox platform · 2 Compression · 3 Testing, benchmarks, errors · 4 roblox-ts ·
5 Competing libraries · 6 Experiments run here · 7 Measurements still needed · 8 Implications for v5

## 1. Roblox platform

### 1.1 Transport

| Topic | Finding | Source |
|---|---|---|
| Buffer compression | Buffers sent through remote events and functions get "transparent on-the-wire compression", zstd per staff. Keep buffers under 50 MB. **Checked in Studio:** 4000-byte buffers once per frame cost 2.8 KB/s on the wire when all zeros and 241.9 KB/s when random, against 240 KB/s of payload. | [Buffer beta announcement](https://devforum.roblox.com/t/introducing-luau-buffer-type-beta/2724894), staff, 2023-11-30; §6 |
| Manual compression | `EncodingService:CompressBuffer(buffer, algorithm, level)`, `DecompressBuffer`, `GetDecompressedBufferSize` | [EncodingService docs](https://create.roblox.com/docs/reference/engine/classes/EncodingService); [thread](https://devforum.roblox.com/t/a-method-to-directly-compress-a-buffer/3261716), shipped by 2025-11-07 |
| Per-call overhead | About 9 B server to client and 14 B client to server per call. A 9-byte buffer arrives as about 12 B. Merging forty 9-byte buffers into one cut about 480 B to about 360 B. | [ByteNet thread](https://devforum.roblox.com/t/bytenet-advanced-networking-library-w-buffer-serialization-strict-luau-absurd-optimization-and-rbxts-support-043/2733365?page=4), community, 2024-02 |
| Per-type cost of plain arguments | Number 9 B, string length+2, bool 2, Instance 4 to 6, Vector3 13, CFrame 13 to 21. Sources conflict. | [ffrostfall](https://ffrostfall.net/stuff/list/remoteevents/) (2022); [Packet Size Counter](https://devforum.roblox.com/t/remote-packet-size-counter-accurately-measure-the-amount-of-bytes-for-remotes/2320709) (2023-24); community |
| Unreliable payload limit | 1000 B on client and server since 2025-03-12 (900 B at launch). **Checked in Studio:** the limit applies to the compressed, serialized call. All-zero buffers arrived at every size tested, up to 8000 B. Random buffers arrived at 980 B and were dropped from 990 B up (each call also carried a short tag string). | [UnreliableRemoteEvent thread](https://devforum.roblox.com/t/introducing-unreliableremoteevents/2724155); §6 |
| Unreliable ordering | No ordering guarantee relative to anything. May be dropped under bandwidth or CPU pressure. | same thread, staff, 2023-11-29 |
| Rate limit | About 500 calls/s per client per remote type. Excess reliable calls queue in order; excess unreliable calls drop. | [UnreliableRemoteEvent docs](https://create.roblox.com/docs/reference/engine/classes/UnreliableRemoteEvent); [remote docs](https://create.roblox.com/docs/scripting/events/remote) |
| Batching by Roblox | No evidence that Roblox merges calls; each call pays its own overhead. | community (U) |
| Bandwidth budget | The official docs give no KB/s figure; the old "50 KB/s" is folklore. `NetworkPeer:SetOutgoingKBPSLimit` exists. | [performance docs](https://create.roblox.com/docs/performance-optimization/improve) |
| Measuring bytes | `Stats.DataSendKbps`, `DataReceiveKbps` (kilobytes per second, aggregate only). No per-remote or exact on-wire API. | [Stats docs](https://create.roblox.com/docs/reference/engine/classes/Stats) |
| Network simulation in Studio | `NetworkSettings`: inbound and outbound delay, jitter, and loss (loss capped at 0.5%, constant). Applies to Test, Team Test, and Server and Clients. | [announcement](https://devforum.roblox.com/t/expanding-network-simulation-in-studio/4665487), 2026-06-02 |

### 1.2 Luau on Roblox

| Item | Status | Source |
|---|---|---|
| Require by string | `./`, `../`, `@self/`, `@game/`. `.luaurc` aliases are **not** supported on Roblox; staff "working on" it. | [announcement](https://devforum.roblox.com/t/introducing-require-by-string/3405078), 2025-01-22; `@game` 2026-01-08 |
| `const` | Live (release 713, 2026-05). | [release notes 713](https://devforum.roblox.com/t/release-notes-for-713-const-keyword-release-is-still-marked-as-pending-while-it-has-been-released-already/4651671) |
| Type solver | New solver is default for nocheck and nonstrict. Strict scripts stay on the old solver unless `UseNewLuauTypeSolver` is set. The old solver is to be removed "at some point". User-defined type functions need the new solver. | [general release](https://devforum.roblox.com/t/general-release-luau%E2%80%99s-new-type-solver/4084991), 2025-11-20; staff 2026-02-04 |
| Native code generation | Server scripts. Not enabled on live clients as of the last staff statement. A 2026-09 community claim says Android has it (U). Studio benchmarks with `--!native` do not predict live client speed. | [native codegen docs](https://create.roblox.com/docs/luau/native-code-gen); [thread](https://devforum.roblox.com/t/enable-native-for-clients/3170510) |
| Native codegen bug | Three or more consecutive `buffer.writeu32` failed to compile natively. Fixed upstream; whether Roblox ships the fix is (U). | [luau#1468](https://github.com/luau-lang/luau/issues/1468) |
| Luau version on Roblox | Not stated. Upstream is 0.740 (2026-09-25). Roblox 741 notes list `if local`. | [Luau releases](https://github.com/luau-lang/luau/releases); [notes 741](https://devforum.roblox.com/t/release-notes-for-741/4906281) |
| Float determinism | Staff: float results are not guaranteed to match across hardware, and reproducible software "had to switch over to things like fixed point arithmetic". | [thread](https://devforum.roblox.com/t/server-and-client-produce-different-math-results-from-the-exact-same-equation/3563224), staff, 2025-03-31 |

### 1.3 Studio and engine features relevant to v5

| Feature | What it gives | Source |
|---|---|---|
| `StudioTestService` | Plugin-level. `ExecutePlayModeAsync`, `ExecuteRunModeAsync` (v700), `ExecuteMultiplayerTestAsync(players, args)` with up to 8 clients (v715, 2026-04), `AddPlayers`, `EndTest(value)` returning a value to the plugin. Known bugs fixed by 2026-08. | [announcement](https://devforum.roblox.com/t/introducing-studiotestservice/4116257), 2025-12-04; [API mirror](https://robloxapi.github.io/ref/class/StudioTestService.html) |
| Native coverage | `ScriptContext:EnableCoverage(instance)` (v715) and `GetCoverageStats()`, whose `GetHits()` gives per-line hit counts. Plugin or Open Cloud security only. **Checked:** it works in a play-test server DataModel, called through the Studio MCP. Hit counts are per line, -1 for non-code lines and 0 for uncovered lines. Client DataModels and `--!native` are untested. | [ScriptContext mirror](https://robloxapi.github.io/ref/class/ScriptContext.html); §6 |
| Structured logging | `LogService:Output/Info/Warn/Error/Log(message, context)` with `{key}` templates (v716; full release 2026-06-04). `MessageOut` carries the context. `GetLogger(name)` (v734). Known gaps: no script or line attribution in Output; Instances in context fail to serialize. `LogService:Error` always throws. | [announcement](https://devforum.roblox.com/t/full-release-debug-faster-with-new-structured-logging-methods/4668415); [LogService mirror](https://robloxapi.github.io/ref/class/LogService.html) |
| Built-in Studio MCP | `execute_luau` in Edit, Client or Server DataModels, `start_stop_play`, `get_console_output`, input simulation. Available to Claude in this environment. | [MCP docs](https://create.roblox.com/docs/studio/mcp), 2026-03-05 |
| Studio CLI | `--task RunScript --runScriptFile … --outputFile …`, command-bar permission. Whether it can call `StudioTestService` is (U). | [CLI docs](https://create.roblox.com/docs/studio/command-line-interface) |

## 2. Compression

### 2.1 Techniques

Gains are as cited by each source; whether they hold for Lync's traffic has to be measured (§7).

| Technique | Cited gain | Prerequisites and CPU | In Luau |
|---|---|---|---|
| One call per player per frame, one buffer | Saves the 9 to 14 B call overhead and about 3 B per extra argument | Batching (v4 already does this) | Required baseline |
| Bit packing | Gaffer: orientation 128 to 29 bits, position 96 to 50; whole pipeline 17.4 Mbps to about 256 kbps | Shifts and masks | Good: `bit32` fast calls, `buffer.readbits/writebits` (relative speed (U)) |
| Quantization with per-field accuracy | Entropy-coded uniform scalar quantization is within about 0.255 bit/sample of the rate-distortion bound at high rate | Cheap | Good |
| Delta against an acknowledged baseline | Quake 3: one changed field 36 bits vs 132 full; Gaffer: position 26 vs 50 bits | Acks, per-client baselines, memory per client | Feasible; reliable ordered remotes may serve as implicit acks (U) |
| Priority accumulator and interest management | Halo Reach reached 20% of Halo 3's bandwidth (with profiling and priorities, not isolated) | Per-client sort or buckets | Feasible; measure |
| Tolerance suppression and dead reckoning | Send only when error exceeds a threshold (DIS) | Shared extrapolation | Good if the extrapolation is integer |
| Prediction-based deltas | Unity: delta against a prediction from three acked baselines (U) | The predictor must match exactly on both ends | Integer only |
| Static Huffman or tANS tables | FSE: ratio 8.84 vs 6.38 for Huffman on one corpus; Quake 3 ships a static Huffman table | Tables trained offline and shipped | Integer, deterministic; Luau cost per symbol (U) |
| Adaptive range coding (LZMA, AV1 style) | Best ratio of the practical coders | Adaptive state per stream; must reset on loss | Integer; Luau cost per bit (U) |
| Integer codes (varint, zigzag, Elias gamma, Rice) | Fits small values | Trivial | Good |
| String dictionaries | Source engine string tables; Oodle Network 25% to 80% with a static dictionary | Agreed at handshake | Good |
| Context mixing (lpaq) | High ratio at 3.6 µs/byte native | Far too slow | Not practical |

**Interaction with Roblox's zstd.** Buffers are already compressed on the wire (§1.1). An entropy coder
of our own can only help where zstd cannot see structure (small payloads, bit-packed fields), and it
may also defeat zstd. The first measurement is wire bytes against buffer length, for payloads with and
without our coding (§7).

### 2.2 Frontier research, 2022 to 2026

| Method | Claim | Why it does or does not fit |
|---|---|---|
| Language-model compression ([Delétang et al.](https://arxiv.org/abs/2309.10668), 2023) | Beats PNG and FLAC | 70B parameters, GPU-scale |
| ts_zip, NNCP, cmix ([Bellard](https://bellard.org/nncp/)) | enwik9 at 0.85 to 1.08 bits per byte | Megabytes to gigabytes of model, KB/s to MB/s on GPUs |
| L3TC ([arXiv 2412.16642](https://arxiv.org/abs/2412.16642), 2024) | 48% saving vs gzip, fastest learned coder | Text only, needs a model |
| StateSMix ([arXiv 2605.02904](https://arxiv.org/abs/2605.02904), 2026) | 8.7% better than `xz -9e` on 1 MB | Needs kilobytes of data to warm up; game messages are bytes |
| Learned image entropy models | Floating-point models decode to garbage across platforms; integer lookup-table CDFs fix it (U) | The lesson carries over: synchronized model state must be integer |
| Modern adaptive coders ([Strutz and Rischke](https://arxiv.org/abs/2601.06120), 2026) | Table-driven adaptive range coder, best for 12 to 64 symbols | Borrowable: division-free, shift-updated tables |
| Trained dictionaries (zstd, Oodle) | Gains concentrated in the first few KB | Borrowable: per-field static tables trained offline from recorded traffic |
| Semantic or goal-oriented compression ([Gündüz et al.](https://arxiv.org/abs/2207.09353), 2022) | Framework, no game numbers | Matches the per-field accuracy idea |
| Quantization advances (TurboQuant, 2025) | Near-optimal for high-dimensional vectors | No benefit at 3 to 4 dimensions |
| Learned delta prediction for game state | No 2023 to 2026 peer-reviewed result found (U) | None to borrow yet |
| Quantum compression (Schumacher) | Compresses quantum states | Does not apply: Roblox sends classical bytes, bounded below by Shannon entropy |

### 2.3 Determinism, in two classes

1. **Codec state that both sides mirror:** adaptive models, coder probabilities, shared predictors.
   A mismatch makes the decoder produce garbage.
   - Staff say float results can differ across hardware (§1.2).
   - IEEE `+ - * / sqrt` are reproducible under the same settings; transcendental functions and fused
     multiply-adds are the risks ([Gaffer](https://gafferongames.com/post/floating_point_determinism/)).
   - Whether Roblox's builds fuse multiply-adds is (U).
   - Integer-valued doubles below 2^53 are exact under `+ - *` and `bit32`, so integer-only state is
     safe (analysis, not sourced).
2. **Values:** lossy schemes where a mismatch is a bounded error. This covers quantization with an
   error budget, suppression within a threshold, closed-loop deltas against the receiver's
   reconstruction, importance-weighted precision, and eventually-exact values that converge by
   repetition (Halo).

The probe in §6 tests class 1 on real platforms.

## 3. Testing, benchmarks, errors

### 3.1 Testing in Studio

- **Frameworks:**
  - Jest Roblox (port of Jest 27, latest 3.20.1 from 2026-08) is the maintained framework; it has no
    coverage. [repo](https://github.com/Roblox/jest-roblox)
  - TestEZ was archived on 2024-09-14.
- **Property-based testing:** no Luau library with generators and shrinking exists. v4's `Rng`
  (xoshiro128**), tape shrinker and `Generate` are pure Luau and the best asset to carry over.
- **Server plus clients:** `StudioTestService:ExecuteMultiplayerTestAsync` runs one server and up to
  8 clients as separate Studio sessions, with results returned through `EndTest` (§1.3). How
  clients report to the server is left to the test, for example a plain RemoteEvent owned by the
  harness.
- **Clock:** `task.delay` and `task.wait` resume on Heartbeat, so timing is quantized to frames. Use
  `workspace:GetServerTimeNow()` for time shared across machines and `os.clock()` for local intervals.
  Tests need an injectable clock and scheduler.
- **Automation from outside Studio:**
  - the Studio MCP, available here;
  - the Studio CLI `RunScript`;
  - community runners (rodeo, studio-run, jest-roblox-cli).

### 3.2 Coverage

- **First choice: native coverage.** `ScriptContext:EnableCoverage` plus `GetCoverageStats` gives
  line and function counts with no source rewriting (§1.3). To verify:
  - recording in play-test server and client DataModels;
  - multi-client sessions;
  - `--!native`;
  - overhead.
- **Fallback: instrumentation.** Insert counters into a test build (jest-roblox-cli does this with
  an AST). For Lync, a Lute transform fits (`lute transform` gives a syntax tree with spans).
  Branch coverage needs instrumentation either way.
- **Feature coverage:** claim ids in the spec, tests tagged with the claims they prove, and a Lute
  script that checks both directions:
  - every claim has a test;
  - every tag names a real claim.

### 3.3 Benchmarks

- **Timer.** `os.clock()` has sub-microsecond precision on a monotonic per-machine baseline. Its docs
  wording supersedes older "CPU time" threads.
- **Profilers.** `debug.profilebegin/profileend` labels show in the MicroProfiler. The Script Profiler
  runs at 1 or 10 kHz and exports JSON, with no programmatic start.
- **Statistical method:**
  - warmup;
  - batches scaled to a minimum duration;
  - Tukey fences that flag outliers but keep them;
  - median with MAD and a bootstrap confidence interval (Criterion);
  - baseline comparison with a noise threshold and a Mann-Whitney test over at least 9 repetitions
    (Google Benchmark).
- **Allocation.** Only `collectgarbage("count")` and `gcinfo` exist on Roblox, and a collection cannot
  be forced. An allocation delta is therefore a noisy lower bound; measure over many iterations.
- **Baselines** are keyed by machine, Studio version, DataModel (server or client) and native on or
  off. Client numbers come from the interpreter (§1.2).
- **Network bytes.** Count payload bytes at Lync's transport seam. Use `Stats` rates only as a sanity
  check.

### 3.4 Errors and logging

- **`error(message, level)`.** It adds `source:line:` only for string messages with a level above 0
  landing on a frame with line info. Level 0 removes the prefix, but Output still shows the stack
  trace (staff, "intentional"). [luaB_error](https://raw.githubusercontent.com/luau-lang/luau/master/VM/src/lbaselib.cpp)
- **`debug.info(level | function, "slnfa")`** returns structured frames. The format of
  `debug.traceback` may change (staff), so structure comes from `debug.info`.
- **Threads.** An `xpcall` handler runs on the failing stack. `task.spawn`, `defer` and `delay` start
  a fresh stack, so the spawner's frames must be captured at call time when they matter.
- **Non-string error values** print badly when uncaught. Thrown values should be strings.
- **Error events.** `ScriptContext.Error` reports unhandled errors with message, trace and script.
  `LogService.MessageOut` carries `context` since structured logging.
- **Clickable Output.** Stack entries link to `Script:line`. Whether clicking a level-2 error opens the
  caller's line is (U).

## 4. roblox-ts

- **Version.** The latest release is 3.0.0 (2024-09-12, TypeScript 5.5.3). `master` is active
  (TypeScript 5.9.3, fixes from 2026-10-01) but unreleased. Milestone 3.1.0 includes `Symbol.iterator`
  support (#1826). [npm](https://registry.npmjs.org/-/package/roblox-ts/dist-tags)
- **Publishing a Luau library:**
  - `main` points to the Luau entry, `types` or `typings` to the `.d.ts`;
  - `init.luau` pairs with `index.d.ts`;
  - single-value modules use `declare const M: M; export = M;`.
  - Examples: `@rbxts/jecs`, `@rbxts/bytenet`, `@rbxts/squash`.
  - The roblox-ts guide for Luau packages is an unfinished placeholder.
- **Scope:**
  - Only `@rbxts/` is treated as a roblox-ts package without user changes, and it needs org
    membership.
  - A custom scope needs two user edits: `typeRoots`, and a `node_modules` entry in the Rojo project.
  - Scope names with `.`, `_` or `~` are mishandled until PR #3104 ships (merged 2026-10-01,
    unreleased).
- **Mappings:**
  - **Multiple returns:** `LuaTuple<[A, B]>`.
  - **Tables:** `Map`/`ReadonlyMap` for `{ [K]: V }`.
  - **Call style:** `this: void` on a member makes it a dot call; a method member makes it a colon
    call.
  - **Brands:** `_nominal_*` unique-symbol members for nominal types.
  - **Instance classes:** class name to type via `Instances[T]` with `T extends keyof Instances`.
  - **Iteration:** custom iterables are not supported until #1826, so expose arrays, maps or
    `IterableFunction`.
- **Sync tooling:** none official.
  - `rbx-tsx types` and `luau2ts` generate `.d.ts` from Luau but turn metatable classes, type
    functions and cross-module references into `any`.
  - `@rbxts/jecs` does not check its `.d.ts` in CI. v4's `Declaration.ts` and `Rejections.ts` were
    already better than the examples found.

## 5. Competing libraries

| Library | Approach | Notable | roblox-ts | Status |
|---|---|---|---|---|
| Blink | IDL compiler with a Studio plugin; generates typed modules | Typed ranges, f16, call modes (sync, async, polling), validations; own benchmarks lead | `.d.ts` output | Active, 1.0 pre-releases through 2026-09 |
| Zap | IDL plus codegen | Bitpacking, `FireExcept`/`FireList`/`FireSet`, profiler labels, manual event loop | `.d.ts` output | Active, 0.6.29 (2026-06) |
| ByteNet | Runtime schema; `definePacket` infers types | Low-level, namespaces | preview package | Inactive since 2024-25 |
| Packet (Suphi) | Runtime | 16- and 24-bit floats, batching | none found | Security issues reported after launch |
| Warp | Runtime, dynamic with optional schema | Rate limiting | unclear | Uncertain; thin docs |
| BridgeNet2 | Wrapper over RemoteEvents | Header reduction | v1 only | Superseded by ByteNet |
| Red | Runtime | Claims 75% less bandwidth | third-party wrapper | Archived; Zap is the same org's successor (inferred) |
| Squash | Serialization only | All Roblox types | separate typings repo | Last push 2026-01 |

**Benchmarks.** Only author-run benchmarks exist:
- Blink's own (2025-04, Ryzen 9 7900X): median FPS in the entities test, Blink 42, Zap 39, ByteNet 32,
  plain Roblox 16.
- BlinkBlox (2026-09) uses forced GC, memory ballast and randomized payloads. That methodology is
  worth copying.

**What users ask for most** (issues and DevForum threads):
1. Exact inferred types for payloads, handlers, functions, generics and unions.
2. No regeneration step after editing a schema. This is the main complaint about the codegen
   libraries.
3. Real documentation with examples.
4. Abuse protection: rate limits, a guard around each listener, validation.
5. Inspection: whether anything is connected, profiler labels, build profiles.
6. Scale to large schemas.
7. TypeScript parity: enums, optional keys, handler declarations.

**Where v4 was already ahead:** replicated sets, a handshake with a schema hash, groups, and
`describe`.

**Where v4 was behind:**
- the codegen libraries get exact types without depending on inference;
- codec breadth (f16, DateTime, BrickColor, an `unknown` type);
- receive modes such as polling;
- a Studio plugin and profiler labels;
- per-event rate limits.

## 6. Experiments run here

| Experiment | Result |
|---|---|
| Lune 0.10.5 parsing `const` | Syntax error. Lune cannot run v5 code. |
| Luau 0.740 CLI | Accepts `const`; `--coverage` writes lcov line hits. |
| Lute 1.0.0 | Runs v5 syntax; lists directories, reads files, runs subprocesses. |
| darklua 0.19.0 with no rules | Output byte-identical to input, alignment included. |
| Float determinism probe (`.data/probes/Determinism.luau`), 19 math operations over 4401 inputs | Windows, Luau 0.740: interpreted and native bit-identical. Baseline in `.data/probes/Determinism.windows-luau-0.740.txt`. |
| Aliasing a type function (darklua's bundle output shape) | Works on Luau 0.740: `Nillable<number>` resolves to `number?` and rejects a string. |
| Literal inference from arguments | `f("1v1", "2v2")` and `f({ "1v1", "2v2" })` widen to `string`; numbers widen to `number`. |
| Literal inference from table keys with `keyof` | `f({ ["1v1"] = true, ["2v2"] = true })` gives exactly `"1v1" \| "2v2"` and rejects `"3v3"`. |
| Explicit instantiation | `f<<"1v1" \| "2v2">>("1v1", "2v2")` exact, but spelled twice. |
| Enum items as arguments | `f(Enum.Material.Grass, Enum.Material.Rock)` gives `Enum.Material`. |
| Whole Enum to item type | Structural inference gives `unknown`; a type function cannot read extern types ("expected self to be a table, got extern"). |
| Exporting a type function across modules | Works on Luau 0.740: a module exports `type Infer<C> = InferImpl<C>`, and a requirer's `Types.Infer<typeof(codec)>` accepts `"2v2"` and rejects `"3v3"`. |
| Studio (Edit, Windows): determinism probe | Roblox's Luau build gives the same 19 hashes as the upstream Luau 0.740 CLI on the same machine. Studio accepts `const`. |
| Studio (play-test server): native coverage | `EnableCoverage` plus `GetCoverageStats` returned per-line hits for a runtime-created module: lines 3 and 4 hit twice, the uncovered `return` 0, non-code lines -1. |
| Studio: unreliable limit | Zero buffers arrived up to 8000 B; random buffers arrived at 980 B and dropped from 990 B. The limit is measured after compression. |
| Studio: exact call size from Roblox's drop warning | "Payload went over by: N bytes": a 990 B random buffer plus a 9-character tag string came to 1005 B, and with a 10-character tag the call was 16 B over the payload. A buffer plus a short string costs about 6 B beyond the string's characters, so a lone random buffer fits up to about 995 B. |
| Studio: LogService | `GetLogger` is "not yet available" in this build. `LogService:Warn(template, context)` works and prints only the filled template, with no source name. |
| Studio: reliable compression | 4000 B per frame: 2.8 KB/s on the wire for zeros, 241.9 KB/s for random, against 240 KB/s of payload (`Stats.DataSendKbps`). |

## 7. Measurements still needed

In Studio (or a published place where marked):
1. **Bytes.** Done for the extremes: zstd removes almost everything from redundant buffers and nothing
   from random ones (§6). Still to measure: the size below which zstd skips small buffers, and how much
   it removes from realistic bit-packed payloads with and without our own coding.
2. **Unreliable limits.** Done: the limit applies after compression (§6). Still to measure: the
   per-call overhead.
3. **Encode and decode cost** in the client interpreter and with native on the server: `bit32` word
   packing against `buffer.readbits/writebits`, table-driven entropy decode per symbol, and adaptive
   range decode per bit.
4. **Float determinism** on a published place: a live server (Linux) and clients on Windows, macOS,
   iOS and Android, running `.data/probes/Determinism.luau`.
5. **Native coverage.** Works in a play-test server (§6). Still to test: client DataModels,
   multi-client sessions, `--!native` scripts.
6. **`StudioTestService`** driven from the Studio CLI or a plugin, and the return path for results.
7. **Behaviour under simulated delay, jitter and 0.5% loss.**
8. **GC pressure** of decode allocations, measured over many iterations.

## 8. Implications for v5

Proposals that follow from the findings, for review.

1. **Require form.** Decided: `.luaurc` aliases in `src`, converted for Roblox by darklua's
   `convert_require`. Roblox itself resolves only `./`, `../`, `@self/` and `@game/`.
2. **Compression order.** First one call per player per frame, schema bit packing with per-field
   accuracy, and deltas with change masks. Then measure what zstd already does before any entropy
   coding of our own. Synchronized codec state is integer-only. Frontier methods are out.
3. **Tests.** Two tiers in Studio:
   - deterministic in-process tests with a fault-injecting transport and a manual clock;
   - a small set of real multi-client tests through `StudioTestService`.
   Port the algorithms of v4's `Rng`, shrinker and `Generate`, rewritten in skill style.
4. **Coverage.** Native `EnableCoverage`, measured working in a play-test server. Feature coverage
   through claim ids checked by a Lute script.
5. **Folders.** No `fixtures/`. The shared surface between test and bench is small: the generator and
   sample schemas. With aliases it can have its own folder at no cost; its name and boundary are part
   of the folder design. Goldens live beside their tests, with an update command that writes results
   returned from Studio.
6. **Benchmarks.** The statistics in §3.3, baselines keyed by host and DataModel, client numbers from
   the interpreter.
7. **Errors and logging.**
   - Every thrown value is a string with a stable code.
   - Caller frames come from `debug.info` at the public entry.
   - The spawner's frames are captured before `task.spawn`.
   - `LogService` structured logging carries context, with Lync supplying the source and line
     itself.
8. **Developer experience.** Exact types from values: key-set tables for closed sets, Enum items as
   values. roblox-ts `.d.ts` written to roblox-ts conventions and compiled against a fixture project
   on every check. No regeneration step, real docs, per-definition rate limits, and inspection hooks.
