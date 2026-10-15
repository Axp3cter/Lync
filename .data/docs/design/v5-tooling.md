# Lync v5: compiler outputs and tools (milestones 3 and 6)

Draft 3.6, 2026-10-15. Part of the v5 design (`v5.md`); changes from draft 3.5 are in `v5-changes.md` ("Draft 3.5
to 3.6").
Milestone 3 builds §1–§4 on the Lune host, except what a row marks for a later milestone; milestone 6 builds the
Rust/mlua host, weaving (§5), `lync check --published`, `diff`, `replay`, the Studio plugin, the inspector and the
profiler adapter (§6). A build code is raised from the milestone in its row of §3.4, under `v5.md` §7.1's deferral
rule.

## 1. Outputs

**Generation inputs.** The generated files are a function of exactly these: the schema modules' text, `lync.toml`'s
text, the generator (`coreDigest`, §1.2), the pair (`buildId`, `rotationSeed`), and the scan result (§3.3: the
client scan set's paths, ordinals and digests, and whether they came from files or a place), which sets the
unreferenced-definition lists and each namespace's completeness. With equal inputs the compiler always produces the
same bytes `[client-security-build §2.2]`; the manifest records every input (§1.2). A build run draws the pair once
for every namespace and both sides (`v5-integrity.md` §2).

| Output | Format | Consumer | Reaches clients |
|---|---|---|---|
| client shard, server shard per namespace (§1.1) | Luau, readable, MIT header; each definition commented with its schema line | the game | the client shard |
| variant modules, one set per build run, with `build.playerVariantCount` > 1 (§1.1) | Luau, line 1 as shards | the server, which gives each player one | one variant per player |
| type declarations | `.d.ts`; JSDoc names each definition's schema line | roblox-ts | no |
| `manifest.json` (§1.2) | JSON, sorted keys, LF line endings | `lync check`, `lync weave`, `lync replay`, `lync diff`, the inspector's capture replay | no: it holds `rotationSeed` |
| `report.md` (§1.3) | Markdown rendered from the manifest | developers | no |
| PVS modules, per `[[pvs]]` entry (§2) | Luau parts returning base64 | the server | no |

**Instance paths**, in every output and diagnostic, are the names from the service down joined by `.`, with a `.`,
`\` or `*` inside a name written `\.`, `\\` or `\*`. Where siblings share a name, each path list in the manifest
also records an `ordinal`: the instance's 1-based index among the instances with that path, in `GetDescendants`
order of the place or, for files, in the sourcemap's order.

### 1.1 Shards

- **Line 1** mirrors the part's identity for a reader and carries its digest `[build-checks §3.2]`:
  `-- Lync 5.0.0 | arena | client | part 1/1 | build 3735928559 | schema 0123456789abcdef | code <64 hex digits>`.
  `code` is SHA-256 over every byte after line 1, with CRLF replaced by LF first. Nothing reads identity from line
  1: an edit to line 1 alone is not detected (`build-checks/drift.out`), and it changes no behaviour. Line 2 of a
  server part is `--!native`: a directive after a comment line still takes effect (checked with `luau-analyze`
  0.740 on `--!strict`).
- **Identity constants in the body**, as code the digest covers: generator version, `buildId`, seed-0 schema hash,
  schema path, namespace, side, part number and part count. `shardSchemaMismatch`, `shardPairMismatch`,
  `shardPartMissing` and `shardPartUnknown` (§3.4) read these.
- **Parts.** Each part holds at most 200,000 bytes of source. Derivation: `Source` set the ordinary way is capped at
  200,000 characters (reported, `[generation-security §2.4]`; §8), and a character takes at least one byte. A side
  that fits is one module, the shard module itself, `part 1/1`. A side that doesn't is split by sorted definition
  name into N parts: the shard module is then an index holding no definition, which requires its children `Part1` …
  `PartN` (files `client/init.luau`, `client/Part1.luau` …); the build deletes the other layout's files and every
  part beyond N. A definition whose generated code alone exceeds the cap is `definitionCodeBytesExceeded` (§3.4).
- **Generator invariants**, each checked by compiling every part with the host's Luau compiler before anything is
  written; a failure is `internal` (exit 3): at most 200 locals and 200 upvalues per function, fewer than 32,768
  closures per function prototype (`kMaxClosureCount`), definitions held in a table, each with its own functions
  `[generation-security §4.2]`. Server parts should also stay under 1,048,576 native IR instructions per module
  (`CodegenHeuristicsInstructionLimit`; Roblox's value unverified), past which functions are left interpreted, not
  refused `[client-security-build §2.1]`. No host is verified to report that count (§8), so until one is, the
  200,000-byte part cap is the only bound on a server part.
- **Self-check items.** The client shard holds the self-check item list of `v5-integrity.md` §5 (table, key,
  closure and expected line per entry that holds a Lync closure). Before anything is written, the build runs the
  emitted check against the emitted shard; an item failing there is `internal` (exit 3), a Lync emission bug.
- **Native code.** Server parts carry `--!native`; client parts carry no native directive. Roblox documents native
  code for servers only, and its clients run interpreted (reported, 2026) `[generation-security §4.1]`, so a client
  directive gains nothing and a server part without one loses native decode. There is no option.
- **Names.** Generated functions keep readable names, never per-build or anonymous ones: view keys, the shard's path
  and `require` give every tool a stable route, so per-build names price nothing `[refusals-rejudged-1 R10]`.
- **Types.** Generated Luau types use no `read` modifiers, which the old solver rejects (`v5.md` §3.2).
- **Variant modules** (`build.playerVariantCount` = N > 1; the mechanism is `v5-integrity.md` §2.4's): one set of N
  modules per build run, at `ServerStorage.LyncVariants.<v>`, v = 1 … N, each returning one integer (its mask),
  never replicated until the server gives one to a player `[generation-methods M7]`. Each carries line 1 and its
  digest as every output does, with `variant v/N` in place of namespace, side and part
  (`-- Lync 5.0.0 | variant 3/16 | build 3735928559 | code <64 hex digits>`); no part rule applies to a module of one
  integer. They are covered by `shardDigestMismatch`, `manifestShardMismatch` and `--published` as a shard part
  is (a body of one integer carries no identity constants to pair); the scans exclude them as Lync outputs.
- **The generator emits only what the schema declares.** A trap is a schema definition the developer writes and
  marks `:trap()` on the server view; it is emitted in the schema module, client shard, types and manifest by the
  same emitter as every other definition, so no output separates it (`v5-integrity.md` §3 holds the decision).

### 1.2 Manifest

| Field | Content |
|---|---|
| `format` | 1 |
| `generator` | `lync` (version) and `coreDigest` (SHA-256 of the compiler core that generated the build): the generator identity, for reproducibility. A part's `code` digest (§1.1) is a different value, for drift |
| `buildId`, `rotationSeed` | the run's public build id (u32) and private rotation seed (16 hex digits) `[generation-methods M1]` |
| `rotation` | `entropy`, the source the run drew its pair from: `"os"` (OS entropy), `"guid"` (Studio, §4.2), `"public"` (a source a tool can search, §4.1) or `"fixed"` (a fixed `build.rotationSeed`, `v5-integrity.md` §2.5). Nothing else is drawn that sets a run-time cost (`v5-integrity.md` §2.3) |
| `inputs` | SHA-256 of `lync.toml`'s text and of each schema module's text, and of the canonical serialization of `scan` (§1); regeneration (§3.4 `shardDigestMismatch`) runs only when every one equals the live value |
| `scan` | the client scan set (§3.3): `{ path, ordinal, digest }` per script, SHA-256 over LF-normalised `Source`, and `source` (`"files"` or `"place"`) |
| `variants` | one `{ variant, path, digest }` per variant module of the run (§1.1) |
| `namespaces.<name>` | `schemaPath`; `schemaHash` (seed 0); `ids` (canonical order to wire id, both spaces); `idTableHash` (§5.5); `shards.client` and `shards.server`, one `{ part, path, digest, wovenDigest? }` per part; `selfCheckItems`, the client shard's self-check items in index order, each `{ table, key }`, so a `REPORT`'s 1-based `selfCheckItem` names one (`v5-integrity.md` §5); `maxMessageUnits` (U_max) and `maxUnreliableInstances` (N_u) of its client-sent definitions (`v5.md` §7.5); `reachability` (`"complete"`, or `"incomplete"` with its `dynamicAccessFound` sites `{ uri, line, column, case }`); `unreferenced`, for a complete namespace, the exact list of its client-sent definitions with no `.name`, `:name` or `"name"` token in `scan`; per definition `{ line, worstCaseBytes, scanReferenced?, callerSources?, closed?, openReason?, sites? }`: `callerSources`, for a client-sent definition, its caller-source list (`v5-integrity.md` §4), one `{ path, ordinal, origin }` per script, `origin` `"text"` (the script names it), `"view"` (a view of it reaches the script through a followed parameter, field or return, §3.3) or `"config"` (`check.callerSources`); `sites` and `closed` from §5 |
| `remoteInstances`, `remoteCreations` | the `remoteInstanceFound` and `remoteCreationFound` entries of §3.4 with their evidence, sorted by path and ordinal, written whenever those checks run |
| `wovenScripts` | `{ path, ordinal, digest }` of each built copy `lync weave` rewrote (§5) |
| `streaming` | the place's `StreamingEnabled`, `StreamingTargetRadius`, `StreamingMinRadius`, `StreamOutBehavior`, `ModelStreamingBehavior` and the place file, when a place was read `[interest-rewind §12.3]` |
| `decoyReview` | each (definition, field, collection) where a `refers` declaration meets `:decoys`, with the scripts of the client scan set that name the definition `[decoy-challenge-facts §3]` |
| `pvs` | per `[[pvs]]` entry: cell count N, table bytes, part digests, bake time |
| `diagnostics` | the count of each code the run reported |

`unreferenced` and `closed` are observations about the scan set, not about every client: code outside `scan` (a
module in `ServerStorage` cloned into a client, an asset inserted at run time) can still fire such a definition.
They have no run-time effect unless the developer opts a definition in (`check.inferReachability`,
`v5-integrity.md` §3); only opted-in definitions' lists go into the server shard.

`lync build` and `lync watch` write it; `lync weave` rewrites it with the same `buildId`, adding the weave fields.
It must never ship, since it holds `rotationSeed`: an `output.manifest` path inside a folder the sourcemap maps into
the place is `outputPathMisplaced`. Studio-only projects keep it in `ServerStorage.Lync.Manifest`, a `StringValue`, split
into children `Part1` … of at most 200,000 characters each when longer (the `StringValue` cap is unverified, §8).
`ServerStorage` never replicates, but anyone holding the place file reads the `rotationSeed` there. Studio edit-time
regenerations run at the identity build (`buildId` 0, `rotationSeed` 0) and rewrite this manifest; only "Prepare
release" draws a pair (§4.2).

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
worst-case size, whether the scan found a reference to it, whether it is opted in to run-time reporting, closed or
open with the first open reason, and woven site count; the `unreferenced` list with the size and source of the scan
set it holds for; the `dynamicAccessFound` sites; the inbound bound's schema terms (`v5.md` §7.5): U_max, N_u, the
unit burst max(2 × U_max, 81,920) and its one-frame cost, 100 ns × the burst, and, for a namespace that declares
streams, the stream parse term `inbound.unreliable.frames` × Σ_streams 33 × c_copy at the default frames and the
measured c_copy of 64.7 ns native (`v5-collections.md` §15.7). Per build: one line naming `rotation.entropy`; the
`remoteInstances` and `remoteCreations` tables, with
one line stating that engine entry points other than remotes (`ClickDetector`, `ProximityPrompt`, `Tool` activation,
physics ownership) are not listed `[build-checks §1.1]`; the `decoyReview` list; the `streaming` settings; each PVS
table's N, size and bake time; the `diagnostics` counts. `output.report` takes `output.manifest`'s range (§2), since
the report lists review material that need not reach clients.

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
rotationSeed = "release"        # v5-integrity.md §2.5

[[namespace]]
schema = "src/shared/Net/schema.luau"
client = "src/shared/Net/client"
server = "src/server/Net"
dts = "types/net.d.ts"          # optional

[check]
inferReachability = false       # opt-in to run-time reporting (v5-integrity.md §3)
clientRoots = []                # v5-integrity.md §3
knownRemotes = ["ReplicatedStorage.Remotes.LegacyShop"]
remoteCallFound = "warn"        # any code of §3.4 with a [check] severity, by its own name

[output]
manifest = "build/lync-manifest.json"
report = "build/lync-report.md"
```

**Keys defined here.** Every path is relative to `lync.toml`; every instance path is written as in §1.

| Key | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `format` | integer | — | 1 | required | — |
| `project.sourcemap` | path to the JSON that `rojo sourcemap --include-non-scripts` writes | — | — | `"sourcemap.json"` | one JSON read per run; required (absent file: `sourcemapMissing`) whenever a check that maps files to instance paths runs and no `--place` is given (§3.3); a scripts-only sourcemap omits non-script instances, so `remoteInstanceFound` sees none from it `[build-checks §1.3]` |
| `namespace.schema` | path to the schema module | — | — | required | — |
| `namespace.client`, `namespace.server` | path of each side's shard module | — | distinct paths | required | — |
| `namespace.dts` | path | — | — | none: no `.d.ts` | one file per namespace |
| `namespace.staged` | boolean | — | — | `false` | `true`: the namespace's `schema` and `client` must map under `ServerStorage` (`stagedPathMisplaced`, §3.4); one more namespace index in the segment toc after `Lync.release` `[interest-rewind §12.3]` |
| `staged.paths` (`[[staged]]`) | array of instance paths | — | — | `[]` | one container lookup per path per run |
| `staged.loader` (`[[staged]]`) | instance path of a release folder | — | — | none | exempts references to that path from `stagedReferenceFound` |
| `pvs.place` (`[[pvs]]`) | path to a built `.rbxl` | — | — | none: no bake, and the module at `output` is the developer's own table, read as is | one place read per bake `[interest-rewind §10]` |
| `pvs.cellSize` | integer | studs | 8–256, and N = columns × rows ≤ 65,536, with columns = ⌈max X / `cellSize`⌉ − ⌊min X / `cellSize`⌋ and rows likewise in Z, over the extents in studs of the place's `Workspace` parts (the grid starts at a multiple of `cellSize`, as the table format below requires; the runtime's `pvs` range, `[interest-rewind §10]`; else `configValueOutOfRange`) | 32 (chosen: 1,024 cells on a 1,024-stud square map; a measured bake time or table size that a game can't afford changes it) | a table of 14 + ⌈N²/8⌉ B: 128 KiB of bits at 1,024 cells, 512 MiB at 65,536; as base64 it alone fills the documented 100 MB place limit `[generation-security §2.4]` at N = 24,495 |
| `pvs.raysPerAxis` | integer | sample points per axis per cell | 1–4 | 2 (chosen: a measured rate of pairs marked hidden that are visible would change it) | `raysPerAxis`⁴ rays per cell pair: 0.17 s at 1, 2.16 s at 2 for 1,024 cells on the measured map `[interest-rewind §4.2]` |
| `pvs.output` | path of a server-only module (a module, not a data store value: a data store read at start would make Lync's start yield) | — | must map under `ServerStorage` or `ServerScriptService` (else `outputPathMisplaced`) | required in each entry | the table's size × 4/3 (base64) in the place, in parts of at most 200,000 bytes of source with line 1 and digest as shard parts (§1.1): 1 part at 1,024 cells, 14 at 4,096 |
| `check.knownRemotes` | array of instance paths; `*` matches one path segment | — | — | `[]` | none; a listed `remoteInstanceFound` entry keeps its manifest row and gets no Diagnostic |
| `check.freeFormCodes` | integer | codes per component | 2–2^53 | 65,536 (chosen: below it every input of `v5.md` §3.4 and the measured demo inputs, above it ids, currency up to 10^6 and fine positions `[checks-telemetry C5]`; a schema whose claims or inputs fall on the other side changes it) | none; it sets `freeFormRoleMissing`'s threshold (`v5-checks.md` §7.4) |
| `check.minStagedNameBytes` | integer | B | 1–64 | 4 (chosen: shorter names such as `id` and `hp` occur in most scripts; a measured false-match rate changes it) | none; it sets `stagedNameFound`'s minimum length |
| `check.<code>` | `"off"` \| `"warn"` \| `"error"` | — | one key per code marked `[check]` in §3.4 | per code, §3.4 | `"off"` stops that check: no Diagnostic and no manifest entry of that code; computations another product reads still run (§3.2) |
| `output.manifest` | path | — | outside every folder the sourcemap maps into the place (else `outputPathMisplaced`) | `"build/lync-manifest.json"` | — |
| `output.report` | path | — | outside every folder the sourcemap maps into the place (else `outputPathMisplaced`) | `"build/lync-report.md"` | — |

**The PVS bake** is an approximation the developer reviews, not an exact visibility test: a cell pair is marked
hidden iff every one of the `raysPerAxis`² × `raysPerAxis`² segments between the two cells' sample points, at one
eye height in XZ, intersects an opaque collidable part's box `[interest-rewind §4.1–§4.2]`. Its errors go both
ways: an opening narrower than `cellSize`/`raysPerAxis`, and every height difference (a viewer on a ledge), can be
marked hidden though visible (`probes/scope-3.6/pvs_gap.luau`); meshes, unions, terrain and moving parts never
occlude. What Lync does exactly is apply the table it is given: a pair is withheld iff its bit is 0
(`v5-collections.md` §8.5). The developer reviews the baked table, edits it, or supplies their own through an entry
without `place`, or as a `buffer` passed to `interest`'s `pvs`.

**The PVS table format**, the bytes a `[[pvs]]` module's base64 string decodes to and the `buffer` `interest`'s
`pvs` option takes (`v5-collections.md` §8.2), the same for a baked table and a developer's own; integers
little-endian, as `buffer`'s functions read them:

| Offset (B) | Field | Type | Meaning |
|---|---|---|---|
| 0 | `cellSize` | u16 | studs, 8–256 |
| 2 | `originX`, `originZ` | i32 each | studs, the grid's minimum corner in X and Z, each a multiple of `cellSize` |
| 10 | `columns`, `rows` | u16 each | cells along X and along Z, each at least 1; N = `columns` × `rows` ≤ 65,536 |
| 14 | bits | ⌈N²/8⌉ B | bit b = u × N + s at byte ⌊b / 8⌋, bit b mod 8 counted from the least significant: 1 when cell s is visible from cell u, 0 when hidden; a position (x, z) is in cell ⌊(x − `originX`) / `cellSize`⌋ + `columns` × ⌊(z − `originZ`) / `cellSize`⌋ |

A table is exactly 14 + ⌈N²/8⌉ bytes; bits past N² in the last byte are 0. `interest` requires its `radius` to be
an integer multiple of the table's `cellSize` (`v5-collections.md` §8.5).

**Keys defined elsewhere**, by the section that states their meaning and cost: `build.rotationSeed`,
`build.varyOffsets`, `build.playerVariantCount` (`v5-integrity.md` §2.5); `check.inferReachability` (`false`,
`true`, or an array of namespace names and definition paths) and `check.clientRoots` (`v5-integrity.md` §3);
`check.callerSources` (`v5-integrity.md` §4); `weave.*` (§5.7). Every value the generator draws per build sits in
`[build]`, so per-player variants are `build.playerVariantCount`, not a `[variants]` table of one key
`[generation-methods M7]` `[interest-rewind §13.4]`.

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
  - `human` (default): `error[definitionOptionUnknown]: arena.chat has no option "rtae"`, the `-->` location, the source line
    with a caret, `= help:` when there is exactly one fix, and `run lync explain <code>` once per distinct code;
  - `json`: JSON Lines, one Diagnostic plus `uri` per line (it streams under `watch`);
  - `github`: `::error file=…,line=…,col=…,title=lync <code>::<message>`, plus the human report in
    `$GITHUB_STEP_SUMMARY`, since Actions shows at most 10 annotations per step.

  SARIF is not built: it would be a fourth renderer to maintain and golden-test, for GitHub code scanning, whose
  annotations the `github` format already gives in Actions.

### 3.2 Severity

- **Effect.** An `error` makes `lync build`, `lync watch` and `lync weave` write no outputs and `lync check` exit 1;
  a `warning` changes neither.
- **One code per subject and fix.** A trigger gets its own code when its subject or its fix differs; triggers with
  one subject and one fix share a code, with an evidence field naming which one fired and the known causes listed
  per value (`dynamicAccessFound` `case`, `shardDigestMismatch` `byRegeneration`); `v5.md` §7.3 states the same rule
  for facts.
- **Fixed severities**, for codes where no setting makes the finding right or wrong: declaration codes, the
  configuration and environment codes, `shardSchemaMismatch`, `shardDigestMismatch`, `shardPairMismatch`,
  `shardPartMissing`, `shardPartUnknown`, `definitionCodeBytesExceeded`, `publishedShardMismatch`,
  `publishedShardMissing` and `publishedWovenMismatch` are errors; `manifestShardMismatch`,
  `regenerationInputMismatch`, `lyncPackageDigestMismatch` and `publishedScriptMismatch` are warnings. Each is a
  mistake in the configuration, a failure of the environment, a mismatch between artefacts of one build, or a
  statement of what the build made against what the configuration asked `[build-checks §3.5]`.
- **`[check]` severities**, for every other code: `check.<code>` takes `"off"`, `"warn"` or `"error"`. Its default
  follows one rule, in this order: `"off"` when the trigger names an instance that carries no traffic between a client
  and the server (today `bindableInstanceFound`); `"error"` when no known cause in an unmodified game is correct code;
  `"warn"` when some known cause is correct code. `"off"` stops the check: no Diagnostic and no manifest entry of that
  code. Computations that another product reads still run: `check.dynamicAccessFound = "off"` leaves the namespace
  incomplete.

### 3.3 Scans

- **One lexer pass** per run: the core's token-level, pure-Luau lexer, in every host, so the CLI and the plugin
  compute the same sets and the server shard's reachability lists don't depend on the host. A parser-based rule in
  the Rust host could qualify callees by module and drop some `dynamicAccessFound` sites `[build-checks §2.5]`; it is not
  used, since two hosts would then write different shards for one project. Comments are not scanned; string
  literals are. Throughput, detector included: 11.0–12.3 MB/s interpreted, 19.4–20.1 MB/s native (Luau 0.742 CLI),
  6.9–14.3 MB/s inside Lune `[build-checks §2.6]`.
- **Script sets.**
  - *Client scan set:* `v5-integrity.md` §3's (scripts in replicating containers, `Packages/`, every `LocalScript`,
    every `Script` with `RunContext = Client`, the scripts under `check.clientRoots`).
  - *All scripts:* every script in the place.
  - *Replicating:* a top-level service without the reflection tag `NotReplicated` (rbx-dom's reflection database
    carries the tags); `ServerStorage`, `ServerScriptService` and `Chat` carry it, `Lighting`, `SoundService` and
    `Teams` don't (checked, API dump 0.741.19).
  - Both exclude Lync's outputs (shard parts, variant modules, PVS parts) and Lync's own package, identified by content:
    the generator carries the SHA-256 of each runtime module of its version, and the subtree of a `ModuleScript`
    whose first line is `-- Lync <version> runtime` is excluded only when every module in it matches. A subtree that
    carries the header and doesn't match is scanned and reported as `lyncPackageDigestMismatch`.
- **Namespace values** (for `dynamicAccessFound`, reachability, the caller probe's source lists and weave closure): the
  result of a `require` or `TS.import` whose static path matches the client shard's full instance path suffix, never
  its leaf name alone, since `client` is a common module name `[build-checks §2.3]`; followed through aliases, fields,
  module returns and same-named function parameters (`v5-integrity.md` §3). The incompleteness predicate is computed
  once per run and every reader takes the same set. For the caller probe's source lists the scan follows, by the
  same rule, views of a definition (`Net.strike`) and values holding one through parameters, fields and returns,
  and records each list entry's origin (§1.2; `v5-integrity.md` §4).
- **Inputs.**
  - *CLI over files:* the script files and `project.sourcemap` for their instance paths and containers, plus
    non-script instances when the sourcemap includes them.
  - *CLI with `--place <file>`:* the built place through rbx-dom (`rbx_binary` in the Rust host, `@lune/roblox` in
    Lune), which replaces the sourcemap and the files for every check of that run; it also holds instances Rojo
    doesn't manage only if the place was downloaded.
  - *Studio plugin:* `game:GetDescendants()` of the edit DataModel; in a play test, of the play-test server
    DataModel (§4.2).
  - *A place `lync weave` wrote* (its shard parts' digests equal their `wovenDigest`): `lync check` runs only the
    shard, manifest and `published*` codes on it and no scan, since an inline site no longer names its definition;
    the scans belong to the unwoven place the weave read (§4.3).

### 3.4 Codes

Every build code, with its exact trigger, its evidence (`data`), its severity (§3.2), its known causes in an
unmodified game, and the milestone that raises it (M).

**Configuration and environment** (exit 2):

| Code | Exact trigger | Evidence | Severity | Known causes | M |
|---|---|---|---|---|---|
| `configMalformed` | `lync.toml` text that doesn't parse as TOML | `line`, `column` | error | a mistake in `lync.toml` | 3 |
| `configKeyUnknown` | a key the JSON Schema of `lync.toml` doesn't define | key path | error | a misspelled key; a key removed in v5 (`[types]`) | 3 |
| `configValueWrongType` | a value of the wrong type | key path, expected type | error | a mistake in `lync.toml` | 3 |
| `configValueOutOfRange` | a value outside its range in §2 or §5.7, including an unsupported `format` and a range that names another key | key path, the range | error | a mistake in `lync.toml` | 3 |
| `outputPathMisplaced` | `output.manifest` or `output.report` inside a folder the sourcemap maps into the place, or a `pvs.output` that maps anywhere other than under `ServerStorage` or `ServerScriptService` | key path, the folder or container it maps to | error | a sourcemap that now maps `output.manifest`'s folder; a `pvs.output` written under `ReplicatedStorage` | 3 |
| `configMissing` | no `lync.toml` and no `ServerStorage.Lync.Config` | — | error | a fresh project | 3 |
| `configKeyMissing` | a required key or table absent (such as `[[namespace]]`) | key path | error | a fresh or partly written `lync.toml` | 3 |
| `sourcemapMissing` | the `project.sourcemap` file absent when §2's condition requires it | file | error | a sourcemap not generated before the run | 3 |
| `cloudRequestFailed` | an Open Cloud request of `lync check --published` answered with a status outside 200–299 | `endpoint`, `status` | error | an API key without scope `universe.place.luau-execution-session:write`; an exhausted rate limit (5 task creations per minute per key owner) | 6 |
| `cloudTaskFailed` | the Luau Execution task ended in a state other than `COMPLETE` | `state` | error | a place whose listed scripts take the task past its 5-minute limit | 6 |
| `publishedSourceReadFailed` | the task's read of a script's `Source` raised | `path`, `raisedText` | error | a task thread without capability `PluginOrOpenCloud` (unverified, §8) | 6 |
| `generatorMismatch` | `lync weave` run by a generator whose `coreDigest` differs from the manifest's | `manifestCoreDigest`, `runningCoreDigest` | error | another Lync version installed in CI than built the manifest | 6 |
| `captureBuildMismatch` | `lync replay` given a capture whose `HELLO` `buildId` or `idTableHash` differs from the manifest's | `captureBuild`, `manifestBuild`, `idTableHashMismatch` | error | the manifest of another release than the capture's | 6 |

**Shards and manifest:**

| Code | Exact trigger | Evidence | Severity | Known causes | M |
|---|---|---|---|---|---|
| `shardSchemaMismatch` | a shard part's seed-0 schema hash differs from the live schema's | `side`, `part` | error | the schema edited and not rebuilt | 3 |
| `shardDigestMismatch` | a part's or variant module's recomputed digest differs from the digest on its line 1 (`byRegeneration` 0); or (`byRegeneration` 1), in `lync check` only, with the part's body `buildId`, every `inputs` value and the generator equal to the manifest's: regenerating an unwoven part gives a digest other than its `digest`, or a woven part's digest differs from its `wovenDigest` (`lync weave` proved that part's regeneration before writing it, §5.2) | `side`, `part`, `variant` (0 for a shard part), `byRegeneration` | error; `lync build`, `lync watch` and the plugin run only `byRegeneration` 0 before overwriting, and overwrite nothing while it holds. Fix: restore or delete the part, and keep shard folders out of formatters (`.styluaignore`, darklua's input set) `[build-checks §3.5]` | a formatter over generated files (StyLua, format-on-save); a darklua pass over shards; a merge resolved by hand; Team Create "Merge From Server" on a drafted shard; for `byRegeneration` 1, an edit that also rewrote line 1's digest. Not a CRLF checkout (normalised) `[build-checks §3.3]` | 3 |
| `regenerationInputMismatch` | `lync check` with a manifest whose recorded input differs from the live one, so regeneration doesn't run | `input` (1 `lync.toml`, 2 a schema module, 3 the scan result, 4 the generator) | warning | any edit since the build: a script, a schema (also `shardSchemaMismatch`), `lync.toml`, or another Lync version | 3 |
| `shardPairMismatch` | the parts of a namespace's client shard and server shard don't all carry one `buildId`, one generator version and one schema hash in their bodies | `clientBuild`, `serverBuild`, `generatorVersionMismatch`, `schemaHashMismatch` | error | one side committed and not the other (Team Create Drafts commits per script); a partial checkout; a plugin write refused for one script (Script Injection denial, `UpdateSourceAsync` rejection); a stale copy in a place Rojo only partly manages | 3 |
| `shardPartMissing` | a part that a shard module's part count names is absent | `side`, `part` | error | a partial checkout; a plugin write refused for one script; a part deleted by hand | 3 |
| `shardPartUnknown` | a child `Part<k>` of a shard module with k beyond its part count | `side`, `part` | error | a part left from a larger build in a place Rojo only partly manages (the build deletes such files, §1.1) | 3 |
| `manifestShardMismatch` | the manifest records a `buildId` or part or variant digests other than the outputs' (`wovenDigest` for a place `lync weave` wrote, `digest` elsewhere) | `side`, `part`, `variant` | warning | the manifest not kept with the shards (not committed, or from another CI run) | 3 |
| `definitionCodeBytesExceeded` | one definition's generated code exceeds the 200,000-byte part cap (§1.1) | `bytes`; range at the definition's schema line | error | an enum of thousands of long item names; a record of thousands of fields | 3 |

The regeneration costs one generation run (planner and codegen, measured in milestone 3). The no-build path has no
shards and no manifest, so none of these codes applies to it.

**Scans:**

| Code | Exact trigger | Evidence | Severity | Known causes | M |
|---|---|---|---|---|---|
| `rawRemote` | a method call `:FireServer(`, `:InvokeServer(`, `:FireClient(`, `:FireAllClients(` or `:InvokeClient(` in any script of the all-scripts set | `method` | `[check]`, `"warn"` | the game's own remotes; packages firing their own remotes (Knit, Cmdr); a raw call on Lync's own remotes, which then fails the tag (`tagMismatch`) | 3 |
| `foreignRemote` | an instance of class `RemoteEvent`, `UnreliableRemoteEvent` or `RemoteFunction` anywhere in the place, except exactly `ReplicatedStorage.Lync.Reliable` of class `RemoteEvent` and `ReplicatedStorage.Lync.Unreliable` of class `UnreliableRemoteEvent` (a same-named instance of another class is listed); not raised for paths in `check.knownRemotes` | `class`, `instance`, `replicates` (1 when its top-level service is replicating, §3.3, else 0), `runtime` (1 when found by the plugin's play-test walk) | `[check]`, `"warn"` | the game's own remotes from before Lync or kept on purpose; a Toolbox model or gear carrying a remote inside a `Tool`; a remote in `ServerStorage` that game code clones into a replicated container (`replicates` 0); remotes frameworks and the legacy chat system create at run time (`runtime` 1). Not listed: remotes created after the play test ends, or inserted from assets at run time `[build-checks §1.5]` | 3; `runtime` 6 |
| `remoteCreation` | in the all-scripts set, `Instance.new(` whose first argument is one string literal naming one of `foreignRemote`'s classes (`literal` 1), or is not a string literal (`literal` 0) | `class` (empty when `literal` 0), `literal` | `[check]`, `"warn"` | Knit's Comm (`literal` 1); Cmdr's helper `Instance.new(className)` (`literal` 0); forked legacy chat scripts; a `literal` 0 site whose helper creates only other classes `[build-checks §1.2]` | 3 |
| `foreignBindable` | an instance of class `BindableEvent` or `BindableFunction` anywhere in the place | `class`, `instance`, `replicates` | `[check]`, `"off"` | every bindable is game code's own signal; a client fires only its own, never the server's `[build-checks §1.2]` | 3 |
| `lyncHeaderMismatch` | a `ModuleScript` whose first line is `-- Lync <version> runtime` in a subtree whose modules don't all match the generator's runtime digests; the subtree is scanned | `path`, `version` (from the header) | warning | a vendored copy of another Lync version inside a package; an edited runtime | 3 |
| `dynamicAccess` | in the client scan set, a dynamic access of a namespace value as `v5-integrity.md` §3 defines it: `kind` 1 an index whose key is not one string literal, 2 iteration (`for … in`, `pairs`, `ipairs`, `next`), 3 a hand-off the scan cannot follow by name | `namespace`, `kind`, `binding` (uri and range of the binding source) | `[check]`, `"warn"`; severity only, never whether the namespace is incomplete, and no per-site suppression (`check.reachability = false` is the opt-out) | kind 1: a generic helper `Net[name]:fire(v)`; kind 2: a client loop connecting every event, even one that fires nothing; kind 3: a framework registering the namespace with package code the scan has no definition for; any kind: following by name, which binds the parameter of every same-named function (`X.new(Net)` binds the first parameter of every `new`) and follows shadowing locals `[build-checks §2.5]` | 5 |
| `solverOff` | each call site of `Lync.server(` or `Lync.client(` in the all-scripts set | — | `[check]`, `"warn"` | runtime-path code under the old solver, the default in Roblox and luau-lsp, where its types degrade to error types; a project on the new solver, whose setting no tool can read (`NotScriptable`, `v5.md` §3.2), which sets `check.solverOff = "off"` | 3 |
| `freeFormField` | in a client-sent payload (`data` of `from = "client"` events and requests, `reply` of `from = "server"` requests), walked depth first in name order through records, `t.optional`, array elements, map keys and values, union variants, `t.convert`'s base and `t.cframe`'s position codec, a leaf with no `:claim()` or `:input()` on itself or an enclosing codec that is `t.f32`, `t.f64`, `t.vector3f32`, `t.int()`, `t.int(min, max)` with max − min + 1 > `check.freeFormCodes`, `t.number` or `t.vector3` with more than `check.freeFormCodes` codes per component, `t.string`, `t.buffer`, `t.instance` or `t.custom` | field path, the leaf's code count; range at the definition's schema line | `[check]`, `"warn"` | chat and other free text, names and search strings, fine settings sliders, cosmetic camera or UI coordinates: each takes one `:input()`. Not found: claims in input-shaped codecs (`t.bool`, `t.int(1, 500)`) and below the threshold (`t.number(0, 600, 0.01)`): the rule is syntax and can't recognise outcomes `[checks-telemetry C5]` | 3 |
| `decoyRef` | a collection C with a `.C:decoys(` call in the all-scripts set; a leaf of a client-sent payload, walked as `freeFormField` walks it, whose codec serialises (`v5.md` §4.7) identically to C's `key` codec; and, for that definition, no `:field("<path>"):refers(` whose argument is an expression ending in `.C`, with `<path>` the leaf's top-level field | field path, collection, `declarable` (0 when the path is not a top-level key, optional key or array of keys, and the message names `reportInteraction`) | `[check]`, `"warn"` | a field that shares the key codec but isn't a key (a `t.int(1, 2^40)` score beside `UserId` keys); a key left undeclared on purpose (a player naming its own record, never a decoy) `[decoy-challenge-facts §3]` | 5 |
| `unscopedRef` | a server-sent event or request whose `data` holds a field whose codec serialises identically to some collection's `key` codec, with no `:field("<path>"):about(` call on that definition whose argument is an expression ending in `.C`, for that field and collection C, in the all-scripts set | field path, collection; range at the definition's schema line | `[check]`, `"warn"` | a field that shares the codec but isn't a key; an event sent to every viewer on purpose `[interest-rewind §8]` | 4 |
| `stagedReplicated` | a staged namespace's `schema` or `client` path, or a `[[staged]] paths` entry, maps anywhere other than under `ServerStorage` or `ServerScriptService` | namespace or path, container | `[check]`, `"error"` | none: the declaration says server-only | 3 |
| `stagedReferenced` | a script of the client scan set, or a released namespace's schema, contains, as a string literal or as a path expression (a chain of `.Name`, `:WaitForChild("Name")` or `:FindFirstChild("Name")` rooted at `game:GetService("X")` or `game.X`), the instance path of a staged namespace's `schema` or `client` module or of a `[[staged]] paths` entry, either as built under `ServerStorage` or as released (the same path below `ReplicatedStorage`), or a `require` that resolves to one, other than through a `[[staged]] loader` path | namespace, path | `[check]`, `"error"` | none outside the loader exemption | 3 |
| `stagedNameLeak` | a definition name, field name, union variant or enum item of a staged namespace, at least `check.stagedNameBytes` bytes long, occurs byte for byte as a string literal in a released namespace's schema or a script of the client scan set | the string | `[check]`, `"warn"` | a common word ("level") used in both; only the game knows whether it leaks `[interest-rewind §12.3]` | 3 |
| `streamingOff` | the place read with `--place` has `Workspace.StreamingEnabled = false`, and the project has a staged namespace or an `:interest(` call in the all-scripts set | place path | `[check]`, `"warn"` | a game that streams nothing on purpose; with streaming off, all of `Workspace` reaches every client at join, whatever `interest` withholds `[interest-rewind §12.1]` | 3 |

**Weaving** (§5; each at its site's line, or line 1 of its script):

| Code | Exact trigger | Evidence | Severity | Known causes | M |
|---|---|---|---|---|---|
| `weaveArgument` | a resolved site of a record definition whose argument is not a table constructor | definition | `[check]`, `"warn"` | a payload built elsewhere and passed by name; a roblox-ts spread | 6 |
| `weaveKeys` | a resolved site whose table constructor's keys are not exactly the record's field set, or not all constant strings | definition, the differing key | `[check]`, `"warn"` | an optional field left out; a computed key | 6 |
| `weaveShadowed` | a free name the site's fragment references (a builtin such as `buffer`, `math`, `type`, `Enum` or `Vector3`, or a name with prefix `__lync_`) is bound by a local in scope at the site | definition, the name | `[check]`, `"warn"` | a game local named `type`, `vector` or `Enum` | 6 |
| `weaveCompile` | a woven script that fails to compile; the script stays unwoven | script, compiler message | `[check]`, `"warn"` | woven imports pushing a function past 200 locals or 200 upvalues `[generation-security §4.2]` | 6 |
| `weaveUnparsed` | a script the Luau parser, at the version the host pins, refuses; it stays unwoven | script, parser message | `[check]`, `"warn"` | syntax newer than the pinned parser | 6 |
| `weaveLiteralRefused` | with `weave.literals`, a literal site whose constant the codec refuses; the site stays unwoven and throws `valueRefused` when it runs, as unwoven | definition, field path, the value | `[check]`, `"warn"` | the call in code that never runs | 6 |

**Published place** (`lync check --published`, §4.3; `[refusals-rejudged-1 R11]`):

| Code | Exact trigger | Evidence | Severity | Known causes | M |
|---|---|---|---|---|---|
| `publishedShardDiffers` | a shard or variant part in the published version whose `Source` digest differs from the manifest's (`wovenDigest` when present, else `digest`) | `path`, `part`, `expectedBuild`, `foundBuild` (the body's `buildId`, which the task returns for parts) | error | a Studio publish after the plugin regenerated shards; a hand edit published from Studio; the manifest of another CI run passed to the check | 6 |
| `publishedShardMissing` | a shard part the manifest lists, absent at its path in the published version | `path`, `part` | error | a Studio publish from a place copy without it; a shard moved after the build | 6 |
| `publishedWovenDiffers` | at a path in `wovenScripts`, the published scripts' digests differ, as a multiset, from the manifest's | `path` | error | a Studio publish, which carries the developer's unwoven source | 6 |
| `publishedScriptChanged` | at a path of the client scan set that Lync didn't write, the published version's scripts differ from the `--place` file's: a digest present in one and not the other (`change` 1), a path only in the published version (2), or only in the file (3); paths are compared as multisets of digests, so same-path siblings need no order | `path`, `change` | warning | any edit published after the CI build; this is the developer's own code | 6 |

**Costs**, build time only, zero at run time and on the wire: SHA-256 0.04 ms per 64 KB part, CRLF normalisation
0.6–0.9 ms per 64 KB in Lune `[build-checks §3.5]`; the tree walk for `foreignRemote` and `foreignBindable` 3 µs per
instance after reading the place (1.36 s for 100,003 instances and 7.4 MB of source, scan included, in Lune)
`[build-checks §1.6]`; the shared lexer pass of §3.3; one codec-tree walk per client-sent payload for
`freeFormField` and `decoyRef`, and one codec comparison per leaf per collection with decoys (or per server-sent
field per collection for `unscopedRef`) `[checks-telemetry C5]` `[decoy-challenge-facts §3]`; one Luau Execution
task and one SHA-256 per walked script for `--published` (§4.3).

### 3.5 Exit codes

0 no errors; 1 one or more errors outside exit 2's codes; 2 usage (an unknown command, flag or argument, printed as
plain text) or a configuration or environment code; 3 `internal`, a Lync bug (a failed generator invariant, a woven
script whose line count changed, a woven site failing the gate's differential, §5.4), printed with a request to file
an issue. When codes of several classes occur in one run, 3 takes precedence over 2, and 2 over 1.

## 4. Hosts

### 4.1 CLI

| Command | What it does | M |
|---|---|---|
| `lync build [--place <file>]` | draws one (`buildId`, `rotationSeed`) and plans every namespace once with it; writes shards, `.d.ts`, the manifest and the report; runs every check of §3.4 except `staleShard`, `unpairedShard`, `staleManifest` (it rewrites all three artefacts), the weaving codes and the `published*` codes, and runs `editedShard` before overwriting; runs each `[[pvs]]` bake | 3; bakes 4 |
| `lync watch` | `lync build` again on each change to `lync.toml`, a schema module, the sourcemap or a scanned script; under `build.seed = "release"` each rebuild draws a new pair | 3 |
| `lync check [--place <file>] [--published <universe>/<place>[/<version>]] [--manifest <path>]` | every check of `lync build` plus the drift codes, writing nothing; with `--published`, which requires `--place` (the file that was published), the published-place codes | 3; `--published` 6 |
| `lync explain <code>` | prints the code's registry page | 3 |
| `lync weave <place> -o <file> [--manifest <path>]` | §5 | 6 |
| `lync diff <old> <new>` | compares two manifests at seed 0 and lists each definition whose ids or codecs changed; differences that come only from the two builds' pairs (field order, offsets) are listed apart | 6 |
| `lync replay <capture> [--manifest <path>]` | decodes a capture (its frames with their `HELLO` and `WELCOME`) using the layouts and keys the planner reproduces from the manifest (§1.2); refuses with `replayMismatch` when the capture's `buildId` or `idTableHash` isn't the manifest's | 6 |

`--manifest` defaults to `output.manifest`. `watch` is in milestone 3 because, outside Studio-only projects, it is
the only regenerate-on-edit path.

- **Host.** The shipped host is a Rust binary on mlua, installed with rokit; Lune is the fallback and the first
  host. Weaving needs the Rust host: it parses with Luau's own parser through a C++ shim, which Lune lacks
  `[codecs-in-scripts §2]`. Lute 1.0 is not used: its latest release has no macOS x86_64 binary, and its module paths
  differ from its own documented definitions (`@lute/crypto` against `@std/crypto`, a CST node's field `token`
  against `value`) `[client-security-build §1.2]`.
- **Entropy**, recorded as `rotation.entropy` (§1.2). The Rust host draws `buildId` and `rotationSeed` from OS
  entropy (`getrandom`) `[security-tooling §6]` (`"os"`), never from a clock-seeded generator, which is searchable
  from the build's approximate time `[generation-methods M1]`. The Lune host, on Linux and macOS, reads 12 bytes
  of `/dev/urandom` through `process.exec("od", { "-An", "-N12", "-tx1", "/dev/urandom" })` (`"os"`; that Lune
  passes the output intact is unverified, §8); where that fails it draws with `math.random` seeded from `os.clock()`
  and `os.time()` (`"public"`).
- **Decision: how a run names the built place.**
  - *Problem.* Foreign remotes in the tree, staged-path mapping, the streaming settings and a scan from a place
    (`scan.source` `"place"`) need the built place, which exists only after `rojo build`, so on a developer's machine
    it is often absent.
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
  with a filesystem `lync.toml`, `lync watch` is the one writer. Edit-time regeneration builds at the identity
  build (`buildId` 0, `rotationSeed` 0) and rewrites `ServerStorage.Lync.Manifest`; it runs `editedShard`
  (`regenerated` 0) first and overwrites nothing while it holds. Shards are written with `UpdateSourceAsync` inside
  one `ChangeHistoryService` recording `[security-tooling §3]`.
- **"Prepare release"** draws a new pair from two `HttpService:GenerateGUID(false)` calls (security None):
  dropping each GUID's dashes, its version digit (the 13th hex digit) and its variant digit (the 17th), it takes
  `rotationSeed` from the first 16 remaining digits of the first GUID and `buildId` from the first 8 remaining of the
  second, so no bit is shared between the two. It regenerates and writes the manifest, with `rotation.entropy`
  `"guid"`. The GUID's entropy source is undocumented, so Studio-only builds have a public-quality `rotationSeed`
  until it is checked (§8), with the consequences `v5-integrity.md` §2 states for a public seed
  `[generation-methods M16]`.
- **Play-test walk.** When the plugin runs in the play-test server DataModel, it walks `game:GetDescendants()` once
  `ReplicatedStorage.Lync.Reliable` exists, then follows `game.DescendantAdded` for the three remote classes until
  the play test ends, and reports each foreign remote with `runtime` 1: the only view of remotes that helpers create
  at run time (Cmdr, legacy chat) `[build-checks §1.3]`. That plugin code runs in that DataModel
  is unverified (§8); where it doesn't, the walk doesn't run.
- **"Bake"** runs each `[[pvs]]` bake, with the approximation §2 states, on the edit DataModel's parts, on demand,
  never on the edit path: a 1,024-cell bake takes 0.17–2.16 s native on the CLI `[interest-rewind §4.2]`.
- **Not in the plugin:** weaving, which would rewrite the open place's own scripts `[codecs-in-scripts §2]`; a
  publish or save hook, which no plugin can register `[client-security-build §1.4]`; execution coverage as a
  reachability check `[security-tooling Impl5]`: it would see only the paths a play test happens to run and needs
  plugin code in the play-test client DataModel (unverified), while the report's `unreferenced` list already names
  exactly what the scan found no token for, for the developer to judge against their own cloning and asset
  patterns.

### 4.3 CI and release

1. `lync build`: one run, so one pair for every namespace and both sides (`v5-integrity.md` §2).
2. `rojo build -o game.rbxl`.
3. `lync check --place game.rbxl --format github`: fails on errors. The scans read this unwoven place.
4. Woven projects: `lync weave game.rbxl -o release.rbxl` (§5). Call the place to publish P (`release.rbxl`, else
   `game.rbxl`).
5. Open Cloud Place Publishing of P, `versionType=Published` (30 requests per minute), which returns the version.
6. `lync check --published <universe>/<place>/<version> --place P`.
7. `restartServers` (30 per minute), only when step 6 exits 0; it retires servers still on the previous build
   `[security-tooling §4]`.

Servers started after step 5 already run the new version, so step 6 reports and doesn't gate them: a failure is
answered by publishing the previous release again. CI keeps each release's manifest as an artefact. Woven places
are written only by CI and never edited in Team Create: publishing woven output into a place a team edits puts
woven scripts in their editor `[codecs-in-scripts §2]`. Studio-only projects stay on shards.

**`--published`** creates one Luau Execution task on the versioned endpoint
(`…/places/{p}/versions/{v}/luau-execution-session-tasks`; 5 task creations per minute per key owner, at most 5 min
per task, return values at most 4 MB). The task walks the published version's client scan set, every shard and
variant part and every `wovenScripts` path, reads each `Source`, hashes it with `EncodingService:ComputeStringHash`
after CRLF-to-LF replacement, and returns `{ path, digest, buildId? }` as JSON, `buildId` read from a part's body
constant. The CLI walks the `--place` file the same way and compares path by path, each path's scripts as a
multiset of digests; parts and woven copies are also compared with the manifest. The API key, with scope
`universe.place.luau-execution-session:write`, comes from the environment variable `LYNC_OPEN_CLOUD_KEY`, never from
`lync.toml`. Cost: zero at run time and on the wire; one task and one SHA-256 per walked script per check
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
  unwoven sources, so play tests use the shard path and releases the woven path; the gate of §5.4 makes them
  deliver the same values. Studio-only projects never weave, and no `weave.*` key applies to them.

### 5.2 The command

`lync weave <place> -o <file>` reads the built place, the manifest and the schema modules. It refuses with
`generatorMismatch` (exit 2) when its generator's `coreDigest` differs from the manifest's. It plans once at the
manifest's `rotationSeed`, taking the scan result the manifest records (reachability lists and completeness)
rather than rescanning, regenerates the shards and compares them with the place's: a place whose shards are from
another run, or edited, fails with `editedShard` (`regenerated` 1) and nothing is written. Fragments, site table
and shards therefore come from one planner run `[codecs-in-scripts §8]`. It scans the place itself only for sites
and closure. It writes the output place with the woven scripts and rewritten shards (the server shard gains the
site table and site decoders; with `weave.dropClosed`, the client shard loses closed encoders), rewrites line 1 of
every part it changes with the new digest, which it records as `wovenDigest` `[build-checks §3.2]`, and rewrites
the manifest (§1.2). There is no `lync build --weave`: weaving's input is the built place,
which exists only after `rojo build`.

### 5.3 Sites and forms

- **Bindings.** A local initialised by a namespace value (§3.3) whose `require` path resolves statically through
  `game:GetService`, `.Name`, `:WaitForChild`, `:FindFirstChild`, `script`, `.Parent` or a local bound to one of
  them; `TS.import(script, base, segments…)` resolves as `base.segment…`. A definition alias is a local initialised
  by `binding.def`. Neither may be reassigned in its scope.
- **Resolved site:** a call `binding.def:verb(…)` or `alias:verb(…)`, dot or colon (roblox-ts emits both). It is
  **woven** when its argument is a table constructor whose keys are constant strings equal to the record's field set
  (any single expression for a non-record codec) and no free name of its fragment is shadowed; otherwise it stays on
  the shard with the `weave*` code of §3.4 that names why. A **literal site** has every field value
  constant.
- **Forms** `[codecs-in-scripts §6]`:
  - client sites in statement context: inline (W2) when the definition has at most `weave.inlineMaxSites` woven
    client sites in the place, else a call into the shard's scalar entry with the fields as arguments (W3); with
    `weave.literals`, a literal site is folded at build time into one run header, one reserve and one constant
    write, whatever the count;
  - client sites in expression context, every request (`invoke` yields and returns a result) included: W3, a call
    that is valid wherever the original call was `[codecs-in-scripts §4.1]`;
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
  fields, returns and same-named parameters are followed, not escapes), and every occurrence of its name in the client
  scan set, as `.name`, `:name` or the string `"name"`, is part of a woven site or of an alias declaration whose uses
  are all woven `[codecs-in-scripts §4.2]`. Closure is exact relative to the scan set and nothing more, as
  `unreferenced` is (§1.2): the manifest and report list every closed definition; a generic-id message on one is
  reported at run time only for definitions the developer opts in (`check.reachability`, `v5-integrity.md` §3), and
  site ids, constant elision and woven speed don't depend on that opt-in. The scope is the client scan set, as for the
  unreferenced list: server handlers name every definition they handle, so a scope of all scripts would close none. A
  declared trap that no client code names is closed like any such definition; with `weave.dropClosed` its encoder goes
  too, so a driver calling it raises at the caller and sends nothing: the developer's trade-off, stated in the
  option's row.
- **Gate**, per script, before anything is written `[codecs-in-scripts §4.3]`:

  | Check | On failure |
  |---|---|
  | parses with the pinned Luau parser | script unwoven, `weaveUnparsed` |
  | no shadowed builtin at a site | site unwoven, `weaveShadowed` |
  | the woven script compiles | script unwoven, `weaveCompile` |
  | line count unchanged | `internal` (exit 3) |
  | differential, for 200 value sets per site drawn by xorshift32 seeded with the site's canonical index plus 1 (never 0, xorshift32's fixed point), at the build's own `[build]` settings and `rotationSeed`, under the identity permutation and under permutation seed 1: with `weave.ids = "generic"`, the woven bytes equal the shard encoder's; otherwise the woven id is the site table's id for that site, and the server shard's site decoder gives from the woven bytes the value the generic decoder gives from the shard encoder's bytes `[codecs-in-scripts §7.3]`; in every mode a refused value raises the same message | `internal` (exit 3) |

  The 200 value sets are chosen, as in the prototype, which found woven and shard bytes identical over 3,466 B at
  `-O1` and `-O2` (`codecs-in-scripts/diff.out`); a gate miss found later in a released build would raise it.
- **Correctness never depends on finding every site:** an unwoven call stays on the shard, and completeness gates
  only closure.

### 5.5 Site-bound ids and `idTableHash`

- **Ids** (`weave.ids`): generic ids stay as `v5.md` §4.6 defines them. `"site"` adds one up-space id per woven
  client site, `"definition"` one per woven definition, after the generic ids, in canonical order by (script
  instance path, ordinal, line, column of the call's first token) (§1); they are permuted per server like every id.
  A site id's layout is its definition's layout minus the fields the site writes as constants (`"site"` with
  `weave.literals` only; with `weave.literals = false` a site writes no constants and its layout is its
  definition's), so a fully literal site sends no payload bits. A site-id message is delivered as a
  message of its definition: the same `limit`, `validate`, handlers and element charge `[codecs-in-scripts §7.1]`.
  A message on the generic id of a closed definition is the fact `v5-integrity.md` §3 specifies.
- **Decision: what the up-id table's hash covers, and its name.**
  - *Problem.* Two weaves at one fixed `build.seed` can differ in their id modes and site tables, which set which
    up ids exist and what each delivers; `buildId` and the schema hash don't pin them, and a disagreement decodes
    wrong values silently.
  - *Options:* a hash of the site table alone (`weaveHash`, `[codecs-in-scripts §7.3]`), which misses the id mode
    and the constants; **a hash of everything the two shards must agree on beyond `buildId` and the schema hash**
    `[generation-methods M16]`; a per-shard code hash, which adds no wire safety and which a modified client sets
    freely `[build-checks §4]`.
  - *Choice:* HalfSipHash-2-4, zero key, low 32 bits, over a canonical serialization of the id mode, the site table
    in canonical order (each site's script path, ordinal, line, column and definition's canonical id), and each
    site's constant fields and values. Not covered: values `buildId` pins (field order, tag constants, offsets, and
    every `[build]` option, `v5-integrity.md` §2), per-player variant data, the secrets (`rotationSeed`, the
    key-derivation secret, the canary key: a public hash over a secret is an offline check for guesses) and the
    per-server permutation seed. It is 0 exactly when the id mode is `"generic"`; otherwise it is the hash, with 0
    replaced by 1. Named **`idTableHash`**, for the table it pins: `weaveHash` would misname a field the protocol
    always carries, and `layoutHash` collides with the `layout` field and option of the runtime path. `HELLO`
    carries it at protocol version 2, so G7 is re-cut with `idTableHash` 0 (`v5.md` §4.6, §4.10), and a mismatch is
    refused.

### 5.6 Composition

- Per-build values reach woven sites from the same IR as the shard: field order and offsets (folded into the
  constant word at a literal site); the tag is computed at flush and never woven `[generation-methods M16]`.
- Per-player variants compose only in tag scope: woven scripts in starter containers are copied to every player, so
  `build.playerVariantScope = "upstream"` with `lync weave` is `configRange` `[codecs-in-scripts §8]`.
- The schema hash, `staleShard` and the unwoven golden vectors other than G7 (re-cut, §5.5) are unchanged; woven
  fixture vectors (a site id; a fully literal site with no payload bits) join the golden set (`v5.md` §4.10).

### 5.7 Options

Read only by `lync weave`.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `weave.inlineMaxSites` | integer | woven client sites per definition | 0–65,535 (0: never inline) | 2 (chosen: in the measured 20-definition mix, client Lync bytecode is 1.34× unwoven at 1 inlined site per definition, 1.64× at 2, 1.89× at 3; a measured phone load cost per KB would change it) | per site, mean over the measured mix at `-g1`: an unwoven site 124 B, W3 177 B, W2 654 B; client time per call (interpreted, median): `move6` W2 437 ns, W3 562 ns; `strike` 663 and 676; `chat` 144 and 164 `[codecs-in-scripts §6.1, §6.3]` |
| `weave.literals` | boolean | — | — | `true` (derived: no run-time cost; 85–165 ns less per literal call) | a literal site's checks move to the build; a refused literal is `weaveLiteralRefused` |
| `weave.server` | `"off"` \| `"call"` | — | — | `"call"` (derived: W3 is faster than the shard entry on the server with no correctness cost) | +53 B per server site (W3, the client mix's mean); server time per call `move6` 291 against 453 ns, `strike` 333 against 471, `chat` 115 against 176 (native shard, interpreted script) |
| `weave.ids` | `"generic"` \| `"definition"` \| `"site"` | — | — | `"site"` (chosen: the only mode with constant elision and per-site ids) | `"site"`: ⌈log2(D + S)⌉ − ⌈log2 D⌉ bits per upstream run (D = 20: +1 at S = 20, +2 at 60–100, +4 at 300; +1 bit is 9–18 B/s per player at 70 upstream frames/s), the closed-generic fact, constant elision (1–8 bits per message at the measured shapes, the whole payload at a fully literal site); `"definition"`: at most +1 bit per run and the fact; `"generic"`: no wire change |
| `weave.dropClosed` | boolean | — | — | `false` (derived: with `true`, code outside the build calling a closed definition raises at the caller instead of sending, so an unmodified client running such code breaks, and a declared trap no client code names loses its encoder, so a driver calling it sends nothing) | `true`: the client shard drops closed definitions' encoders (0.43× unwoven bytes at 1 site per definition); the server still decodes and reports the generic id |
| `weave.handlers` | boolean | — | — | `false` (derived: it is the one transform whose result the byte differential can't check) | per delivered message of an unpacked definition: client 419 → 342 ns, server 355 → 262 ns `[codecs-in-scripts §6.4]`; build time to prove the precondition (unmeasured) |

### 5.8 Handler unpacking (`weave.handlers`)

A function literal passed to `connect`, `validate` or `handle` at a resolved binding or alias is rewritten to take
the record's top-level fields as arguments when every occurrence of its value parameter is a read `param.f`, with
`f` a constant field name of the record: never written, passed, returned, compared, captured by a closure, given to
`#`, `next` or `typeof`, or indexed by a non-constant. The parameter is replaced in place by one parameter
`__lync_<i>` per top-level field, i its 1-based index in field order (field names need not be identifiers), and each
`param.f` by its `__lync_<i>`, so every line keeps its number. The rewritten call
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
- whether Lune's `process.exec` returns `od`'s reading of `/dev/urandom` intact, and the entropy source of
  `HttpService:GenerateGUID()` in Studio (private `rotationSeed`, §4.1, §4.2);
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
