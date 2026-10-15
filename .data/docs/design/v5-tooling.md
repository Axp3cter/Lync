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
  closures per function prototype (`kMaxClosureCount`), definitions held in a table with small functions per
  definition `[generation-security §4.2]`. Server parts should also stay under 1,048,576 native IR instructions per
  module (`CodegenHeuristicsInstructionLimit`; Roblox's value unverified), past which functions are left
  interpreted, not refused `[client-security-build §2.1]`. No host is verified to report that count (§8), so until
  one is, the 200,000-byte part cap is the only bound on a server part.
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
| `scripts` | the client scan set (§3.3) minus Lync's own outputs: `{ path, digest }`, SHA-256 over LF-normalised `Source`, read from the place with `--place`, else from the files the sourcemap maps `[refusals-rejudged-1 R11]` |
| `wovenScripts` | `{ path, digest }` of each built copy `lync weave` rewrote (§5) |
| `streaming` | the place's `StreamingEnabled`, `StreamingTargetRadius`, `StreamingMinRadius`, `StreamOutBehavior`, `ModelStreamingBehavior` and the place file, when a place was read `[interest-rewind §12.3]` |
| `decoyReview` | each (definition, field, collection) where `:refers` meets `:decoys`, with the client scripts in the scan set that name the definition `[decoy-challenge-facts §3]` |

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
| `pvs.output` | path of a server-only module | — | must map under `ServerStorage` or `ServerScriptService` (else `configRange`) | required in each entry | the table's size × 4/3 (base64) in the place |
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
  are warnings. Each is a mismatch between artefacts of one build, or a statement of what the build made against what
  the configuration asked `[build-checks §3.5]`.
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
| `cloudTaskFailed` | the Luau Execution task ended in a state other than `COMPLETE` | `state` | error | the task's 5-minute limit on a large place | 6 |
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
| `trapNamesShort` | a complete namespace with fewer trap-name candidates (§1.1) than `build.traps` | `namespace`, `requested`, `generated` | warning | a namespace whose definition names have few pieces (one definition `chat` gives none) | 5 |
| `solverOff` | each call site of `Lync.server(` or `Lync.client(` in the all-scripts set | — | `[check]`, `"warn"` | runtime-path code under the old solver, the default in Roblox and luau-lsp, where its types degrade to error types; a project on the new solver, whose setting no tool can read (`NotScriptable`, `v5.md` §3.2), which sets `check.solverOff = "off"` | 3 |
| `freeFormField` | in a client-sent payload (`data` of `from = "client"` events and requests, `reply` of `from = "server"` requests), walked depth first in name order through records, `t.optional`, array elements, map keys and values, union variants, `t.convert`'s base and `t.cframe`'s position codec, a leaf with no `:claim()` or `:input()` on itself or an enclosing codec that is `t.f32`, `t.f64`, `t.vector3f32`, `t.int()`, `t.int(min, max)` with max − min + 1 > 65,536, `t.number` or `t.vector3` with more than 65,536 codes per component, `t.string`, `t.buffer`, `t.instance` or `t.custom` | field path, the leaf's code count; range at the definition's schema line | `[check]`, `"warn"` | chat and other free text, names and search strings, fine settings sliders, cosmetic camera or UI coordinates: each takes one `:input()`. The 65,536 is a constant, chosen: below it every input of `v5.md` §3.4 and the measured demo inputs (255-code sticks, enums, slot indices), above it ids, currency up to 10^6 and fine positions `[checks-telemetry C5]` | 3 |
| `decoyRef` | a collection C with a `.C:decoys(` call in the all-scripts set; a leaf of a client-sent payload, walked as `freeFormField` walks it, whose codec serialises (`v5.md` §4.7) identically to C's `key` codec; and no `:refers("<top-level field>", "C")` for that definition and field | field path, collection, `declarable` (0 when the path is not a top-level key, optional key or array of keys, and the message names `reportInteraction`) | `[check]`, `"warn"` | a field that shares the key codec but isn't a key (a `t.int(1, 2^40)` score beside `UserId` keys); a key left undeclared on purpose (a player naming its own record, never a decoy) `[decoy-challenge-facts §3]` | 5 |
| `unscopedRef` | a server-sent event or request whose `data` holds a field whose codec serialises identically to some collection's `key` codec, with no `:about("<field>", …)` call on that definition in the all-scripts set | field path, collection; range at the definition's schema line | `[check]`, `"warn"` | a field that shares the codec but isn't a key; an event sent to every viewer on purpose `[interest-rewind §8]` | 4 |
| `stagedReplicated` | a staged namespace's `schema` or `client` path, or a `[[staged]] paths` entry, maps to `ReplicatedStorage`, `ReplicatedFirst`, `Workspace`, `StarterGui`, `StarterPack` or `StarterPlayer` | namespace or path, container | `[check]`, `"error"` | none: the declaration says server-only | 3 |
| `stagedReferenced` | a script of the client scan set, or a released namespace's schema, contains a staged module's instance path or a `require` that resolves to it, other than the `[[staged]] loader` path | namespace, path | `[check]`, `"error"` | none outside the loader exemption | 3 |
| `stagedNameLeak` | a definition name, field name, union variant or enum item of a staged namespace, at least 4 bytes long, occurs byte for byte as a string literal in a released namespace's schema or a script of the client scan set | the string | `[check]`, `"warn"` | a common word ("level") used in both; only the game knows whether it leaks `[interest-rewind §12.3]` | 3 |
| `streamingOff` | the place read with `--place` has `Workspace.StreamingEnabled = false`, and the project has a staged namespace or an `:interest(` call in the all-scripts set | place path | `[check]`, `"warn"` | a game that streams nothing on purpose; with streaming off, all of `Workspace` reaches every client at join, whatever `interest` withholds `[interest-rewind §12.1]` | 3 |

**Weaving** (§5; per site or per script, each at the site's line):

| Code | Exact trigger | Evidence | Severity | Known causes | M |
|---|---|---|---|---|---|
| `weaveNotStatement` | a resolved site (§5.3) in expression context, such as `local r = Net.buy:invoke(…)` | definition | `[check]`, `"warn"` | every request (`invoke` yields and returns a result); a `fire` whose value is used | 6 |
| `weaveArgument` | a resolved site of a record definition whose argument is not a table constructor | definition | `[check]`, `"warn"` | a payload built elsewhere and passed by name; a roblox-ts spread | 6 |
| `weaveKeys` | a resolved site whose table constructor's keys are not exactly the record's field set, or not all constant strings | definition, the differing key | `[check]`, `"warn"` | an optional field left out; a computed key | 6 |
| `weaveShadowed` | a local named `type`, `math`, `buffer`, `vector` or with prefix `__lync_` in scope at a resolved site | definition, the name | `[check]`, `"warn"` | a game local named `type` or `vector` | 6 |
| `weaveCompile` | a woven script that fails to compile; the script stays unwoven | script, compiler message | `[check]`, `"warn"` | woven imports pushing a function past 200 locals or 200 upvalues `[generation-security §4.2]` | 6 |
| `weaveUnparsed` | a script the Luau parser, at the version the host pins, refuses; it stays unwoven | script, parser message | `[check]`, `"warn"` | syntax newer than the pinned parser | 6 |
| `weaveLiteralRefused` | with `weave.literals`, a literal site whose constant the codec refuses; the site stays unwoven and throws `valueRefused` when it runs, as unwoven | definition, field path, the value | `[check]`, `"warn"` | the call in code that never runs | 6 |

**Published place** (`lync check --published`, §4.1; `[refusals-rejudged-1 R11]`):

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

- **CLI:** `lync build`, `lync watch`, `lync check`, `lync explain <code>` (milestone 3); `lync diff <old> <new>`
  (breaking wire changes) and `lync replay <capture>` (milestone 6). `watch` is in milestone 3 because, outside
  Studio-only projects, it is the only regenerate-on-edit path. The shipped host is a Rust binary on mlua, installed
  with rokit; Lune is the fallback and first host. Lute 1.0 is not used: its latest release has no macOS x86_64 binary, and its
  module paths differ from its own documented definitions (`@lute/crypto` against `@std/crypto`, a CST node's
  field `token` against `value`) `[client-security-build §1.2]`.
- **Studio plugin** (milestone 6): the same diagnostics through
  `ScriptEditorService:RegisterScriptAnalysisCallback`, with `code` and `href`, plus `staleShard` on shards; the
  network inspector; a "Prepare release" action that writes a fresh build seed. It regenerates on schema edit only
  when the configuration lives in its `StringValue`; with a filesystem `lync.toml`, `lync watch` is the one writer.
  No plugin can hook publish or save `[client-security-build §1.4]`.
- **CI:** `lync check --format github` fails on stale shards, errors and type tests; a release builds client and
  server shards in one `lync build` run (one seed, `v5-integrity.md` §2) and publishes through Open Cloud
  `[client-security-build §1.8]`.

## 5. Inspector and profiler (milestone 6)

- **Studio inspector:** bytes per definition and per player from `Lync.counters()` polled at 4 Hz, facts from the
  observer, live decoded frames, capture and replay.
- **PacketProfiler adapter:** registers Lync as a traffic layer `[landscape §5]`.
- **MicroProfiler labels** with `profile = true` (`v5.md` §7.5).

## 6. Repo tooling

Never shipped: StyLua and selene with a Lync `std` file; Moonwave; Markdown guides and the code registry
`docs/codes/`; GitHub Actions; Python for simulations and capture analysis.
