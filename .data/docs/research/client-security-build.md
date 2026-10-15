# Lync v5 build and tooling pipeline

Researcher brief, 2026-10-15. This brief covers how Lync's runtime and codecs and the game's own code are
generated, placed and checked at build or edit time, and how that serves performance, typing and the runtime
integrity design. That design lives in `client-security.md` (keyed tag, replay window, id shuffling, traps,
`Suspicion`, knobs). This brief builds on it and does not repeat it. Where the two meet, the section number
there is cited as CS §n.

The coordinator set two decisions during this work, and the brief follows both:
- **Config format.** Build configuration is `lync.toml`. Generated artefacts are JSON. Behaviour and runtime
  policy stay in Luau, in server code. The shared schema stays Luau.
- **Tooling languages.** The compiler core must be Luau. The shipped CLI host only has to run Luau and install as
  one binary through rokit. Repo-internal tooling may use any language.

**Labels.** **verified** means I ran it or read the source. **documented** means official docs say so.
**reported** means a third party says so. **unverified** means my inference.

**Tools:** luau, luau-compile, luau-analyze 0.740 and API dump 0.741.19 (luau skill); Rojo 7.7.1, darklua 0.19.0,
Lute 1.0.0, Lune 0.11.0 (official Linux binaries, run); smol-toml 1.9.1 on Node 22. Sources read in
`.data/projects/`: rojo, darklua, luau-lsp 1.70.1, roblox-ts 3.0.0, lute, luau.

**Probes** (`.data/docs/probes/client-security-build/`, reproduced by `run.sh`, output in `run.out`): `gen.luau` +
`fixture/` (Lute generator prototype over a Rojo project), `rotation/` (bytecode and timing of seeded variants),
`placement/` (inlining size, 200-local limit), `config/` (TOML parity across three hosts, JSON Schema).

The previous draft's probes (`bench2`, `enc`, `fold`, `inline50`, `shared50`, `vm`) were deleted. Several of its
claims are corrected below, each marked *(corrects draft)*.

---

## 0. Bottom line

1. **What generation buys is speed and types.** Security gains a little. Straight-line codecs are about 4×
   faster, and concrete types work under both type solvers. For security a build adds three things a runtime
   cannot: zero-cost per-build field order and tag constants (§2.3); whole-project static facts such as which
   definitions client code can ever fire, raw-remote use and worst-case sizes (§4.2); and a reproducible manifest
   (§4.1). None of them touches the attacker who calls Lync's own API (CS §1.4 A4).
2. **The compiler core is pure Luau and host-agnostic.** The core is schema evaluation, IR, the layout planner,
   codegen, the static checks, the lexer and SHA-256 framing. Hosts inject I/O. The same core runs in the CLI
   host, in the Studio plugin, and (planner only) in the runtime-only path, so wire bytes cannot drift.
3. **Recommended CLI host: a Rust binary that embeds Luau through mlua.** It uses mlua 0.12.2 with luau0-src
   `0.22.0+luau740`, notify for file watching, and the toml crate. Lune is the fallback and prototyping host. Lute
   1.0.0 is rejected for shipping for now: in a few minutes of use I hit API drift from its own repo docs, and its
   latest release has no macOS x86_64 build (§1.2).
4. **No Studio plugin can hook publish or save.** Every publish and save member is `RobloxScriptSecurity`
   (verified, §1.4). For Studio-only users the plugin regenerates on edit. The runtime's schema-hash check is the
   safety net: stale generated code falls back to the runtime path on both sides at once, never to a wire split
   (§2.4).
5. **Per-build rotation costs nothing at run time.** Seeded variants compile to the same opcode sequence: 76/76,
   26/26 (reordered when fields move) and 27/27 instructions. Only constants and the order of field writes change.
   Doing the same rotation at run time adds loads and costs about 2–3× on a record write (§2.3).
6. **Per-client code generation is impossible on Roblox.** Per-player *selection* from a build-time pool is
   possible but not worth it. The runtime per-session id shuffle (CS §3.4) gives per-player variation with no
   replication cost (§3.3).
7. **The manifest cannot attest client scripts at run time.** `Source` carries the capability `PluginOrOpenCloud`
   (verified), so game code cannot hash its own scripts, and the client would be reporting on itself anyway. The
   server uses build facts (reachability, inferred direction, build id) instead (§4.3). *(corrects draft)*
8. **The config splits by when it acts.** `lync.toml` holds build-time knobs that are compiled in. Integrity
   policy is a server-only Luau API, because the runtime-only path needs it and the client learns the
   wire-shaping parts from SESSION (§5).

---

## 1. Vehicles

### 1.1 The compiler core (Luau; one implementation)

What it does and where it runs:

| Stage | Input | Output | Runs in |
|---|---|---|---|
| Evaluate | namespace modules, executed with Lync's declaration API | declaration descriptors | CLI host, plugin, runtime |
| Plan | descriptors, seed | IR: ids, field order, widths, worst-case sizes, schema hash | CLI host, plugin, runtime (seed 0 only) |
| Generate | IR, `lync.toml` | client shard and server shard per namespace, `.d.ts`, debug map | CLI host, plugin |
| Analyse | every project script's text | reachability, raw-remote and remote-creation findings | CLI host, plugin |
| Report | all of the above | `manifest.json`, `report.json`, `report.txt` | CLI host, plugin |

Constraints, each tied to evidence:
- **Evaluation runs the user's schema, so the core must be Luau.** The schema is a Luau module (A-1, A-2). In the
  CLI host it runs with a chunk name equal to its instance path. In my probe, `luau.load(..., "=" .. path, env)`
  worked (verified, `gen.luau`).
- **Namespace naming needs care.** A-2 names a namespace by the full name of the calling module. A host or a
  plugin that evaluates a clone, or evaluates under a file path, gets a different name. The core should set the
  expected name explicitly while evaluating, instead of relying on how each host names chunks (unverified for
  Studio clones).
- **Static analysis needs a parser that runs everywhere.** Lute's `@std/syntax` calls the C++ parser through
  `@lute/syntax/parser` (verified: `lute/std/libs/syntax/parser.luau`, `lute/syntax/src/parser.cpp` calls
  `Luau::Parser::parse`). That parser cannot run in Studio. The checks in §4.2 need only tokens: method names
  after `:`, a `[` after a view, and string arguments to `Instance.new`. So the core should carry a small pure-Luau
  lexer, and every host then gets identical findings.
- **Hashing must give identical digests in every host.** The CLI host provides SHA-256. Studio provides
  `EncodingService:ComputeBufferHash(input, Enum.HashAlgorithm.Sha256)`, which has security None and is
  thread-safe (verified, API dump). Its members are `Blake2b, Blake3, Md5, Sha1, Sha256`.

### 1.2 CLI host: Lute, Lune or an mlua binary

| | Lute 1.0.0 | Lune 0.11.0 | Rust host on mlua 0.12.2 |
|---|---|---|---|
| Luau version | bundled (1.0.0) | 0.740 ("Updated to Luau version `0.740`", changelog 2026-10-11) | `luau0-src 0.22.0+luau740` (crates.io, 2026-09-27) |
| Maturity | 1.0.0. Three rough edges in a few minutes of use (below) | 0.x since 2023, with breaking changes per minor (0.11 made `handle.stop()` a method) | mlua 0.12.2 (2026-10-03, 7.8 M downloads). Lune itself is built on it |
| File watching | `fs.watch` present (verified in the 1.0.0 binary) | **none**: `fs` has `copy isDir isFile metadata move readDir readFile removeDir removeFile writeDir writeFile` (verified) | `notify` 8.2.0 (2026-08-30, 171 M downloads) |
| Process control | `@std/process`: `args cwd env execPath exit homedir run system` (verified) | `process.exec` and the non-blocking `process.create` (changelog) | Rust `std::process` |
| TOML and JSON | `batteries/toml.luau` (pure Luau, no `require`) and `@std/json` | `serde.decode("toml"/"json"/"jsonc")` (verified for TOML) | `toml` 1.1.8 (TOML 1.1) and `serde_json` |
| Place files | none | `@lune/roblox` reads and writes `.rbxl`/`.rbxm` | `rbx_binary` 3.0.1 and `rbx_dom_weak` 4.2.0, or the `lune-roblox` 0.4.0 crate |
| Windows | release asset present | release asset present, Windows ARM too. Several Windows path fixes in the changelog | Rust std and notify use native Windows APIs (reported) |
| One-binary distribution | `lute compile` makes a standalone executable (docs) | `lune build` makes a standalone executable, cross-target (changelog) | `cargo build` per target, released on GitHub, installed by rokit |
| macOS x86_64 | latest-release asset **404** (verified) | 200 | ours to build |

**Lute rough edges, observed while writing the probe:** crypto resolves as `@lute/crypto` in 1.0.0 while the
repo's definitions document `@std/crypto`, and the CST string node carries `token` in 1.0.0 where the repo's
`cst.luau` names it `value`.

**Recommendation: a Rust host on mlua.** The host surface is small (files, walk, watch, hash, TOML/JSON, args,
exit codes): a few hundred lines once, with no dependency on a moving runtime API. Watch mode is required (§1.9)
and Lune has none. The crate pins the exact Luau release (`+luau740`). `lune-roblox`, `lune-std-serde` and the
rbx-dom crates can be reused as libraries for place-file work.

**verified (milestone build, f1fbfd7):** Lune 0.11.0 resolves `@self/`, `./` and `../` string requires as Roblox does. It exposes `Vector3`,
`CFrame`, `Color3`, `Instance` and `Enum` only through `@lune/roblox`, with f32 `CFrame` components as on Roblox,
so a test runner copies them into `getfenv(0)` before requiring library code. selene's `roblox` std couldn't be
generated behind the sandbox's proxy.

Lune is the right **prototyping** host and a supported fallback, because the core is host-agnostic. Lute stays
fine for repo-internal scripts. Python remains fine for compression simulations, capture tables and bench
statistics, which never ship.

### 1.3 Rojo

Rojo is the project model and an uploader. It does not transform code.

| Can | Evidence |
|---|---|
| Emit `sourcemap.json`: `{name, className, filePaths, children}` per node, with `--watch` and `--include-non-scripts` | `src/cli/sourcemap.rs` (`SourcemapNode`, `watch`, `include_non_scripts`), verified. My fixture's map is in the probe dir |
| Build a place or model from `*.project.json`. Map `.server`/`.client` files to scripts, with `emitLegacyScripts` choosing LocalScript or RunContext Scripts | `src/project.rs`, `snapshot_middleware/mod.rs`, verified |
| Choose file loaders with `syncRules` (`json`, `toml`, `yaml`, `txt`, `csv`, `rbxm`, `ignore`) | `src/project.rs` tests, verified |
| `rojo upload --api_key --universe_id` POSTs to `.../places/{id}/versions?versionType=Published` with `x-api-key` | `src/cli/upload.rs`, verified |
| `rojo syncback` from a place to files | `src/cli/syncback.rs` |

| Cannot | Evidence |
|---|---|
| Run any transform, hook or plugin | The middleware set is a fixed enum (`snapshot_middleware/mod.rs`). The changelog's only "filter plugins" entry is from 0.4.0 (March 2018) and is long gone |

Lync's integration with Rojo is therefore: read `sourcemap.json`, write generated `.luau` into folders that the
project file already maps, and let `rojo serve` or `rojo build` carry them. The output must be deterministic and
written only when changed, so `serve` does not churn.

### 1.4 Studio plugin

API facts (verified against API dump 0.741.19 with `api`):

| Member | Security | Use |
|---|---|---|
| `ScriptEditorService:UpdateSourceAsync(script, callback)` | PluginSecurity, Yields | The safe way to write a script. The docs say the callback receives the old source, "may not yield", returns nil to cancel, and "the editor may reject this update if the [source] was out of date … the callback will be re-invoked" (documented, [ScriptEditorService](https://create.roblox.com/docs/reference/engine/classes/ScriptEditorService)) |
| `ModuleScript.Source`, `Script.Source` | Security None, but Capabilities read and write `PluginOrOpenCloud` | Plugins and Open Cloud can read and write source. **Game scripts cannot read it at run time**, so a game cannot hash its own code (§4.3) |
| `ScriptEditorService:RegisterScriptAnalysisCallback`, `TextDocumentDidChange`, `GetEditorSource`, `OpenScriptDocumentAsync` | PluginSecurity | Edit-time diagnostics (direction misuse, raw remotes); regenerate when the schema changes |
| `ScriptEditorService:EditSourceAsyncWithRanges`, `StripComments`, `OpenStringValueDocumentAsync` | **RobloxScriptSecurity** | Not available. A StringValue cannot be opened in the script editor, which shapes where Studio keeps `lync.toml` (§5.2) |
| `ChangeHistoryService:TryBeginRecording`, `FinishRecording`, `SetWaypoint` | PluginSecurity | One undo step per generation |
| `Plugin:GetSetting`, `SetSetting` | PluginSecurity | Per-user, per-machine state. Not shared through Team Create, so not for config |
| `RunService:IsEdit()` | PluginSecurity | Tell edit mode from play mode |
| **`StudioPublishService.OnPublishAttempt`, `RegisterPublishHold`, `GamePublishFinished`, `GamePublishCancelled`, `OnSaveOrPublishPlaceToRoblox`, `PublishAs`, `PublishLocked`; `StudioService.OnSaveToRoblox`, `ShowPublishToRoblox`, `OnPublishAsPlugin`; `StudioAssetService.OnSaveToRoblox`** | **all RobloxScriptSecurity** | **No publish or save hook for third-party plugins** (verified by a search of every member named Publish, Save, Upload, Commit or Package in the dump) |

**Script injection.** Writing scripts triggers Studio's Script Injection permission prompt, and a denial is
remembered (reported, [DevForum](https://devforum.roblox.com/t/how-to-detect-when-a-player-has-denied-script-injection-permission-on-a-plugin/1375400)).
Blink's plugin needs the same permission (reported, landscape §5.1). The plugin must detect a denial and say how
to grant the permission.

**Verdict on the plugin.** It can do everything the CLI does against the live DataModel (evaluate, generate,
analyse, report). It cannot be the publish gate, compile to bytecode or decompile. Its trigger is editing (schema
modules, `lync.toml`) plus a manual "Prepare release" action.

### 1.5 darklua

- **Fixed rule set.** darklua 0.19.0 has 32 named rules (verified, `src/rules/mod.rs`). There is no Luau-scriptable
  rule.
- **A custom pass needs Rust.** It means a Rust program that depends on `darklua_core`, implements the public
  `Rule` trait (`fn process(&self, block: &mut Block, context: &Context)`), and adds it with
  `Configuration::with_rule` (verified, `src/frontend/configuration.rs:87`).
- **Renaming is deterministic but has no seed.** Two runs of `rename_variables` over my seed-7 shard produced
  identical bytes (verified). Its options are only `globals`, `include_functions` and `detect_globals`.
- **Renaming locals buys nothing for shipped code.** Local and parameter names are not shipped. Potassium's
  `decompile` returns `UNNAMED_<addr>` (CS §2.1). *(corrects draft, which called it "the polymorphic-renaming
  workhorse")*
- **`remove_comments` strips hot comments.** Run on a shard, it removed `--!strict` and `--!optimize 2` (verified).
  The docs' remedy is `except: ["^--!"]` (documented, `site/content/rules/remove_comments.md`). The default
  `retain_lines` generator keeps line numbers.

**Verdict:** Lync needs no darklua. Its generator emits the final code. Teams that already run darklua (bundling,
`inject_global_value`) can keep running it over generated shards if they use `except: ["^--!"]`.

### 1.6 luau-lsp: plugin or definition files

- **The source-transform plugin is editor-only.** It is `transformSource(source, context) -> {TextEdit}?` and runs
  "before type checking". It is sandboxed (`string, table, math, bit32, buffer, coroutine, utf8`; optional
  `lsp.fs`), with a 5000 ms default timeout. It is "experimental … subject to change" (added in 1.65.0,
  2026-04-06). Sources: `src/Plugin/README.md`, `CHANGELOG.md`, verified.
- **It never runs in CI.** `src/AnalyzeCli.cpp` has no reference to plugins (verified by grep), so `luau-lsp
  analyze` does not apply them.

**Verdict:** this is not a vehicle for shipped code or CI checks. Generated shards carry concrete types, so
luau-lsp needs only the sourcemap. A plugin could give no-build users better hover types; that is optional polish.

### 1.7 roblox-ts transformer, and flamework-binary-serializer as precedent

- **Transformers rewrite TS, not Luau.** `compilerOptions.plugins` are loaded and run through
  `ts.transformNodes` over **TypeScript** source files. The transformed files are reprinted and re-typechecked
  before roblox-ts emits Luau (verified, `src/Project/functions/compileFiles.ts:124-160`). A transformer cannot
  emit Luau codecs except as TS that compiles to Luau, or by writing files as a side effect.
- **`.luau` files ship as written.** Non-TS files in `src` are copied to `out` verbatim (`copyItem.ts` filters out
  only compilable files, verified). The generator can write `Net.client.gen.luau` and `Net.gen.d.ts` into `src`,
  and `rbxtsc` ships them with no transformer.
- **flamework-binary-serializer 0.7.0** (npm, modified 2025-10-05; peer-depends on `rbxts-transformer-flamework`;
  read from the unpacked package):
  - The macro `createBinarySerializer<T>()` makes the transformer emit **metadata** (a type description).
  - The runtime **interprets** that metadata: `createSerializer.lua` branches on `meta[1]` kinds (`"f32"`,
    `"u8"`, …) on every value. This is the closure and interpreter shape that is about 4× slower than
    straight-line code.
  - Its own doc comment warns: "this serializer depends on the order of emit, but this isn't guaranteed to be
    stable across compiles". Lync must avoid that: ids and order come only from sorted names and the seed.

**Verdict:** the transformer is optional. What it adds is precision for TS sources: type-checker symbol resolution
makes reachability (§4.2) see through aliases, and finds `RemoteEvent.FireServer` by type rather than by name. The
same checks also run, less precisely, over `rbxtsc`'s Luau output with the core's lexer. The transformer reads
`lync.toml` with smol-toml (§5.2).

### 1.8 Open Cloud place publishing from CI

- **Endpoint:** `POST https://apis.roblox.com/universes/v1/{universeId}/places/{placeId}/versions?versionType=Published`,
  with header `x-api-key`. The body is `.rbxlx` (`application/xml`) or `.rbxl` (`application/octet-stream`). The
  key needs the `universe-places` permission with Write. Sources (documented):
  [usage guide](https://create.roblox.com/docs/cloud/guides/usage-place-publishing),
  [reference](https://create.roblox.com/docs/cloud/reference/features/places).
- **`versionType`** is `Saved` ("saved, but not published") or `Published`. The endpoint is marked BETA. The rate
  limit is **30/minute per API key owner**. No body size limit is stated.
- **Limitation:** the API "doesn't update" `EditableImage`, `EditableMesh`, `PartOperation`, `SurfaceAppearance`
  or `BaseWrap`. Places with those must be published from Studio after editing them. Scripts are unaffected.

**Verdict:** this is the only fully automatic path in which generation always precedes publishing. The pipeline
is `lync build` → `rojo build` → POST, or `rojo upload --api_key`. Use `Saved` for staging.

### 1.9 Who owns which job, and how Rojo and Studio-only users get the same result

| Job | Owner | Rojo user | Studio-only user |
|---|---|---|---|
| Evaluate, plan, generate, analyse, report | Luau core | CLI host | plugin (same core, vendored) |
| Trigger | — | `lync watch` (notify) beside `rojo serve`; `lync build` in CI | the plugin regenerates on schema or `lync.toml` edit; "Prepare release" draws a new seed |
| Write files or scripts | host | files in mapped folders, only when changed | `UpdateSourceAsync`, one ChangeHistory recording |
| Config | `lync.toml` | file at the project root | the same TOML text in `ServerStorage.Lync.Config` (StringValue), edited in a plugin widget |
| Types | core | `.luau` types and `.d.ts` | `.luau` types |
| Publish | Roblox | Open Cloud from CI, or Studio | Studio (no hook: §1.4) |
| Safety net | runtime | schema-hash check at first view (§2.4) | the same |
| TS-specific checks | transformer (optional) | `rbxtsc` | — |

**The least effort.** A Rojo user adds `lync.toml` and one `lync watch` beside `rojo serve`. A Studio-only user
installs the plugin, which creates the config value and regenerates on edit.

**The same result.** Both run one core, at one Luau version, over one TOML text, so output is byte-identical for
the same seed and schema. Only the trigger differs: CI can guarantee generation before publish, and Studio
cannot. The runtime safety net makes that gap a speed problem, never a correctness problem.

---

## 2. Generation model

### 2.1 Code shape

- **Two shards per namespace, one per side.**
  - The **client shard** holds what a client runs: encoders for client-to-server definitions and decoders for
    server-to-client definitions. It goes to a replicated folder.
  - The **server shard** holds the rest, plus server-only facts: reachability, inferred directions, per-definition
    worst-case sizes. It goes to `ServerScriptService` ("never replicated to clients", documented,
    [data model](https://create.roblox.com/docs/projects/data-model)).
  - Clients download only their half, and server-only facts never ship.
- **Hard limits per generated module** (verified, `Bytecode/include/Luau/BytecodeBuilder.h`): 255 registers, 200
  locals and 200 upvalues per function; 2^23 constants; jump distance 2^23. A module with 210 top-level `local function`s fails: `CompileError: Out of local registers when trying to
  allocate f200: exceeded limit 200` (verified, `placement/limits.out`). So shards put definitions in a table
  (`M.shoot = {...}`) and keep each definition in its own small functions.
- **Native-code budget.** Native codegen keeps a running IR instruction total per module.
  `CodegenHeuristicsInstructionLimit` defaults to 1,048,576, and a function that would cross it is left
  interpreted (`CodeGenOverflowInstructionLimit`; verified, `CodeGen/src/CodeGenContext.cpp:527`). Roblox's value
  of this FInt is unverified. That is one more reason to shard.
- **Size cap.** `maxShardBytes` defaults to 64 KB of source. A namespace that would exceed it splits into numbered
  parts by sorted definition name, behind a small index module. The Creator Store restricts "unnecessarily large
  scripts" (documented, §6.1), and very large single files are the Zap complaint (landscape, Zap #225).
- **Readable output.** No minification and no renaming. A header names the generator version, the schema file,
  the schema hash and the seed. Each definition carries a comment with its schema origin. The probe emits
  `-- fixture.ReplicatedStorage.Shared.Combat.shoot (event, lane u) from src/shared/Combat.luau:5` (verified,
  `gen.luau`).
- **Schema locations in errors cost nothing on the success path.** Error strings are constants and are built only
  when thrown: `error("[Lync] ….hit.damage must be a number", 3)` in the probe. In a Studio-only build the
  "file:line" is the namespace module's full name and its line in `Source`. The debug map (§5.6) adds generated
  line → schema location for tools.

### 2.2 Determinism

Same core version, same schema text, same `lync.toml` and same seed must give byte-identical output on every host.
The rules:

| Hazard | Rule | Evidence |
|---|---|---|
| Luau table iteration order is unspecified | sort every name list before use | probe sorts; the typing brief T3 runtime note |
| Roblox `Random`'s algorithm is undocumented | the core's own xorshift32 over `bit32` | CS §3.4; `gen.luau` `rng` |
| Float literals | `tostring` is shortest round-trip: `0.1*3` prints `0.30000000000000004` and `tonumber(tostring(x)) == x` | verified, luau 0.740 |
| Line endings and Windows | always emit `\n`; hash the emitted bytes | rule |
| JSON key order | emit sorted keys | rule; the probe's runs matched, but by insertion pattern only |
| Host clocks, paths, environment | never in output; timestamps only in `report.txt` | rule |

**Measured** (verified, `run.out`): two runs at seed 0 gave byte-identical manifests; two runs at seed 7 gave
byte-identical trees (`diff -r` clean); seeds 0, 7 and 8 gave three different shard hashes.

**Seed 0 is the canonical build.** It means identity id order, canonical field order and fixed tag constants. The
golden vectors (W-190) and the runtime path's wire are defined at seed 0. Tests also run fixed nonzero seeds, so
permutation bugs surface.

### 2.3 Per-build rotation, and why it costs nothing

**What rotates per build** (seed ≠ 0): record field order, and four tag-PRF initialisation constants mixed with
the per-connection key `K` from SESSION (CS §3.1). Ids already shuffle per server at run time (CS §3.4,
`shuffleIds = "server"`), so a build-time id rotation would add nothing and is not offered.

**Measured** (`rotation/compare.py`, verified, `run.out`). One template was filled with four seeds plus a
"runtime" variant that reads the same values from tables. Each was compiled at `-O2` and its instruction streams
compared, ignoring `REMARK`s:

| Function | seed 0 | seeds 7, 8, 12345 | runtime-table variant |
|---|---|---|---|
| `tagWord` (one ARX round with 4 constants) | 76 instructions | 76, same opcode sequence | 80: each constant becomes `GETUPVAL` + `GETTABLEN` + `FASTCALL2` instead of `FASTCALL2K` |
| `writeHit` (3 fields) | 26 | 26: same sequence at seed 7; same multiset, reordered, at 8 and 12345 | 28 plus a loop and closure calls |
| `dispatch` (3 ids) | 27 | 27, same sequence | 59 (table of closures) |

**Remarks** (luau skill `remarks` and `bytecode`, `rotation/remarks.out`): every constant is a K operand of a
builtin fast call (`FASTCALL2K 32 R0 K0 L0 [1390851128]` for `bit32.bxor(k0, C0)`), and `buffer.writeu16`,
`writeu8`, `readu16` and `readu8` are all `builtin` fast calls. A rotated build differs from seed 0 only in K
values, immediate ids and which field's write comes first.

**Timing** (2M iterations, best of 7; ranges over 6 runs on a shared machine, ns per call, so only gaps larger
than the spread mean anything):

| | `tagWord` | `writeHit` | `dispatch` |
|---|---|---|---|
| seed 0 | 81–118 | 41–72 | 22–50 |
| seed 7 | 82–116 | 42–60 | 22–33 |
| runtime tables | 95–125 | 113–142 | 34–43 |

Seeded variants are indistinguishable. The runtime-table record write is 2–3× slower; for `tagWord` the four extra
loads are lost in the noise.

**What rotation buys.** Hand-built frames, public byte scripts and tag reimplementations written against build N
stop working on build N+1, at zero run-time cost.

**What rotation does not buy.** Any attacker who uses Lync's own encoder (CS §1.4 A3/A4) is unaffected. The
constants sit in the client's bytecode as K constants and can be read with `getconstants` or a decompiler.
Rotation shortens the shelf life of static tooling to one release; it is not a secret.

### 2.4 Coexistence with the runtime-only path

- **Same API.** `Lync.client(ns)` and `Lync.server(ns)` return the same views either way (A-4, A-136 to A-138). A
  generated shard supplies codecs to the view; it never replaces the API.
- **Lookup.** The runtime cannot read `lync.toml`, so locations are fixed by rule (§3.1). At first use of a view
  it looks for the namespace's shard there and compares the shard's embedded schema hash with the hash of the live declarations, which the runtime computes
  anyway for HELLO (W-184).
- **On a match**, the generated codecs are used.
- **On a mismatch or a missing shard**, the runtime path is used, and Studio prints one `[Lync]` line naming the
  stale namespace.

  Both sides make this decision from the same place file, so they agree. The HELLO hash must also include the
  **build seed**. A generated client must never be paired with a runtime-path server or a server from another
  build. If that ever happens (a hand-built client, say), it is a handshake mismatch, not a decode fault.
- **Same wire at seed 0.** The runtime path and a seed-0 build share the planner, so they produce identical
  bytes. A differential test encodes random values of every schema in the test corpus through both paths and
  compares bytes. Then it repeats with fixed seeds, comparing the generated path with a runtime path told the same
  seed. The runtime path *can* take a seed, because it already iterates a field list, so a permuted list costs
  it nothing extra. That keeps the planner honest even though production runtime-path games run at seed 0.
- **Runtime field shuffling against a build.** CS §3.4 offers `shuffleFields` as a runtime knob. Generated
  straight-line codecs cannot follow a per-session field order without becoming the slow path. With generated
  code present, the runtime must ignore `shuffleFields` with one warning; `rotate.fieldOrder` covers it per build.

---

## 3. Placement in the game tree

### 3.1 Where generated modules live

| Output | Location | Why |
|---|---|---|
| Client shards | `<namespace's parent>.LyncGenerated.<namespace leaf name>`, e.g. `ReplicatedStorage.Shared.LyncGenerated.Combat` | Clients `require` them; the namespace already sits in a replicated place, so its sibling does too |
| Server shards | `ServerScriptService.LyncGenerated.<namespace full name>` | Never replicated. Holds reachability, inferred direction and size facts |
| Config (Studio-only) | `ServerStorage.Lync.Config` (StringValue) | ServerStorage is "only meant for server use" (documented). Saved with the place, so Team Create shares it |
| Manifest, report, debug map | outside any folder the project maps (`lync-build/`). For Studio, kept by the plugin | developer-only (§5.6) |

`project.sharedOutput` and `serverOutput` only say which *files* Rojo maps to those instance paths; the build
checks through the sourcemap that they land there. Generated code cannot live inside the Lync package: Wally and
pesde rewrite `Packages/` on every install.

### 3.2 Spreading generated code across the game's own modules

Option: inline each definition's encoder into every game script that fires it, so no Lync codec module exists.

| Cost or effect | Finding |
|---|---|
| Size | 50 call sites with inlined encoders: 22,927 B of bytecode (`-g0`) against 4,587 B shared, **5.0×**. Source is 16,962 B against 4,505 B (verified, `placement/size.out`). Every client downloads it |
| Require graph | Every game script that fires would gain a dependency on generated text inside itself. A schema change rewrites game scripts, not one generated folder: noisy diffs, merge conflicts, and `UpdateSourceAsync` races with scripts a developer has open |
| Debuggability | Codec errors would point into `Weapon:142`, not a shard; schema locations would have to go into every copy |
| Security | Batching per player per frame needs one queue and one flush (landscape §4). That central function remains, and an executor finds it with `getgc`/`filtergc` by its constants (CS §1.2). An attacker calls it or the view; nothing about A3/A4 changes |
| Speed | None: a shared call to a straight-line encoder is already a fast path |

**Verdict:** refuse. Keep one shard per namespace and side. The draft's "scatter and dissolve" idea is in the
refuse list.

### 3.3 Per-player variants from a build-time pool

Mechanism: the server holds N variants of the client shard in ServerStorage (`NotReplicated`, verified) and
clones one into each player's `PlayerGui` (`PlayerReplicated`, verified tag). Only that player receives it.
What it costs:
- **Replication.** Each player downloads one variant, roughly the size of the shared shard, so bytes are about
  equal. The server also holds a clone per player and replicates one extra script instance per player.
- **Timing.** Client code cannot `require` its codecs until the clone arrives. PlayerGui is filled from StarterGui
  "when the character first spawns", and with `CharacterAutoLoads = false` not until `LoadCharacterAsync`. With
  reset on spawn, PlayerGui contents "are cleared and replaced" (documented,
  [PlayerGui](https://create.roblox.com/docs/reference/engine/classes/PlayerGui)). The variant must therefore sit
  in a `ResetOnSpawn = false` ScreenGui, and Lync's client start must wait for it.
- **Gain.** Each variant is still read in full by that player's executor. Per-player differences in *ids* already
  come free from per-session upstream shuffling (CS §3.4, one decode table per player on the server, no
  replication). A pool adds per-player *field order* only, which matters solely to an attacker who shares
  byte-level scripts between players inside one build.

**Verdict:** refuse. It costs a join-time dependency and per-player instances for a gain the runtime shuffle
mostly provides.

### 3.4 What Roblox allows

| Possible | Not possible |
|---|---|
| Per-build code: any shape, compiled into the place | Per-client code generation: clients have no compiler, and `LoadStringEnabled` is `NotScriptable` and server-only (verified, API dump) |
| Per-server values in tables set at run time (SESSION seed, key, permutation): zero cost through a table already indexed (CS §3.4) | Per-server *straight-line* code: that would need server `loadstring` producing client code, which cannot reach a client as code |
| Per-player *selection* of a pre-built ModuleScript through PlayerGui (§3.3) | Hiding any client code from that client's executor |
| Server-only code and data in ServerScriptService or ServerStorage | Reading or hashing script `Source` from game code (capability `PluginOrOpenCloud`, verified) |

---

## 4. Provenance and verification

### 4.1 Build manifest

`lync-build/manifest.json` has sorted keys and LF line endings:

```json
{
  "format": 1, "lync": "5.0.0", "core": "sha256:…", "seed": 7,
  "namespaces": {
    "ReplicatedStorage.Shared.Combat": {
      "schemaHash": "…", "schemaFile": "src/shared/Combat.luau",
      "ids": { "inventory": 0, "reload": 1, "shoot": 2, "adminGrant": 3, "hit": 4 },
      "shards": { "client": "sha256:…", "server": "sha256:…" },
      "reachability": { "status": "incomplete", "because": "StarterPlayerScripts.Client.Dynamic:6",
                        "clientReferenced": ["inventory", "reload", "shoot"] },
      "worstCase": { "shoot": 22, "hit": 4 }
    }
  },
  "findings": { "rawRemoteCalls": 1, "remoteCreation": 1, "dynamicAccess": 1 }
}
```

The probe writes a smaller manifest of this kind (seed, ids, schema and shard SHA-256, findings; verified,
`gen.luau`). Its uses:
- **Reproducibility.** Rebuilding with the recorded seed must reproduce every hash; CI fails if it does not.
- **Compatibility diff.** Diffing two manifests shows which definitions changed wire layout.
- **Drift check.** The plugin and CLI recompute hashes of what is in the tree and flag hand edits. Studio hashes
  with `EncodingService` (§1.1).

### 4.2 Build-time checks

All of these run in the core over script text. They verify the **developer's** code: attacker code never passes
through the build. Soundness is therefore needed against accident, not malice. The probe found each kind in the
fixture (verified, `run.out`): client fires `inventory, reload, shoot`; dynamic access at `Dynamic:6`; a raw
`FireServer` at `Weapon:11`; `Instance.new("RemoteEvent")` at `Main:5`.

| Check | What it finds | Why it matters to integrity | Default |
|---|---|---|---|
| `rawRemotes` | `:FireServer`, `:InvokeServer`, `:FireClient`, `:FireAllClients` in project scripts | Honest raw calls on Lync's remotes would raise `TagMismatch` false positives (CS §3.1). Raw remotes elsewhere are unbudgeted entry points outside `Suspicion` | warn |
| `foreignRemotes` | `Instance.new("RemoteEvent"/"UnreliableRemoteEvent"/"RemoteFunction")`, and remote instances in the tree (Rojo `--include-non-scripts`; the plugin walks the DataModel) | Lists every remote not owned by Lync as attack surface in the report | warn |
| `reachability` | definitions that no client script references | The server can treat a client block of such a definition as `Unreachable`; see below | report |
| `dynamicAccess` | a Lync view indexed with `[...]`, passed as a value, stored or returned | Turns reachability off for that namespace | warn |
| `unreliableSize` | an unreliable definition whose worst case exceeds the per-frame cap (L-7 minus the CS §3.2 sequence and tag) | Prevents silent drops of over 1000 B (landscape #5, Blink #108) | error |

**Reachability, done soundly.** The probe's rule (a `:fire` or `:invoke` right after `view.name`) is too narrow:
`local ev = Combat.hit; ev:fire()` would be missed and later flagged. The shipped rule must be:
- every `view.name` reference in client code counts as reachable;
- any escape of a client view or a namespace table, or any computed index of either, makes the namespace
  `incomplete`, and then nothing is inferred for it;
- packages under `Packages/` are analysed like project code;
- code not in the project (another place, an asset loaded at run time) is outside the guarantee, which the
  report states.

What reachability enables:
- **Inferred direction.** A `"both"` definition referenced only by server code is effectively server-to-client.
  The server shard records the inferred direction. It stays *out of* the HELLO hash, so a change in client code
  that alters an inference never turns into a handshake mismatch.
- **Auto-traps.** With `reachability = "enforce"`, a client block for an unreferenced definition is dropped and
  reported `Unreachable`, weight **Strong** (CS §6.1 scale). It is not Certain, because analysis gaps are this
  check's false-positive source. The developer makes it Certain by declaring the direction explicitly (CS §3.6).
- **Cost:** one table index on a definition the decoder already looked up. It is the same check as CS §3.6
  direction, folded together.
- **Limit:** an attacker who fires only definitions honest client code references (CS §1.4) never trips it.

### 4.3 How the server uses build facts, and what it cannot use

| Use | Mechanism | Strength |
|---|---|---|
| Build identity | build seed and core hash in the HELLO hash | Stale or foreign clients fail the handshake (W-208 class). An echoing attacker passes; this is about correctness |
| Unreachable and inferred direction | server shard tables | Strong signal (§4.2) |
| Worst-case sizes | server shard tables | Budget sizing; strict decode already rejects oversize blocks (CS §3.5) |
| **Not possible: attesting client scripts** | — | Game code cannot read `Source` (capability `PluginOrOpenCloud`, verified); no engine API hashes a running script; a client's self-report is attacker-controlled. *(corrects draft: "the game itself can compare" `getscripthash`)* |

### 4.4 The build report

`report.json` (machine) and `report.txt` (human), with the same content. The text form:

```
Lync 5.0.0 build  seed 7  (core sha256:3f1c…)  2 namespaces, 14 definitions, 4 shards
  ReplicatedStorage.Shared.Combat   client 5.1 KB  server 6.8 KB   reachability: incomplete (Dynamic:6)
    shoot      u  client→server  worst 22 B   ok
    adminGrant r  both           worst 13 B   not referenced by client code (inference off: namespace incomplete)
CHECKS
  error   unreliableSize   none
  warn    rawRemotes       FireServer at StarterPlayerScripts.Client.Weapon:11 (remote LegacyShop)
  warn    foreignRemotes   RemoteEvent created at ServerScriptService.Server.Main:5
  warn    dynamicAccess    StarterPlayerScripts.Client.Dynamic:6 indexes a Combat view with a computed key
ROTATION  field order: 3 records moved; tag constants: rotated; ids: runtime shuffle per server
COST      +0 B wire, +0 instructions (rotation); shards 11.9 KB source total; native: server shards
```

Every finding names a script path and line, the check's knob, and the fix.

---

## 5. Configuration surface

### 5.1 The split

| Kind | Where | Read by | Examples |
|---|---|---|---|
| Declarations | shared schema (Luau) | runtime, core | events, codecs, `:unreliable()` |
| Build-time knobs | `lync.toml` | core in every host | seed, rotation, sharding, checks, outputs |
| Runtime policy | server-only Luau API | server runtime; wire-shaping parts sent to the client in SESSION (CS §3.1) | tag width, replay window, shuffle mode, weights, traps |
| Behaviour | server Luau | server runtime | validators, handlers, `Lync.observe` reactions |
| Artefacts | JSON (and `report.txt`) | developers, CI, the plugin | manifest, report, debug map |

Integrity knobs are runtime, not TOML: the runtime-only path needs them without a build, they are server policy
that must never ship in shared code, and the client learns what it needs at the handshake.

The build reads none of them. Where a build-time computation depends on them (the `unreliableSize` cap), it
assumes the worst case allowed by their ranges: a 32-bit tag and a 16-bit sequence, 6 B.

### 5.2 `lync.toml`

This is the full sketch. It is valid against `config/lync.schema.json` (verified with Python jsonschema 4.26).

```toml
#:schema ./lync.schema.json
format = 1

[project]
sourcemap = "sourcemap.json"
namespaces = ["ReplicatedStorage.Shared.Combat"]
sharedOutput = "src/shared/LyncGenerated"
serverOutput = "src/serverGenerated"

[build]
seed = "release"

[generate]
shardBy = "namespace"
maxShardBytes = 65536
native = "server"
schemaLocations = true
types = ["luau", "dts"]

[rotate]
fieldOrder = true
tagConstants = true

[check]
rawRemotes = "error"
foreignRemotes = "warn"
unreliableSize = "error"
dynamicAccess = "warn"
reachability = "report"

[output]
report = "lync-build/report"
debugMap = "lync-build/debug.json"
```

| Knob | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `format` | integer | — | 1 | required | — |
| `project.sourcemap` | path | — | — | `"sourcemap.json"` | — |
| `project.namespaces` | array of instance paths | — | unique | `[]` = every module calling `Lync.namespace` | — |
| `project.sharedOutput` / `serverOutput` | path | — | must map to the fixed instance paths of §3.1 (checked via the sourcemap) | none: required with Rojo | — |
| `build.seed` | `"release"` or integer | — | 0 – 4294967295 | 0 | 0 is canonical. `"release"` draws a fresh seed and records it in the manifest; every build then changes shard bytes |
| `generate.shardBy` | enum | — | `"namespace"`, `"group"` | `"namespace"` | `"group"` adds an index module |
| `generate.maxShardBytes` | integer | bytes of source | 8192 – 1048576 | 65536 | smaller means more modules and requires |
| `generate.native` | enum | — | `"off"`, `"server"`, `"both"` | `"server"` | native compile time and memory where the host enables it |
| `generate.schemaLocations` | boolean | — | — | true | constant strings only; nothing on the success path |
| `generate.types` | array | — | `"luau"`, `"dts"` | `["luau"]` | build time |
| `rotate.fieldOrder` | boolean | — | — | true (inert at seed 0) | 0 instructions (§2.3) |
| `rotate.tagConstants` | boolean | — | — | true (inert at seed 0) | 0 instructions (§2.3) |
| `check.rawRemotes` | enum | — | `"off"`, `"warn"`, `"error"` | `"warn"` | build time |
| `check.foreignRemotes` | enum | — | same | `"warn"` | build time |
| `check.unreliableSize` | enum | — | same | `"error"` | build time |
| `check.dynamicAccess` | enum | — | same | `"warn"` | build time |
| `check.reachability` | enum | — | `"off"`, `"report"`, `"enforce"` | `"report"` | enforce: one table index per decoded client block |
| `output.report` | path prefix | — | outside mapped folders | `"lync-build/report"` | — |
| `output.debugMap` | path | — | outside mapped folders | `"lync-build/debug.json"` | — |

**Parsers: one text, three hosts.** Verified with `config/parity.py` and `parity.out`. The same `lync.toml` was
parsed by:
- Lute's `batteries/toml.luau` (1581 lines, pure Luau, no `require`), run by the plain `luau` 0.740 CLI, which is
  exactly what the plugin would vendor;
- smol-toml 1.9.1 on Node, for the transformer;
- Lune 0.11.0 `serde.decode("toml")`.

All three gave identical canonical JSON. Edge cases differ, and the JSON Schema forbids them:

| Input | toml.luau | smol-toml | Lune |
|---|---|---|---|
| `beyond = 9007199254740993` | `9007199254740992` (silent rounding) | **rejects the file**: "integer value cannot be represented losslessly" | `9007199254740992` |
| `date = 1979-05-27` | `"1979-05-27"` (string) | not reached | `{"$__toml_private_datetime": …}` |
| `wholeFloat = 1.0` | `1` (int/float distinction lost) | not reached | `1` |

So the schema bounds every integer to at most 2^32−1 and allows no datetimes.

`toml.luau` uses Luau's `const function` syntax (40 `const` sites). The local Luau parser accepts `const` without
a flag (verified, `Ast/src/Parser.cpp`), and darklua 0.19 parses it. Whether Roblox Studio's parser accepts
`const` today is **unverified**. If not, the vendored copy needs a mechanical `const` → `local` rewrite.

**Editor support.** Taplo and Even Better TOML read a header directive `#:schema ./lync.schema.json`. It must sit
at the top, preceded only by comments or other directives; relative paths resolve from the TOML file (documented,
[Taplo directives](https://taplo.tamasfe.dev/configuration/directives.html)).

**Studio-only users.** The TOML text lives in `ServerStorage.Lync.Config`, a StringValue. Because
`OpenStringValueDocumentAsync` is RobloxScriptSecurity (verified), the plugin edits it in its own widget and
validates it against the same schema embedded in the core. `Plugin:SetSetting` is per machine, so it holds no
config.

### 5.3 Runtime integrity policy: server-only Luau

This is the same surface as CS §7, as one call that throws when not on the server (A-148 decides the side):

```luau
-- ServerScriptService/Lync.server.luau
local Lync = require(ReplicatedStorage.Packages.Lync)
local Combat = Lync.server(require(ReplicatedStorage.Shared.Combat))

Lync.integrity({
	tag = { bits = 16, coverBytes = 1024, rounds = "1-3", lookahead = 4, desyncAfter = 8, rekeyInterval = 60 },
	replay = { seqBits = 12, window = 64, noise = 0.02 },
	replyMemory = 2048,
	shuffle = { ids = "server", fields = false },   -- fields: runtime path only (§2.4)
	directionCheck = true,
	clock = { beacon = 0, rateThreshold = 0.03, window = 60, confirm = 3, warmup = 30 },
	cadence = { jitter = 1, window = 10 },
	earlyReplyFactor = 0.5,
	signals = {
		weights = { Certain = 10, Strong = 4, Weak = 1 },
		scoreHalfLife = 600, perPlayerEvents = 16, serverEvents = 256,
	},
})
Combat.adminGrant:trap()                 -- CS §3.5; server view only
Lync.observe(function(event) --[[ the game's ladder, CS §6.3 ]] end)
```

- Units, ranges and costs are exactly those in CS §7. The names are grouped, not renamed.
- `shuffle.seed` (tests) stays on the seams (A-10), never in production config.
- The wire-shaping subset (tag bits, rounds, cover, sequence bits, shuffle mode and seed) reaches clients in
  SESSION. Nothing else leaves the server.

**Validation.** The call throws, naming the key, the value and the allowed range, in the A-117 style. A second
call replaces only the given keys. A change after the first player is admitted applies to new connections only,
because SESSION parameters are per connection.

### 5.4 Build-time validation

The CLI host validates `lync.toml` against the JSON Schema and then against cross-field rules. The plugin does
the same through the embedded schema. Errors print in the `[Lync]` style with the TOML key path:
- `[Lync] lync.toml: generate.maxShardBytes is 4096; it must be 8192 to 1048576.`
- `[Lync] lync.toml: project.sharedOutput "src/gen" is not mapped by default.project.json.`
- `[Lync] lync.toml: output.debugMap "src/shared/debug.json" is inside a mapped folder and would ship.`
- A warning when `rotate.*` is set and `seed = 0` (inert), so golden builds stay honest.

### 5.5 Report format

See §4.4. `report.json` holds the same data with stable keys, so CI can gate on `findings.*.level == "error"`.

### 5.6 Developer-only debug map

`debug.json` has, per namespace: seed, ids, field orders, tag constants, generated line → `{schemaFile, line,
definition, field}`, and the core version.

What it is for, honestly:
- **Not secrecy.** The shipped client shard already states the field order and constants, and a decompiler or
  `getconstants` reads them (§2.3). The map stays out of the game for size and tidiness, not secrecy.
- **Not live inspection in Studio.** The Studio inspector, during a play test, runs in the same DataModel as the
  shards and decodes with the shard's own decoders. It needs no map.
- **Offline decoding.** A frame captured from a live server, from a bug report or from telemetry needs the
  build's map plus that server's runtime shuffle seed. The server can log the seed to developer-only telemetry
  (CS §3.4). The map is also exactly reproducible from schema, seed and core version, so a lost map is rebuilt,
  not mourned.

Where it is kept: for Rojo users, `lync-build/debug.json`, gitignored and outside mapped folders (validated,
§5.4); for Studio-only users, nowhere, because the plugin recomputes it on demand from config and schema.

---

## 6. Distribution constraints

### 6.1 Creator Store

Documented, [Creator Store](https://create.roblox.com/docs/production/creator-store), fetched 2026-10-15. The
store restricts:
- "Obscuring engine features within scripts, including LuaVMs, `getfenv()`, and `setfenv()`";
- "Requiring remote assets", including `require(assetId)`, `loadstring()` and `ModuleScript.LinkedSource`;
- "Including obfuscated code" ("creators [must] understand what they are putting into their games");
- "unnecessarily large scripts, including multiple repeat lines or large strings that are unused".

It also says "you cannot distribute assets with Restricted dependencies that were not uploaded by you".

**Consequences:**
- Lync's runtime, the generated shards and the plugin must contain no `getfenv`, `setfenv`, `loadstring` or
  `require(assetId)`. CS §2.2 already bans `getfenv` for speed reasons.
- Generated output must stay readable (§2.1). A VM- or obfuscator-processed build cannot be distributed this way.
- Sharding under `maxShardBytes` keeps generated modules from being one huge file.
- A DevForum report says automated moderation once flagged `print("require")` as a false positive, since fixed
  (reported, [thread](https://devforum.roblox.com/t/automated-moderation-false-flags-the-script-printrequire-as-violating-community-standards/4051529)).
  Expect scanner noise on any script that mentions these names, even in strings.

### 6.2 Packaging generated versus runtime code

| Channel | Ships | Notes |
|---|---|---|
| Wally (`axp3cter/lync`, realm `shared`) | the runtime and the core (the runtime path uses the planner) | the current `packaging/wally.toml` uses `exclude = ["**"]` plus explicit `include` because "Wally 0.3.2 ships every file that no exclude matches" (verified, repo file) |
| pesde | the same, `environment = "roblox"` | `build_files` are passed to `roblox_sync_config_generator`; `bin` is allowed only for `luau`/`lune` targets (documented, [pesde manifest](https://docs.pesde.dev/reference/manifest/)). So pesde cannot install Lync's Rust CLI; the CLI comes from rokit |
| npm (`@rbxts/lync`) | the runtime, `index.d.ts`, and a Node shim for the transformer | the generator's `.d.ts` output is written into the user's `src`, never into the package |
| rokit | the CLI binary from GitHub releases | the repo already pins tools this way (`versions/one/rokit.toml`: `lune = "lune-org/lune@0.10.5"`, `rojo = "rojo-rbx/rojo@7.7.0"`, …) |
| Creator Store | the plugin (it vendors the core and `toml.luau`) and, optionally, a model of the runtime | §6.1 rules apply |

**Generated code is never published as a package.** It is per game, per build, and lives in the game's tree.
The core version that produced it is in the shard header and the manifest. A runtime from a different version
then refuses it through the hash check (§2.4) instead of misbehaving.

### 6.3 Licensing of generated output

Lync is MIT ("Copyright (c) 2026 Aspect", `versions/one/LICENSE`). Generated shards contain runtime-derived
templates, and MIT requires the notice "in all copies or substantial portions".

Recommendation:
- **A one-line header in every shard**, for example
  `-- Generated by Lync 5.0.0 (MIT, © 2026 Aspect, https://github.com/Axp3cter/Lync); edit lync.toml or the
  schema, not this file.` It costs nothing at run time: comments are not in the bytecode.
- **An explicit sentence in LICENSE** saying that generator output may be used under the user's own terms as
  long as the header stays, in the spirit of the Bison and GCC runtime exceptions. Whether the sentence is needed
  under MIT at all is a legal question (unverified; get a review).

`toml.luau` is Lute's (MIT, "Copyright (c) 2024–2025 Roblox Corporation"), so the vendored copy keeps that notice.

---

## Implications

Ranked by value for the decision; each row gives the vehicle, default, knobs and honest limit.

| # | Recommendation | Vehicle | Default | Knobs | Honest limit |
|---|---|---|---|---|---|
| 1 | Pure-Luau compiler core shared by CLI host, plugin and runtime planner (§1.1) | core | always | — | token-level lexer, not type-aware analysis |
| 2 | Schema-hash check with build seed in HELLO; fall back to the runtime path on mismatch (§2.4) | runtime | on | — | stale shards cost speed until regenerated; Studio cannot force it before publish |
| 3 | Client and server shards per namespace: readable, schema-located, deterministic, seed 0 canonical (§2.1, §2.2) | core via CLI or plugin | on when a build runs | `generate.*`, `build.seed` | 200-local, 255-register and native IR limits shape it; sharding handles them |
| 4 | CLI host in Rust on mlua (notify, toml, serde_json) via rokit; Lune as prototype and fallback (§1.2) | CLI | `lync build`, `lync watch` | — | host code is ours (a few hundred lines); Lune has no watch; Lute 1.0 still drifting |
| 5 | Build-time checks (§4.2) | core | `rawRemotes`/`foreignRemotes`/`dynamicAccess` warn, `unreliableSize` error | `check.*` | verifies the developer's code only; attacker code never passes a build |
| 6 | Reachability and inferred direction in the server shard; `Unreachable` as Strong suspicion (§4.2) | core + server runtime | `report`; `enforce` opt-in | `check.reachability` | incomplete namespaces infer nothing; attackers firing referenced definitions pass |
| 7 | Per-build rotation of field order and tag constants (§2.3) | core | on at nonzero seed; `seed = "release"` in CI | `rotate.*`, `build.seed` | zero cost, but only shortens static byte tooling's life to one release; Lync's encoder defeats it |
| 8 | `lync.toml` + JSON Schema (integers ≤ 2^32−1, no datetimes); Studio keeps the text in a ServerStorage StringValue (§5.2) | core, plugin, transformer | `format = 1` | §5.2 | Roblox acceptance of `const` in the vendored parser unverified |
| 9 | Integrity policy as one server-only `Lync.integrity{…}` mirroring CS §7; wire-shaping values in SESSION (§5.3) | runtime | CS §7 defaults | CS §7 | `shuffle.fields` ignored when generated code is present |
| 10 | Manifest, report (JSON + text), debug map, reproducible from schema, seed and core (§4.1, §4.4, §5.6) | core | every build | `output.*` | none attests running client code |
| 11 | Studio plugin: regenerate on edit, "Prepare release" seed, `UpdateSourceAsync` under one ChangeHistory recording, analysis callbacks (§1.4) | plugin | on | same `lync.toml` | no publish hook; needs Script Injection permission |
| 12 | Open Cloud publish from CI: `Saved` for staging, `Published` for release, 30/min per key owner (§1.8) | CI | documented pattern | — | Editable*, PartOperation, SurfaceAppearance, BaseWrap edits still need a Studio publish |
| 13 | Optional roblox-ts transformer for type-precise reachability and raw-remote checks (§1.7) | transformer | off; `.luau`/`.d.ts` need none | `lync.toml` via smol-toml | TS sources only |
| 14 | MIT header in every shard, plus a LICENSE sentence on generator output (§6.3) | core | on | — | needs legal review |

**Refuse**
- Spreading or inlining codecs into the game's own scripts: 5.0× bytecode, noisy diffs, and the batching queue
  stays central (§3.2).
- Per-player variant pools cloned through PlayerGui: a join-time dependency and per-player instances for what the
  per-session id shuffle already gives (§3.3).
- Any promise of per-client or per-server generated *code*: clients have no compiler, and server `loadstring`
  cannot produce client code (§3.4).
- Manifest self-attestation of client scripts: `Source` is `PluginOrOpenCloud`, and a client's report is
  attacker-controlled (§4.3).
- Obfuscation, VMs, `getfenv`/`setfenv` or `loadstring` in runtime, shards or plugin: Creator Store restrictions,
  and they break fast calls (§6.1, CS §2.2).
- darklua renaming as a "polymorphism" feature: not seedable, and local names are not shipped anyway (§1.5).
- Build-time definition-id rotation as a separate feature: subsumed by the runtime per-server shuffle (§2.3).
- luau-lsp plugins as a build or CI vehicle: editor-only and experimental (§1.6).
- Integrity policy in `lync.toml` or in shared modules: policy must not ship to clients, and the runtime path
  needs it without a build (§5.1).
