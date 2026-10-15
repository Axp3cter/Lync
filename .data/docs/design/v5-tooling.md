# Lync v5: compiler outputs and tools (milestones 3 and 6)

Draft 3.6, 2026-10-15. Part of the v5 design (`v5.md`); changes from draft 3.5 are in `v5-3.6-changes-tooling.md`.
Milestone 3 builds §1–§4 on the Lune host, except what a row marks for a later milestone; milestone 6 builds the
Rust/mlua host, weaving (§5), `lync check --published`, `diff`, `replay`, the Studio plugin, the inspector and the
profiler adapter (§6). A build code is raised from the milestone in its row of §3.4, under `v5.md` §7.1's deferral
rule.

## 1. Outputs

For one schema, one `lync.toml`, one generator and one pair (`buildId`, `rotationSeed`), the compiler always
produces the same files `[client-security-build §2.2]`. A build run draws that pair once for every namespace and
both sides (`v5-integrity.md` §2).

| Output | Format | Consumer | Reaches clients |
|---|---|---|---|
| client shard, server shard per namespace (§1.1) | Luau, readable, MIT header; each definition commented with its schema line | the game | the client shard |
| type declarations | `.d.ts`; JSDoc names each definition's schema line | roblox-ts | no |
| `manifest.json` (§1.2) | JSON, sorted keys, LF line endings | `lync check`, `lync weave`, `lync replay`, `lync diff`, the inspector's capture replay | no: it holds `rotationSeed` |
| `report.md` (§1.3) | Markdown rendered from the manifest | developers | no |

**Instance paths**, in every output and diagnostic, are the names from the service down joined by `.`, with a `.`
or `\` inside a name written `\.` or `\\`.

### 1.1 Shards

- **Line 1** mirrors the shard's identity for a reader and carries its digest `[build-checks §3.2]`:
  `-- Lync 5.0.0 | arena | client | part 1/1 | build 3735928559 | schema 0123456789abcdef | code <64 hex digits>`.
  `code` is SHA-256 over every byte after line 1, with CRLF replaced by LF first. Nothing reads identity from line
  1: an edit to line 1 alone is not detected (`build-checks/drift.out`), and it changes no behaviour.
- **Identity constants in the body**, as code the digest covers: generator version, `buildId`, seed-0 schema hash,
  schema path, namespace, side, part number and part count. `staleShard` and `unpairedShard` (§3.4) read these.
- **Parts.** A side whose source would exceed 200,000 bytes is split, by sorted definition name, into child modules
  `Part1` … `PartN` of the shard module, which requires them; each part has its own line 1 and digest. Derivation:
  `Source` set the ordinary way is capped at 200,000 characters (reported, `[generation-security §2.4]`; §8), and
  a character takes at least one byte.
- **Generator invariants**, each checked by compiling every part with the host's Luau compiler before anything is
  written; a failure is `internal` (exit 3): at most 200 locals and 200 upvalues per function, fewer than 32,768
  closures per function prototype (`kMaxClosureCount`), definitions held in a table, each with its own functions
  `[generation-security §4.2]`. Server parts should also stay under 1,048,576 native IR instructions per module
  (`CodegenHeuristicsInstructionLimit`; Roblox's value unverified), past which functions are left interpreted, not
  refused `[client-security-build §2.1]`. No host is verified to report that count (§8), so until one is, the
  200,000-byte part cap is the only bound on a server part.
- **Native code.** Server parts begin with `--!native`; client parts carry no native directive. Roblox documents
  native code for servers only, and its clients run interpreted (reported, 2026) `[generation-security §4.1]`, so a
  client directive gains nothing and a server part without one loses native decode. There is no option.
- **Names.** Generated functions keep readable names, never per-build or anonymous ones: view keys, the shard's path
  and `require` give every tool a stable route, so per-build names price nothing `[refusals-rejudged-1 R10]`.
- **Types.** Generated Luau types use no `read` modifiers, which the old solver rejects (`v5.md` §3.2). Generated
  trap definitions are in the runtime table and absent from exported Luau and `.d.ts` types
  `[generation-methods M15a]`.
- **Decision: generated trap names** (`build.traps`, `v5-integrity.md` §3).
  - *Problem.* A trap must sit in the runtime table under a name, since the drivers it prices browse the namespace
    and fire what they find; a name a reader can tell from the real ones at a glance removes it.
  - *Options:* random strings (separable at a glance); a word list shipped with Lync (the same words in every game,
    so separable by the list); **names composed from the namespace's own name tokens.**
  - *Choice: own tokens.* Each definition name of the namespace is cut at every lowercase-to-uppercase and every
    letter-to-digit boundary, and the pieces are lowercased; V is the set of distinct pieces. The candidates are
    every piece and every ordered pair of different pieces written as the first followed by the second with its
    first letter uppercased, minus the namespace's definition names, sorted bytewise. Trap k (1 … T) takes the
    candidate at index (x mod the number of candidates left), without replacement, where x is the first xorshift32
    output seeded with the low 32 bits of HalfSipHash-2-4 keyed by `rotationSeed` over `trap:<namespace>:<k>` (0
    replaced by `0x9E3779B9`, as in `v5-integrity.md` §2). With fewer candidates than T the build makes one trap per
    candidate and reports `trapNamesShort`. Whether a reader can separate such names from real ones is unverified
    `[generation-methods M15a]`.

### 1.2 Manifest

| Field | Content |
|---|---|
| `format` | 1 |
| `generator` | `lync` (version) and `coreDigest` (SHA-256 of the compiler core that generated the build): the generator identity, for reproducibility. A shard's `code` digest (§1.1) is a different value, for drift |
| `buildId`, `rotationSeed` | the run's public build id (u32) and private rotation seed (16 hex digits) `[generation-methods M1]` |
| `rotation` | each value `v5-integrity.md` §2 draws from `rotationSeed` that sets a run-time cost (the tag's compression and finalization rounds, the rotation-set index), so the report states the build's cost without running the planner |
| `namespaces.<name>` | `schemaPath`; `schemaHash` (seed 0); `ids` (canonical order to wire id, both spaces); `idTableHash` (§5.5); `shards.client` and `shards.server`, one `{ part, path, digest, wovenDigest? }` per part; `reachability` (`"complete"`, or `"incomplete"` with its `dynamicAccess` sites `{ uri, line, col, kind }`); `traps` (generated names); per definition `{ line, worstCase, reachable?, closed?, openReason?, sites? }` (`sites` and `closed` from §5) |
| `foreignRemotes`, `remoteCreations` | the `foreignRemote` and `remoteCreation` entries of §3.4 with their evidence, sorted by path, written whenever those checks run |
| `scripts` | the client scan set (§3.3): `{ path, digest }`, SHA-256 over LF-normalised `Source`, read from the place with `--place`, else from the files the sourcemap maps `[refusals-rejudged-1 R11]` |
| `wovenScripts` | `{ path, digest }` of each built copy `lync weave` rewrote (§5) |
| `streaming` | the place's `StreamingEnabled`, `StreamingTargetRadius`, `StreamingMinRadius`, `StreamOutBehavior`, `ModelStreamingBehavior` and the place file, when a place was read `[interest-rewind §12.3]` |
| `decoyReview` | each (definition, field, collection) where `:refers` meets `:decoys`, with the scripts of the client scan set that name the definition `[decoy-challenge-facts §3]` |

`lync build` and `lync watch` write it; `lync weave` rewrites it with the same `buildId`, adding the weave fields.
It must never ship, since it holds `rotationSeed`: an `[output] manifest` path inside a folder the sourcemap maps
into the place is `configRange`. Studio-only projects keep it in `ServerStorage.Lync.Manifest`, a `StringValue`
(never replicated; whether a `StringValue` holds a manifest of that size is unverified, §8).

**Decision: no debug map.**
- *Problem.* Offline decoding (`lync replay`, a capture in the inspector, `lync diff`) needs each layout. Under
  `v5-integrity.md` §2 the public `buildId` no longer determines it, and the session key derives from a per-build
  secret, so a captured `HELLO` and `WELCOME` no longer suffice `[generation-methods M1]`.
- *Options:* a separate debug map per build `[client-security-build §5.6]`, holding values the manifest already
  holds; **the manifest.**
- *Choice: the manifest.* The planner reproduces every layout and key from schema, `rotationSeed` and the capture's
  `WELCOME`; CI keeps each release's manifest as an artefact `[build-checks Impl14]`.

### 1.3 `report.md`

Rendered from the manifest; it never contains `rotationSeed`. Per namespace: shard sizes; per definition its
worst-case size, reachability, closed or open with the first open reason, and woven site count; the generated trap
names; the `dynamicAccess` sites. Per build: the `rotation` values with the per-frame cost each sets
(`v5-integrity.md` §2); the `foreignRemotes` and `remoteCreations` tables, with one line stating that engine entry
points other than remotes (`ClickDetector`, `ProximityPrompt`, `Tool` activation, physics ownership) are not listed
`[build-checks §1.1]`; the `decoyReview` list; the `streaming` settings; the count of diagnostics per code.

## 2. `lync.toml`

TOML with a published JSON Schema, read the same way by the CLI and the plugin `[client-security-build §5]`. It is
build-only and ships to no client. Studio-only projects keep the same text in `ServerStorage.Lync.Config`, a
`StringValue` the plugin edits in its own widget.

```toml
#:schema https://lync.dev/schema/lync.toml.json
format = 1

[project]
sourcemap = "sourcemap.json"    # rojo sourcemap --include-non-scripts output

[build]
seed = "release"                # v5-integrity.md §2

[[namespace]]
schema = "src/shared/Net/schema.luau"
client = "src/shared/Net/client"
server = "src/server/Net"
dts = "types/net.d.ts"          # optional

[check]
reachability = true             # v5-integrity.md §3
clientRoots = []                # v5-integrity.md §3
knownRemotes = ["ReplicatedStorage.Remotes.LegacyShop"]
rawRemote = "warn"              # any code of §3.4 with a [check] severity, by its own name

[output]
manifest = "build/lync-manifest.json"
report = "build/lync-report.md"
```

**Keys defined here.** Every path is relative to `lync.toml`; every instance path is written as in §1.

| Key | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `format` | integer | — | 1 | required | — |
| `project.sourcemap` | path to the JSON that `rojo sourcemap --include-non-scripts` writes | — | — | `"sourcemap.json"` | one JSON read per run; required (absent file: `configMissing`) whenever a check that maps files to instance paths runs and no `--place` is given (§3.3); a scripts-only sourcemap omits non-script instances, so `foreignRemote` sees none from it `[build-checks §1.3]` |
| `namespace.schema` | path to the schema module | — | — | required | — |
| `namespace.client`, `namespace.server` | path of each side's shard module | — | distinct paths | required | — |
| `namespace.dts` | path | — | — | none: no `.d.ts` | one file per namespace |
| `namespace.staged` | boolean | — | — | `false` | `true`: the namespace's `schema` and `client` must map under `ServerStorage` (`stagedReplicated`, §3.4); one more namespace index in the segment toc after `Lync.release` `[interest-rewind §12.3]` |
| `staged.paths` (`[[staged]]`) | array of instance paths | — | — | `[]` | one container lookup per path per run |
| `staged.loader` (`[[staged]]`) | instance path of a release folder | — | — | none | exempts references to that path from `stagedReferenced` |
| `pvs.place` (`[[pvs]]`) | path to a built `.rbxl` | — | — | required in each entry | one place read per bake `[interest-rewind §10]` |
| `pvs.cell` | integer | studs | 8–256 | 32 (chosen: 1,024 cells on a 1,024-stud square map) | N = (map side / `cell`)² cells; a table of N²/8 B: 128 KiB at 1,024 cells |
| `pvs.samples` | integer | rays per axis per cell | 1–4 | 2 (chosen) | `samples`⁴ rays per cell pair: 0.17 s at 1, 2.16 s at 2 for 1,024 cells on the measured map `[interest-rewind §4.2]` |
| `pvs.output` | path of a server-only module (a module, not a data store value: a data store read at start would make Lync's start yield) | — | must map under `ServerStorage` or `ServerScriptService` (else `configRange`) | required in each entry | the table's size × 4/3 (base64) in the place |
| `check.knownRemotes` | array of instance paths; `*` matches one path segment | — | — | `[]` | none; a listed `foreignRemote` entry keeps its manifest row and gets no Diagnostic |
| `check.<code>` | `"off"` \| `"warn"` \| `"error"` | — | one key per code marked `[check]` in §3.4 | per code, §3.4 | `"off"` stops that check: no Diagnostic and no manifest entry of that code; computations another product reads still run (§3.2) |
| `output.manifest` | path | — | outside every folder the sourcemap maps into the place (else `configRange`) | `"build/lync-manifest.json"` | — |
| `output.report` | path | — | — | `"build/lync-report.md"` | — |

**Keys defined elsewhere**, by the section that states their meaning and cost: `build.seed`, `build.offsets`,
`build.tagRounds`, `build.playerVariants`, `build.playerVariantScope` (`v5-integrity.md` §2); `build.traps`,
`check.reachability`, `check.clientRoots` (`v5-integrity.md` §3); `weave.*` (§5.7). Every value the generator draws
per build sits in `[build]`, so per-player variants are `build.playerVariants` and `build.playerVariantScope`, not a
`[variants]` table of one key `[generation-methods M7]` `[interest-rewind §13.4]`.

**Validation.** The CLI and the plugin check the text against the JSON Schema, then each range above, including
ranges that name another key or the sourcemap; findings are the `config*` codes of §3.4. The schema bounds every
integer to 0–2^32 − 1 and allows no datetimes, where TOML parsers disagree `[client-security-build §5.2]`. The
vendored TOML parser uses no `const`, whose availability in Studio scripts is unverified.

## 3. Build diagnostics

### 3.1 Structure and renderings

- **One structure, the LSP `Diagnostic`** `[diagnostics §6.1]`: `range`, `severity`, `code` (the registry code of
  `v5.md` §7.1), `codeDescription.href` (`https://lync.dev/codes/<code>`), `message`, `source = "lync"`,
  `relatedInformation`, and `data` holding the evidence of §3.4. Positions come from the line each schema
  constructor records; columns by searching that line for the option key or codec name. A finding on an instance
  with no file (place-only content) takes the place file's `uri`, range 0:0, and `data.instance`.
- **Renderings**, `--format`:
  - `human` (default): `error[unknownOption]: arena.chat has no option "rtae"`, the `-->` location, the source line
    with a caret, `= help:` when there is exactly one fix, and `run lync explain <code>` once per distinct code;
  - `json`: JSON Lines, one Diagnostic plus `uri` per line (it streams under `watch`);
  - `github`: `::error file=…,line=…,col=…,title=lync <code>::<message>`, plus the human report in
    `$GITHUB_STEP_SUMMARY`, since Actions shows at most 10 annotations per step.

  SARIF is not built: it would be a fourth renderer to maintain and golden-test, for GitHub code scanning, whose
  annotations the `github` format already gives in Actions.

### 3.2 Severity

- **Effect.** An `error` makes `lync build`, `lync watch` and `lync weave` write no outputs and `lync check` exit 1;
  a `warning` changes neither.
- **One code per trigger whose fix or setting differs.** Triggers that share both share a code, with an evidence
  field naming which one fired and the known causes listed per value (`dynamicAccess` `kind`, `editedShard`
  `regenerated`).
- **Fixed severities**, for codes where no setting makes the finding right or wrong: declaration codes, the
  configuration and environment codes, `staleShard`, `editedShard`, `unpairedShard` and the first three
  `published*` codes are errors; `staleManifest`, `trapsIncomplete`, `trapNamesShort` and `publishedScriptChanged`
  are warnings. Each is a mistake in the configuration, a failure of the environment, a mismatch between artefacts
  of one build, or a statement of what the build made against what the configuration asked `[build-checks §3.5]`.
- **`[check]` severities**, for every other code: `check.<code>` takes `"off"`, `"warn"` or `"error"`. Its default
  follows one rule: `"error"` when no known cause in an unmodified game is correct code; `"warn"` when some known
  cause is correct code; `"off"` for `foreignBindable` alone, whose trigger names nothing that carries traffic
  between a client and the server. `"off"` stops the check: no Diagnostic and no manifest entry of that code.
  Computations that another product reads still run: `check.dynamicAccess = "off"` leaves the namespace
  incomplete.

### 3.3 Scans

- **One lexer pass** per run: the core's token-level, pure-Luau lexer, in every host, so the CLI and the plugin
  compute the same sets and the server shard's reachability lists don't depend on the host. A parser-based rule in
  the Rust host could qualify callees by module and drop some `dynamicAccess` sites `[build-checks §2.5]`; it is not
  used, since two hosts would then write different shards for one project. Comments are not scanned; string
  literals are. Throughput, detector included: 11.0–12.3 MB/s interpreted, 19.4–20.1 MB/s native (Luau 0.742 CLI),
  6.9–14.3 MB/s inside Lune `[build-checks §2.6]`.
- **Script sets.**
  - *Client scan set:* `v5-integrity.md` §3's (scripts in replicating containers, `Packages/`, every `LocalScript`,
    every `Script` with `RunContext = Client`, the scripts under `check.clientRoots`).
  - *All scripts:* every script in the place.
  - Both exclude Lync's own package (the subtree of any `ModuleScript` whose first line is
    `-- Lync <version> runtime`) and Lync's outputs (shards, the PVS module).
- **Namespace values** (for `dynamicAccess`, reachability, the caller probe's source lists, weave closure and trap
  placement): the result of a `require` or `TS.import` whose static path matches the client shard's full instance
  path suffix, never its leaf name alone, since `client` is a common module name `[build-checks §2.3]`; followed
  through aliases, fields, module returns and same-named function parameters (`v5-integrity.md` §3). The
  incompleteness predicate is computed once per run and every reader takes the same set.
- **Inputs.**
  - *CLI over files:* the script files and `project.sourcemap` for their instance paths and containers, plus
    non-script instances when the sourcemap includes them.
  - *CLI with `--place <file>`:* the built place through rbx-dom (`rbx_binary` in the Rust host, `@lune/roblox` in
    Lune), which replaces the sourcemap and the files for every check of that run; it also holds instances Rojo
    doesn't manage only if the place was downloaded.
  - *Studio plugin:* `game:GetDescendants()` of the edit DataModel; in a play test, of the play-test server
    DataModel (§4.2).

### 3.4 Codes

Every build code, with its exact trigger, its evidence (`data`), its severity (§3.2), its known causes in an
unmodified game, and the milestone that raises it (M).

**Configuration and environment** (exit 2):

| Code | Exact trigger | Evidence | Severity | Known causes | M |
|---|---|---|---|---|---|
| `configSyntax` | `lync.toml` text that doesn't parse as TOML | `line`, `col` | error | a mistake in `lync.toml` | 3 |
| `configUnknownKey` | a key the JSON Schema of `lync.toml` doesn't define | key path | error | a misspelled key; a key removed in this version (`[types]` in draft 3.6) | 3 |
| `configType` | a value of the wrong type | key path, expected type | error | a mistake in `lync.toml` | 3 |
| `configRange` | a value outside its range in §2 or §5.7, including an unsupported `format` and a range that names another key or the sourcemap | key path, the range | error | a mistake in `lync.toml`; a sourcemap that now maps `output.manifest`'s folder | 3 |
| `configMissing` | no `lync.toml` and no `ServerStorage.Lync.Config`; a required key or table absent (such as `[[namespace]]`); a required file absent (`project.sourcemap` under §2's condition) | key path or file | error | a fresh project; a sourcemap not generated before the run | 3 |
| `cloudRequestFailed` | an Open Cloud request of `lync check --published` answered with a status outside 200–299 | `endpoint`, `status` | error | an API key without scope `universe.place.luau-execution-session:write`; an exhausted rate limit (5 task creations per minute per key owner) | 6 |
| `cloudTaskFailed` | the Luau Execution task ended in a state other than `COMPLETE` | `state` | error | a place whose listed scripts take the task past its 5-minute limit | 6 |
| `publishedUnreadable` | the task's read of a listed script's `Source` raised | `path`, `error` (the raised text) | error | a task thread without capability `PluginOrOpenCloud` (unverified, §8) | 6 |

**Shards and manifest:**

| Code | Exact trigger | Evidence | Severity | Known causes | M |
|---|---|---|---|---|---|
| `staleShard` | a shard part's seed-0 schema hash differs from the live schema's | `side`, `part` | error | the schema edited and not rebuilt | 3 |
| `editedShard` | a part's recomputed digest differs from the digest on its line 1 (`regenerated` 0); or, with the manifest present and the running generator's `coreDigest` equal to the manifest's, regenerating the part at the manifest's `rotationSeed` gives another digest (`regenerated` 1) | `side`, `part`, `regenerated` | error; `lync build` and `lync watch` overwrite nothing while it holds | a formatter over generated files (StyLua, format-on-save); a darklua pass over shards; a merge resolved by hand; Team Create "Merge From Server" on a drafted shard. Not a CRLF checkout (normalised) `[build-checks §3.3]` | 3 |
| `unpairedShard` | the parts of a namespace's client and server shards don't all carry one `buildId`, one generator version and one schema hash in their bodies, or a part the shard module's part count names is absent | `clientBuild`, `serverBuild`, `generatorDiffers`, `schemaDiffers`, `missingPart` (0, or the part number) | error | one side committed and not the other (Team Create Drafts commits per script); a partial checkout; a plugin write refused for one script (Script Injection denial, `UpdateSourceAsync` rejection); a stale copy in a place Rojo only partly manages | 3 |
| `staleManifest` | the manifest records a `buildId` or part digests other than the shards' (`wovenDigest` for a place `lync weave` wrote, `digest` elsewhere) | `side`, `part` | warning | the manifest not kept with the shards (not committed, or from another CI run) | 3 |

`lync check` runs the regeneration whenever the manifest is present and the generators match, at the cost of one
generation run (planner and codegen, measured in milestone 3); with another generator it skips it and the summary
says so. The no-build path has no shards and no manifest, so none of these codes applies to it.

**Scans:**

| Code | Exact trigger | Evidence | Severity | Known causes | M |
|---|---|---|---|---|---|
| `rawRemote` | a method call `:FireServer(`, `:InvokeServer(`, `:FireClient(`, `:FireAllClients(` or `:InvokeClient(` in any script of the all-scripts set | `method` | `[check]`, `"warn"` | the game's own remotes; packages firing their own remotes (Knit, Cmdr); a raw call on Lync's own remotes, which then fails the tag (`tagMismatch`) | 3 |
| `foreignRemote` | an instance of class `RemoteEvent`, `UnreliableRemoteEvent` or `RemoteFunction` anywhere in the place, except exactly `ReplicatedStorage.Lync.Reliable` of class `RemoteEvent` and `ReplicatedStorage.Lync.Unreliable` of class `UnreliableRemoteEvent` (a same-named instance of another class is listed); not raised for paths in `check.knownRemotes` | `class`, `instance`, `replicates` (1 when its top-level service replicates to clients, 0 for `ServerScriptService` and `ServerStorage`), `runtime` (1 when found by the plugin's play-test walk) | `[check]`, `"warn"` | the game's own remotes from before Lync or kept on purpose; a Toolbox model or gear carrying a remote inside a `Tool`; a remote in `ServerStorage` that game code clones into a replicated container (`replicates` 0); remotes frameworks and the legacy chat system create at run time (`runtime` 1) `[build-checks §1.5]` | 3; `runtime` 6 |
| `remoteCreation` | in the all-scripts set, `Instance.new(` whose first argument is one string literal naming one of `foreignRemote`'s classes (`literal` 1), or is not a string literal (`literal` 0) | `class` (empty when `literal` 0), `literal` | `[check]`, `"warn"` | Knit's Comm (`literal` 1); Cmdr's helper `Instance.new(className)` (`literal` 0); forked legacy chat scripts; a `literal` 0 site whose helper creates only other classes `[build-checks §1.2]` | 3 |
| `foreignBindable` | an instance of class `BindableEvent` or `BindableFunction` anywhere in the place | `class`, `instance`, `replicates` | `[check]`, `"off"` | every bindable is game code's own signal; a client fires only its own, never the server's `[build-checks §1.2]` | 3 |
| `dynamicAccess` | in the client scan set, a dynamic access of a namespace value as `v5-integrity.md` §3 defines it: `kind` 1 an index whose key is not one string literal, 2 iteration (`for … in`, `pairs`, `ipairs`, `next`), 3 a hand-off the scan cannot follow by name | `namespace`, `kind`, `binding` (uri and range of the binding source) | `[check]`, `"warn"`; severity only, never whether the namespace is incomplete, and no per-site suppression (`check.reachability = false` is the opt-out) | kind 1: a generic helper `Net[name]:fire(v)`; kind 2: a client loop connecting every event, even one that fires nothing; kind 3: a framework registering the namespace with package code the scan has no definition for; any kind: following by name, which binds the parameter of every same-named function (`X.new(Net)` binds the first parameter of every `new`) and follows shadowing locals `[build-checks §2.5]` | 5 |
| `trapsIncomplete` | `build.traps` > 0 for a namespace that is incomplete: no trap is generated for it | `namespace`, `requested` | warning | any `dynamicAccess` cause | 5 |
| `trapNamesShort` | a complete namespace with fewer trap-name candidates (§1.1) than `build.traps` | `namespace`, `requested`, `generated` | warning | a namespace whose names yield fewer candidates than requested: one definition `chat` gives none, `buy` and `chat` give 2 | 5 |
| `solverOff` | each call site of `Lync.server(` or `Lync.client(` in the all-scripts set | — | `[check]`, `"warn"` | runtime-path code under the old solver, the default in Roblox and luau-lsp, where its types degrade to error types; a project on the new solver, whose setting no tool can read (`NotScriptable`, `v5.md` §3.2), which sets `check.solverOff = "off"` | 3 |
| `freeFormField` | in a client-sent payload (`data` of `from = "client"` events and requests, `reply` of `from = "server"` requests), walked depth first in name order through records, `t.optional`, array elements, map keys and values, union variants, `t.convert`'s base and `t.cframe`'s position codec, a leaf with no `:claim()` or `:input()` on itself or an enclosing codec that is `t.f32`, `t.f64`, `t.vector3f32`, `t.int()`, `t.int(min, max)` with max − min + 1 > 65,536, `t.number` or `t.vector3` with more than 65,536 codes per component, `t.string`, `t.buffer`, `t.instance` or `t.custom` | field path, the leaf's code count; range at the definition's schema line | `[check]`, `"warn"` | chat and other free text, names and search strings, fine settings sliders, cosmetic camera or UI coordinates: each takes one `:input()`. The 65,536 is a constant, chosen: below it every input of `v5.md` §3.4 and the measured demo inputs (255-code sticks, enums, slot indices), above it ids, currency up to 10^6 and fine positions `[checks-telemetry C5]` | 3 |
| `decoyRef` | a collection C with a `.C:decoys(` call in the all-scripts set; a leaf of a client-sent payload, walked as `freeFormField` walks it, whose codec serialises (`v5.md` §4.7) identically to C's `key` codec; and no `:refers("<top-level field>", "C")` for that definition and field | field path, collection, `declarable` (0 when the path is not a top-level key, optional key or array of keys, and the message names `reportInteraction`) | `[check]`, `"warn"` | a field that shares the key codec but isn't a key (a `t.int(1, 2^40)` score beside `UserId` keys); a key left undeclared on purpose (a player naming its own record, never a decoy) `[decoy-challenge-facts §3]` | 5 |
| `unscopedRef` | a server-sent event or request whose `data` holds a field whose codec serialises identically to some collection's `key` codec, with no `:about("<field>", …)` call on that definition in the all-scripts set | field path, collection; range at the definition's schema line | `[check]`, `"warn"` | a field that shares the codec but isn't a key; an event sent to every viewer on purpose `[interest-rewind §8]` | 4 |
| `stagedReplicated` | a staged namespace's `schema` or `client` path, or a `[[staged]] paths` entry, maps to `ReplicatedStorage`, `ReplicatedFirst`, `Workspace`, `StarterGui`, `StarterPack` or `StarterPlayer` | namespace or path, container | `[check]`, `"error"` | none: the declaration says server-only | 3 |
| `stagedReferenced` | a script of the client scan set, or a released namespace's schema, contains as a path expression or string literal the instance path of a staged namespace's `schema` or `client` module or of a `[[staged]] paths` entry, or a `require` that resolves to one, other than through a `[[staged]] loader` path | namespace, path | `[check]`, `"error"` | none outside the loader exemption | 3 |
| `stagedNameLeak` | a definition name, field name, union variant or enum item of a staged namespace, at least 4 bytes long, occurs byte for byte as a string literal in a released namespace's schema or a script of the client scan set | the string | `[check]`, `"warn"` | a common word ("level") used in both; only the game knows whether it leaks `[interest-rewind §12.3]` | 3 |
| `streamingOff` | the place read with `--place` has `Workspace.StreamingEnabled = false`, and the project has a staged namespace or an `:interest(` call in the all-scripts set | place path | `[check]`, `"warn"` | a game that streams nothing on purpose; with streaming off, all of `Workspace` reaches every client at join, whatever `interest` withholds `[interest-rewind §12.1]` | 3 |

**Weaving** (§5; each at its site's line, or line 1 of its script):

| Code | Exact trigger | Evidence | Severity | Known causes | M |
|---|---|---|---|---|---|
| `weaveNotStatement` | a resolved site (§5.3) in expression context, such as `local r = Net.buy:invoke(…)` | definition | `[check]`, `"warn"` | every request (`invoke` yields and returns a result); a `fire` whose value is used | 6 |
| `weaveArgument` | a resolved site of a record definition whose argument is not a table constructor | definition | `[check]`, `"warn"` | a payload built elsewhere and passed by name; a roblox-ts spread | 6 |
| `weaveKeys` | a resolved site whose table constructor's keys are not exactly the record's field set, or not all constant strings | definition, the differing key | `[check]`, `"warn"` | an optional field left out; a computed key | 6 |
| `weaveShadowed` | a local named `type`, `math`, `buffer`, `vector` or with prefix `__lync_` in scope at a resolved site | definition, the name | `[check]`, `"warn"` | a game local named `type` or `vector` | 6 |
| `weaveCompile` | a woven script that fails to compile; the script stays unwoven | script, compiler message | `[check]`, `"warn"` | woven imports pushing a function past 200 locals or 200 upvalues `[generation-security §4.2]` | 6 |
| `weaveUnparsed` | a script the Luau parser, at the version the host pins, refuses; it stays unwoven | script, parser message | `[check]`, `"warn"` | syntax newer than the pinned parser | 6 |
| `weaveLiteralRefused` | with `weave.literals`, a literal site whose constant the codec refuses; the site stays unwoven and throws `valueRefused` when it runs, as unwoven | definition, field path, the value | `[check]`, `"warn"` | the call in code that never runs | 6 |

**Published place** (`lync check --published`, §4.3; `[refusals-rejudged-1 R11]`):

| Code | Exact trigger | Evidence | Severity | Known causes | M |
|---|---|---|---|---|---|
| `publishedShardDiffers` | a shard part in the published version whose `Source` digest differs from the manifest's (`wovenDigest` when present, else `digest`) | `path`, `part`, `expectedBuild`, `foundBuild` (the body's `buildId`) | error | a Studio publish after the plugin regenerated shards; a hand edit published from Studio; the manifest of another CI run passed to the check | 6 |
| `publishedShardMissing` | a shard part the manifest lists, absent at its path in the published version | `path`, `part` | error | a Studio publish from a place copy without it; a shard moved after the build | 6 |
| `publishedWovenDiffers` | a script in `wovenScripts` whose published `Source` digest differs from the manifest's | `path` | error | a Studio publish, which carries the developer's unwoven source | 6 |
| `publishedScriptChanged` | a script of the client scan set that Lync didn't write whose digest differs from `scripts`, or that is new or absent | `path`, `change` (1 changed, 2 added, 3 removed) | warning | any edit published after the CI build; this is the developer's own code | 6 |

### 3.5 Exit codes

0 no errors; 1 one or more errors outside exit 2's codes; 2 usage (an unknown command, flag or argument, printed as
plain text) or a configuration or environment code; 3 `internal`, a Lync bug (a failed generator invariant, a woven
script whose line count changed, a woven site failing the differential, §5.4), printed with a request to file an
issue.

## 4. Hosts

### 4.1 CLI

| Command | What it does | M |
|---|---|---|
| `lync build [--place <file>]` | draws one (`buildId`, `rotationSeed`) and plans every namespace once with it; writes shards, `.d.ts`, the manifest and the report; runs every check of §3.4 except `staleShard`, `unpairedShard`, `staleManifest` (it rewrites all three artefacts), the weaving codes and the `published*` codes, and runs `editedShard` before overwriting; runs each `[[pvs]]` bake | 3; bakes 4 |
| `lync watch` | `lync build` again on each change to `lync.toml`, a schema module, the sourcemap or a scanned script; under `build.seed = "release"` each rebuild draws a new pair | 3 |
| `lync check [--place <file>] [--published <universe>/<place>[/<version>]] [--manifest <path>]` | every check of `lync build` plus the drift codes, writing nothing; with `--published`, the published-place codes | 3; `--published` 6 |
| `lync explain <code>` | prints the code's registry page | 3 |
| `lync weave <place> -o <file> [--manifest <path>]` | §5 | 6 |
| `lync diff <old> <new>` | compares two manifests and lists each definition whose wire changed: ids, codecs, layout | 6 |
| `lync replay <capture> [--manifest <path>]` | decodes a capture (its frames with their `HELLO` and `WELCOME`) using the layouts and keys the planner reproduces from the manifest (§1.2) | 6 |

`--manifest` defaults to `output.manifest`. `watch` is in milestone 3 because, outside Studio-only projects, it is
the only regenerate-on-edit path.

- **Host.** The shipped host is a Rust binary on mlua, installed with rokit; Lune is the fallback and the first
  host. Weaving needs the Rust host: it parses with Luau's own parser through a C++ shim, which Lune lacks
  `[codecs-in-scripts §2]`. Lute 1.0 is not used: its latest release has no macOS x86_64 binary, and its module paths
  differ from its own documented definitions (`@lute/crypto` against `@std/crypto`, a CST node's field `token`
  against `value`) `[client-security-build §1.2]`.
- **Entropy.** The Rust host draws `buildId` and `rotationSeed` from OS entropy (`getrandom`)
  `[security-tooling §6]`, never from a clock-seeded generator, which is searchable from the build's approximate
  time `[generation-methods M1]`. No OS entropy source in Lune is verified (§8); until one is, builds
  from the Lune host have a public-quality `rotationSeed`, as Studio-only builds do (§4.2).
- **Decision: how a run names the built place.**
  - *Problem.* Foreign remotes in the tree, staged-path mapping, the streaming settings and the `scripts` inventory
    need the built place, which exists only after `rojo build`, so on a developer's machine it is often absent.
  - *Options:* a `[check] place` key `[interest-rewind §12.3]` (a missing file fails every local run, or is skipped
    silently); **a `--place <file>` flag** `[build-checks Impl4]`; both (two ways).
  - *Choice: the flag,* on `lync build` and `lync check`. CI passes it after `rojo build`; a local run without it
    reads the sourcemap. `[[pvs]] place` stays a key: it names a map source per bake, not the place being checked.

### 4.2 Studio plugin (milestone 6)

- **Diagnostics** through `ScriptEditorService:RegisterScriptAnalysisCallback` (PluginSecurity), with `code` and
  `href`, attached to scripts only; instance findings (`foreignRemote`, `foreignBindable`) appear in the plugin's
  own widget `[build-checks §1.3]`.
- **Drift.** `staleShard`, `editedShard` and `unpairedShard` on open, on `TextDocumentDidChange` of a shard and in
  "Prepare release", hashing `Source` with `EncodingService:ComputeStringHash(source, Enum.HashAlgorithm.Sha256)`
  (security None, thread-safe) `[build-checks §3.4]`; its speed in Studio is unmeasured (§8).
- **Generation.** It regenerates on schema edit only when the configuration lives in `ServerStorage.Lync.Config`;
  with a filesystem `lync.toml`, `lync watch` is the one writer. Shards are written with `UpdateSourceAsync` inside
  one `ChangeHistoryService` recording `[security-tooling §3]`.
- **"Prepare release"** draws a new `buildId` and `rotationSeed` from `HttpService:GenerateGUID()` (security None),
  regenerates, and writes the manifest to `ServerStorage.Lync.Manifest`. The GUID's entropy source is undocumented,
  so Studio-only builds have a public-quality `rotationSeed` until it is checked (§8), with the consequences
  `v5-integrity.md` §2 states for a public seed `[generation-methods M16]`.
- **Play-test walk.** When the plugin runs in the play-test server DataModel, it walks `game:GetDescendants()` once
  `ReplicatedStorage.Lync.Reliable` exists and reports each foreign remote with `runtime` 1, the only view of remotes
  that helpers create at run time (Cmdr, legacy chat) `[build-checks §1.3]`. That plugin code runs in that DataModel
  is unverified (§8); where it doesn't, the walk doesn't run.
- **"Bake"** runs each `[[pvs]]` bake on the edit DataModel's parts, on demand, never on the edit path: a 1,024-cell
  bake takes 0.17–2.16 s native on the CLI `[interest-rewind §4.2]`.
- **Not in the plugin:** weaving, which would rewrite the open place's own scripts `[codecs-in-scripts §2]`; a
  publish or save hook, which no plugin can register `[client-security-build §1.4]`; execution coverage as a
  reachability check `[security-tooling Impl5]`, since in a play test the server's `unreachable` fact already
  reports each message of a definition the scan inferred unreachable, and its fix names `check.clientRoots`.

### 4.3 CI and release

1. `lync build`: one run, so one pair for every namespace and both sides (`v5-integrity.md` §2).
2. `rojo build -o game.rbxl`.
3. Woven projects: `lync weave game.rbxl -o release.rbxl` (§5).
4. `lync check --place release.rbxl --format github`: fails on errors, stale shards and type tests.
5. Open Cloud Place Publishing, `versionType=Published` (30 requests per minute), which returns the version.
6. `lync check --published <universe>/<place>/<version>`.
7. `restartServers` (30 per minute), which retires servers still on the previous build `[security-tooling §4]`.

CI keeps each release's manifest as an artefact. Woven places are written only by CI and never edited in Team
Create: publishing woven output into a place a team edits puts woven scripts in their editor
`[codecs-in-scripts §2]`. Studio-only projects stay on shards.

**`--published`** creates one Luau Execution task on the versioned endpoint
(`…/places/{p}/versions/{v}/luau-execution-session-tasks`; 5 task creations per minute per key owner, at most 5 min
per task, return values at most 4 MB). The task reads the `Source` of each shard part, `wovenScripts` entry and
`scripts` entry by path, hashes it with `EncodingService:ComputeStringHash` after CRLF-to-LF replacement, and returns
`{ path, digest }` as JSON; the CLI compares them with the manifest. The API key, with scope
`universe.place.luau-execution-session:write`, comes from the environment variable `LYNC_OPEN_CLOUD_KEY`, never from
`lync.toml`. Cost: zero at run time and on the wire; one task and one SHA-256 per listed script per check
`[refusals-rejudged-1 R11]`.

- **Decision: what `--published` does when the task can't read `Source`.**
  - *Problem.* Whether a Luau Execution task's thread holds `PluginOrOpenCloud`, which reading `Source` needs, is
    unverified `[refusals-rejudged-1 R11]`.
  - *Options:* fall back to `require`-ing each client shard part in the task and comparing its identity constants;
    **report `publishedUnreadable` and compare nothing.**
  - *Choice: report.* The fallback finds only a published pair from another run, which every join already reports
    as `schemaMismatch` (`seedDiffers` 1) under the default `"release"` seed, and it runs client shards on a server.
    Hand edits are what only a `Source` read finds.

Not in the release pipeline: a per-build key or seed record written to a DataStore `[security-tooling §4]`, since
the server shard holds every value a server needs and a read at start would make Lync's start yield
`[generation-methods M11]`; and a Luau Execution run of the golden set per game release `[security-tooling Impl3]`,
whose result depends only on the Lync version and the engine version, so it belongs in Lync's own CI.

## 5. Weaving (milestone 6)

Weaving writes each call site's encoder into the built copy of the game script that makes the call, and, with
site-bound ids, gives each woven site its own up-space id `[codecs-in-scripts]`. Game code, its types and the
shards' API don't change; only built copies do. It is a speed measure on every woven site and, through site ids, a
server-observed report on definitions every unmodified client reaches only through woven sites.

### 5.1 Decision: where the transform runs

- **Problem.** Rewriting the developer's own scripts each build causes merge conflicts and `UpdateSourceAsync`
  races, which is why draft 3.5 refused weaving; a transform has to see every script with its instance path and
  `RunContext`, including scripts inside `.rbxm` models.
- **Options:** **a pass over the place file `rojo build` produced**; a pass over a copy of the source tree before
  `rojo build` (misses scripts inside model files, needs two project files); the Studio plugin (no publish or save
  hook exists, so its only target is the developer's open scripts, the refused case) `[codecs-in-scripts §2]`.
- **Choice: the place-file pass,** CLI only. It never opens a developer file or Studio script, so nothing is merged
  and no editor races it. Verified end to end with Lune: `rojo build`, dump, weave, write, re-read identical
  `[codecs-in-scripts §2]`; the same round trip in the Rust host is unverified (§8). `rojo serve` keeps syncing
  unwoven sources, so play tests use the shard path and releases the woven path; the differential of §5.4 makes them
  write the same bytes. Studio-only projects never weave, and no `weave.*` key applies to them.

### 5.2 The command

`lync weave <place> -o <file>` reads the built place, the manifest and the schema modules. It refuses to run (exit
2) when its generator's `coreDigest` differs from the manifest's. It plans once at the manifest's `rotationSeed`,
regenerates the shards and compares them with the place's, so a place whose shards are from another run fails with
`editedShard` (`regenerated` 1) and nothing is written. Fragments, site table and shards therefore come from one
planner run `[codecs-in-scripts §8]`. It writes the output place with the woven scripts and rewritten shards (the
server shard gains the site table and site decoders; with `weave.dropClosed`, the client shard loses closed
encoders), and rewrites the manifest (§1.2). There is no `lync build --weave`: weaving's input is the built place,
which exists only after `rojo build`.

### 5.3 Sites and forms

- **Bindings.** A local initialised by a namespace value (§3.3) whose `require` path resolves statically through
  `game:GetService`, `.Name`, `:WaitForChild`, `:FindFirstChild`, `script`, `.Parent` or a local bound to one of
  them; `TS.import(script, base, segments…)` resolves as `base.segment…`. A definition alias is a local initialised
  by `binding.def`. Neither may be reassigned in its scope.
- **Resolved site:** a call `binding.def:verb(…)` or `alias:verb(…)`, dot or colon (roblox-ts emits both). It is
  **woven** when it is a statement, its argument is a table constructor whose keys are constant strings equal to the
  record's field set (any single expression for a non-record codec), and no shadowed builtin is in scope; otherwise
  it stays on the shard with the `weave*` code of §3.4 that names why. A **literal site** has every field value
  constant.
- **Forms** `[codecs-in-scripts §6]`:
  - client sites: inline (W2) when the definition has at most `weave.inlineMaxSites` woven client sites in the
    place, else a call into the shard's scalar entry with the fields as arguments (W3); with `weave.literals`, a
    literal site is folded at build time into one run header, one reserve and one constant write, whatever the
    count;
  - server sites: W3 only, with `weave.server = "call"`, since inlining into an interpreted game script loses the
    native shard's code;
  - never a `local function` helper: at `-O2` it is inlined and a refusal reports the helper's line, not the call's
    (`codecs-in-scripts/error_lines.out`).
- **Lines are preserved, so there is no line map.** Each replacement holds as many newlines as the text it replaces;
  each argument keeps its text and its first line; the encoder sits on the statement's last line; imports go on the
  binding statement's last line, never before the first token, so hot comments stay on lines 1–2. Every line keeps
  its number and instance paths don't change, so Rojo's sourcemap and the Error Report point at the developer's
  file and line. A line map per build `[security-tooling §10]` is therefore not built.
- **Positions.** Each woven check passes its site's source line as a constant to the cold `fail`, so a refusal
  reports the call's first line at `-O1` and `-O2` and skips the `debug.info` walk (`v5.md` §7.1); cost one `LOADN`
  per check, in the cold branch.

### 5.4 Closure and the gate

- **Closed definition:** its namespace is complete (§3.3's predicate, the one `v5-integrity.md` §3 defines: aliases,
  fields, returns and same-named parameters are followed, not escapes), and every occurrence of its name in the
  client scan set, as `.name`, `:name` or the string `"name"`, is part of a woven site or of an alias declaration
  whose uses are all woven `[codecs-in-scripts §4.2]`. The scope is the client scan set, as for reachability: server
  handlers name every definition they handle, so a scope of all scripts would close none. A generated trap has no
  site, so it is closed and keeps only its generic id; `weave.dropClosed` keeps trap encoders.
- **Gate**, per script, before anything is written `[codecs-in-scripts §4.3]`:

  | Check | On failure |
  |---|---|
  | parses with the pinned Luau parser | script unwoven, `weaveUnparsed` |
  | no shadowed builtin at a site | site unwoven, `weaveShadowed` |
  | the woven script compiles | script unwoven, `weaveCompile` |
  | line count unchanged | `internal` (exit 3) |
  | differential: for 200 value sets per site, drawn by xorshift32 seeded from the site's canonical index, the woven bytes equal the shard encoder's at the build's `rotationSeed` with every per-build method on, and a refused value raises the same message | `internal` (exit 3) |

  The 200 value sets are chosen, as in the prototype, which found woven and shard bytes identical over 3,466 B at
  `-O1` and `-O2` (`codecs-in-scripts/diff.out`).
- **Correctness never depends on finding every site:** an unwoven call stays on the shard, and completeness gates
  only closure.

### 5.5 Site-bound ids and `idTableHash`

- **Ids** (`weave.ids`): generic ids stay as `v5.md` §4.6 defines them. `"site"` adds one up-space id per woven
  client site, `"definition"` one per woven definition, after the generic ids, in canonical order by (script
  instance path, line), ties between scripts sharing a path broken by the SHA-256 of their woven source; they are
  permuted per server like every id. A site id's layout is its definition's layout minus the fields the site writes
  as constants (`"site"` only), so a fully literal site sends no payload bits. A site-id message is delivered as a
  message of its definition: the same `limit`, `validate`, handlers and element charge `[codecs-in-scripts §7.1]`.
  A message on the generic id of a closed definition is the fact `v5-integrity.md` §3 specifies.
- **Decision: what the up-id table's hash covers, and its name.**
  - *Problem.* Two builds at one fixed `build.seed` can differ in their site tables or generated traps, which set
    which up ids exist and what each delivers; `buildId` and the schema hash don't pin them, and a disagreement
    decodes wrong values silently.
  - *Options:* a hash of the site table alone (`weaveHash`, `[codecs-in-scripts §7.3]`), which misses traps and
    constants; **a hash of everything the two shards must agree on beyond `buildId` and the schema hash**
    `[generation-methods M16]`; a per-shard code hash, which adds no wire safety and which a modified client sets
    freely `[build-checks §4]`.
  - *Choice:* HalfSipHash-2-4, zero key, low 32 bits, over a canonical serialization of the id mode, the site table
    in canonical order (each site's script path, line and definition's canonical id), each site's constant fields
    and values, and the generated trap set (count, canonical positions, source codec of each). Not covered: values
    `buildId` pins (field order, tag constants, offsets), per-player variant data, the secrets (`rotationSeed`, the
    key-derivation secret, the canary key: a public hash over a secret is an offline check for guesses) and the
    per-server permutation seed. It is 0 with no site ids and no generated traps, so `v5.md` §4.10's G7 and every
    unwoven `HELLO` are unchanged. Named **`idTableHash`**, for the table it pins: `weaveHash` would misname an
    unwoven build with traps, and `layoutHash` collides with the `layout` field and option of the runtime path.
    `HELLO` carries it and a mismatch is refused (`v5.md` §4.6); `lync build` writes it without weaving whenever
    `build.traps` > 0.

### 5.6 Composition

- Per-build values reach woven sites from the same IR as the shard: field order, offsets (folded into the constant
  word at a literal site), traps; the tag is computed at flush and never woven `[generation-methods M16]`.
- Per-player variants compose only in tag scope: woven scripts in starter containers are copied to every player, so
  `build.playerVariantScope = "upstream"` with `lync weave` is `configRange` `[codecs-in-scripts §8]`.
- The schema hash, `staleShard` and the unwoven golden vectors are unchanged; woven fixture vectors (a site id; a
  fully literal site with no payload bits) join the golden set (`v5.md` §4.10).

### 5.7 Options

Read only by `lync weave`.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `weave.inlineMaxSites` | integer | woven client sites per definition | 0–65,535 (0: never inline) | 2 (chosen: in the measured 20-definition mix, client Lync bytecode is 1.34× unwoven at 1 inlined site per definition, 1.64× at 2, 1.89× at 3) | per site, mean over the measured mix at `-g1`: an unwoven site 124 B, W3 177 B, W2 654 B; client time per call (interpreted, median): `move6` W2 437 ns, W3 562 ns; `strike` 663 and 676; `chat` 144 and 164 `[codecs-in-scripts §6.1, §6.3]` |
| `weave.literals` | boolean | — | — | `true` (derived: no run-time cost; 85–165 ns less per literal call) | a literal site's checks move to the build; a refused literal is `weaveLiteralRefused` |
| `weave.server` | `"off"` \| `"call"` | — | — | `"call"` (derived: W3 is faster than the shard entry on the server with no correctness cost) | +53 B per server site (W3, the client mix's mean); server time per call `move6` 291 against 453 ns, `strike` 333 against 471, `chat` 115 against 176 (native shard, interpreted script) |
| `weave.ids` | `"generic"` \| `"definition"` \| `"site"` | — | — | `"site"` (chosen: the only mode with constant elision and per-site ids) | `"site"`: ⌈log2(D + S)⌉ − ⌈log2 D⌉ bits per upstream run (D = 20: +1 at S = 20, +2 at 60–100, +4 at 300; +1 bit is 9–18 B/s per player at 70 upstream frames/s), the closed-generic fact, constant elision (1–8 bits per message at the measured shapes, the whole payload at a fully literal site), `idTableHash` (4 B per namespace per connection); `"definition"`: at most +1 bit per run and the fact; `"generic"`: no wire change |
| `weave.dropClosed` | boolean | — | — | `false` (derived: with `true`, code outside the build calling a closed definition raises at the caller instead of sending, so an unmodified client running such code breaks) | `true`: the client shard drops closed definitions' encoders (0.43× unwoven bytes at 1 site per definition); the server still decodes and reports the generic id |
| `weave.handlers` | boolean | — | — | `false` (derived: it is the one transform whose result the byte differential can't check) | per delivered message of an unpacked definition: client 419 → 342 ns, server 355 → 262 ns `[codecs-in-scripts §6.4]`; build time to prove the precondition (unmeasured) |

### 5.8 Handler unpacking (`weave.handlers`)

A function literal passed to `connect`, `validate` or `handle` at a resolved binding or alias is rewritten to take
the record's top-level fields as arguments when every occurrence of its value parameter is a read `param.f`, with
`f` a constant field name of the record: never written, passed, returned, compared, captured by a closure, given to
`#`, `next` or `typeof`, or indexed by a non-constant. The parameter is replaced in place by one parameter
`__lync_<f>` per field and each `param.f` by `__lync_<f>`, so every line keeps its number. The rewritten call
registers through the shard's fields entry; the delivery passes the decoded locals to fields-form functions and
builds the payload table only when a table-form function is also registered for the definition, so handlers from
outside the place still receive the table.

### 5.9 Cost

- **Bytecode** (client total, `-g1`, against unwoven = 1.00) `[codecs-in-scripts §6.1]`: 20 definitions × 1, 2, 3, 5,
  10 sites spread: W3 1.03, 1.06, 1.09, 1.13, 1.20; W2 1.34, 1.64, 1.89, 2.30, 2.99; one definition × 50 sites: W3
  0.78, W2 4.78. The draft-3.5 figure of 5.0× is that last shape's bound, reproduced (22,927 against 4,587 B,
  `codecs-in-scripts/size_orig.out`), not a property of weaving `[codecs-in-scripts §1]`.
- **Load:** 10–32 KB more client bytecode at the measured mixes, 10–75 µs per join at 0.5–2.4 ns per byte on the
  CLI `[codecs-in-scripts §6.2]`; phone factor unmeasured (§8). A `--!native` server script with woven sites
  compiles in 424 µs against 183 µs unwoven for the fixture's `Weapon`, and draws on the per-game native code limit.
- **Server shard:** one decoder per site; a definition's decoder is 223–351 B `[generation-methods M15a]`, a site's
  is unmeasured.
- **Build:** the Python prototype took 3.06 s for 303 scripts (1.68 MB, 901 sites), 2.84 s of it parsing in one
  process per script; the Rust host parses in process, unmeasured (§8).

## 6. Inspector and profiler (milestone 6)

- **Studio inspector:** bytes per definition and per player from `Lync.counters()` polled at 4 Hz, facts from the
  observer, live frames decoded with the running shards' own decoders, capture, and replay of a capture with the
  layouts and keys the planner reproduces from the manifest (§1.2).
- **PacketProfiler adapter:** registers Lync as a traffic layer `[landscape §5]`.
- **MicroProfiler labels** with `profile = true` (`v5.md` §7.5).

## 7. Repo tooling

Never shipped: StyLua and selene with a Lync `std` file; Moonwave; Markdown guides and the code registry
`docs/codes/`; GitHub Actions; Python for simulations and capture analysis.

## 8. Pending measurements

Unverified facts a default, a code's known cause or a mechanism above rests on (`v5.md` principle 8):
- the `Source` cap of 200,000 characters set the ordinary way (the part cap, §1.1), and how many characters a
  `StringValue` holds (`ServerStorage.Lync.Config`, `.Manifest`);
- a host API reporting a module's native IR instruction count (the server-part bound, §1.1);
- an OS entropy source in Lune, and the entropy source of `HttpService:GenerateGUID()` in Studio (private
  `rotationSeed`, §4.1, §4.2);
- whether a Luau Execution task can read `Source` (`--published`, §4.3);
- whether plugin code runs in the play-test server DataModel and what `GetDescendants` costs in Studio (§4.2);
- `EncodingService:ComputeStringHash` speed in Studio and in a Luau Execution task (§4.2, §4.3);
- the end-to-end place round trip with script rewriting in the Rust host, its in-process parse time, and the share
  of resolvable woven sites in real Rojo and roblox-ts games (§5);
- the phone factor for load time per KB of bytecode (§5.9);
- what an open Team Create session does when Open Cloud publishes a new version (§4.3);
- whether a module returning a base64 string of 128 KiB × 4/3 or more is accepted (the PVS table), whether rbx-dom
  exposes `MeshPart` geometry, a 3D bake's cost, and place read time beyond the measured 500,003 instances (7.36 s
  in Lune, `build-checks/scale.out`) (§4.1, §4.2).
