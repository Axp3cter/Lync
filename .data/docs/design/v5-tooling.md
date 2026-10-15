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

- **One structure, the LSP `Diagnostic`** `[diagnostics §6.1]`: `range`, `severity`, `code` (the registry code of
  `v5.md` §7.1), `codeDescription.href` (`https://lync.dev/codes/<code>`), `message`, `source = "lync"`,
  `relatedInformation`, and `data` holding the value path. Positions come from the line each schema constructor
  records; columns by searching that line for the option key or codec name.
- **Renderings**, `--format`:
  - `human` (default): `error[unknownOption]: arena.chat has no option "rtae"`, the `-->` location, the source line
    with a caret, `= help:` when there is exactly one fix, and `run lync explain <code>` once per distinct code;
  - `json`: JSON Lines, one Diagnostic plus `uri` per line (it streams under `watch`);
  - `github`: `::error file=…,line=…,col=…,title=lync <code>::<message>`, plus the human report in
    `$GITHUB_STEP_SUMMARY`, since Actions shows at most 10 annotations per step.
  SARIF is not built: it would be a fourth renderer to maintain and golden-test, for GitHub code scanning, whose
  annotations the `github` format already gives in Actions. It is added if a user's CI consumes SARIF.
- **Severity by effect:** `error` writes no outputs; `warning` writes them. Declaration and `staleShard` codes are
  errors; `[check]` entries set the rest by name.
- **Build checks with their triggers:**
  - `rawRemote`: a method call `:FireServer(`, `:InvokeServer(`, `:FireClient(` or `:FireAllClients(` in a scanned
    client or server script outside `Packages/`. Evidence: file, line, column (the Diagnostic's `range`) and the
    method (`data.method`). Default `"warn"`, by its effect: traffic on such a remote is not budgeted, tagged or
    decoded by Lync, so §6.1 of `v5.md` doesn't cover it.
  - `solverOff`: each call site of `Lync.server(` or `Lync.client(` in the scanned scripts, unless
    `[types] solver = "new"` (`v5.md` §3.2).
  - Configuration, each with the key's position: `configSyntax` (TOML that doesn't parse, with line and column),
    `configUnknownKey` (a key the schema of `lync.toml` doesn't define), `configType` (a value of the wrong type),
    `configRange` (a value outside its range, including an unsupported `format`), `configMissing` (no `lync.toml`
    and no plugin `StringValue`, or a required key or table absent, such as `[[namespace]]`).
- **Exit codes:** 0 no errors; 1 errors (including stale shards in `check`); 2 usage or configuration
  (`configSyntax`, `configUnknownKey`, `configType`, `configRange`, `configMissing`); 3 internal error, printed with
  a request to file an issue.

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
