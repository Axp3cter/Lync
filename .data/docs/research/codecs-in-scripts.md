# Codecs in game scripts: weaving per-site encoders into built output

Researcher findings, 2026-10-15. **Decision it feeds:** whether v5 should emit each call site's encode (and,
server-side, decode delivery) into the game scripts that use it, which draft 3.5 refused (`v5-changes.md`, "Codecs
scattered into game scripts"), and in which form. The refusal is not inherited: each of its reasons is re-tested.

**Labels.** **verified**: I ran it or read the source. **documented**: official docs say so. **reported**: a third
party says so. **unverified**: inference or nothing found.

**Tools.** Luau 0.742 built from `.data/projects/luau` (CMake Release, scratch build, not committed); the luau skill's
`luau-ast`/`luau-compile` 0.740 and API dump 0.741.19; Rojo 7.7.1 and Lune 0.11.0 release binaries. Machine: Xeon
2.1 GHz, 4 cores, shared with other researchers, timings pinned to an idle core (`taskset -c 3`); CLI timings show
scale only, and phones are slower by an unmeasured factor.

**Probes** (`.data/docs/probes/codecs-in-scripts/`):
- `gen.py`: runtime model, client shard model and game-script models in every call-site form (shard and woven);
  `host.cpp`: a harness linked to the 0.742 VM that runs several chunks in one sandboxed VM, each interpreted,
  native, or as on a Roblox server (only `--!native` modules and `@native` functions); `bench.sh`, `summarize.py`,
  output `bench.out`, `bench.md`.
- `size.py`: bytecode of woven against shared forms (`size.out`); `size_orig.out`: the 5.0x probe re-run.
- `fixture/`, `place_io.luau` (Lune), `weave.py`: a prototype weaver over a `rojo build` place; `diff_mock.luau`,
  `diff_drive.luau`: original-against-woven differential.

Sibling briefs read and cited: `research/security-tooling.md` §10 (cited `[ST §n]`), `research/generation-security.md`
(`[GS §n]`), `research/client-security-build.md` (`[CSB §n]`), `research/client-security.md` (`[CS §n]`).

## Plan (ticked as written)

- [ ] 0. Bottom line
- [x] 1. The refusal, re-tested
- [x] 2. Where the transform runs
- [x] 3. The typed API on both solvers and roblox-ts
- [x] 4. Finding call sites and proving a definition closed
- [x] 5. Line preservation and error positions (source maps)
- [ ] 6. Cost: bytecode, load, encode and decode time, build time
- [ ] 7. Dual-purpose form: site-bound wire ids
- [ ] 8. Interaction with seed, rotation, per-player variants, tag, schema hash
- [ ] 9. Options
- [ ] Implications

## 1. The refusal, re-tested

The record gives these reasons (`v5-changes.md`: the draft-2 refusals table and 3.4→3.5 part 2; [CSB §3.2]). Each, re-tested:

| Reason | Holds? | Evidence |
|---|---|---|
| Rewrites the developer's scripts each build: merge conflicts, `UpdateSourceAsync` races | **No, if the transform runs on built output only.** A post-build pass over the `.rbxl` never opens a source file or a Studio script | §2; verified end to end: `rojo build` → Lune dump → `weave.py` → Lune apply → re-read gives the woven sources byte for byte (`fixture/`, `place_io.luau`) |
| Removes the typed shard API | **No.** Game code still requires the shard and types against it; only the built copy of each script changes | §3 |
| 5.0x bytecode | **Reproduced, but it is the worst case of one shape**, not a property of weaving | §6.1: the probe re-run gives 22,927 against 4,587 B again (`size_orig.out`, 0.742); realistic shapes give 0.43x to 2.3x of the unwoven client total, and 4.8x only when 50 sites fire one definition |
| No speed gain ("a shared call to a straight-line encoder is already a fast path", [CSB §3.2]; repeated in [ST §10]) | **No.** Weaving removes the payload table, the method dispatch and, at literal sites, every check and the variant dispatch; measured 1.2–3.0x faster per call than a shard without the rollback `pcall`, 1.3–3.5x faster than the specified shard entry | §6.3 |
| The central queue stays findable by `getgc` [CSB §3.2] | **Yes, and it does not matter**: weaving's security value is elsewhere (§7) | the queue is the runtime's writer; woven code calls it like the shard does |

Two further reasons appear in the record and still hold in part:
- **"Every client downloads it"** [CSB §3.2]: true; the added bytes are measured in §6.1 and their load cost in §6.2
  (tens of µs per join at the measured sizes).
- **Codec errors would point into `Weapon:142`, not a shard** [CSB §3.2]: they point at the *call site* line,
  which is what v5's caller-error walk already reports for shard calls (`v5.md` §7.1). §5 shows how to keep that
  exact on both optimisation levels.

## 2. Where the transform runs

**Rule: weave only artefacts the build produced, never a file or script the developer edits.** Then there is
nothing to merge and no editor to race. Candidates:

| Vehicle | How | Sees | Limits | Status |
|---|---|---|---|---|
| **A. Place-file pass (recommended)** | `rojo build -o game.rbxl` → `lync weave game.rbxl -o release.rbxl` → publish (`rojo upload` or Open Cloud place publishing) | every script in the place, including scripts inside `.rbxm` models and packages in the tree, with their instance paths and `RunContext` | Rojo has no transform hook (fixed middleware enum), so this is a separate step [CSB §1.3, ST §7]; Open Cloud publishing does not update EditableImage/Mesh, PartOperation, SurfaceAppearance, BaseWrap [CSB §1.8] | **verified end to end** with Lune 0.11 `@lune/roblox` (`place_io.luau`): 4 scripts dumped, 2 rewritten, written back, re-read identical; [ST §10] had marked this unverified |
| B. Source-copy pass | copy the tree to `build/`, weave the copies, `rojo build` a project file that points at `build/` | only file-backed scripts; instance paths need `rojo sourcemap` | misses scripts inside model files; two project files | inferred; no probe |
| C. roblox-ts | `rbxtsc` writes `out/` (already a build artefact; `.luau` files are copied verbatim [CSB §1.7]); then A over the place Rojo builds from `out/` | the compiled Luau | weave a copy or the place, never `out/` in place under `rbxtsc -w` (it rewrites changed files) | inferred from roblox-ts source; no probe |
| D. Studio plugin | `UpdateSourceAsync` on the open place | live DataModel | no publish or save hook (all RobloxScriptSecurity) [CSB §1.4, ST §3]; `SavePlaceAsync` is blocked by active Team Create and overwrites [ST §3]; so the only target is the developer's own scripts, which is the refused case | **not viable** for weaving |

**Host.** The shipped CLI is Rust on mlua [CSB §1.2]. Place I/O: `rbx_binary` 3.0.1 + `rbx_dom_weak` 4.2.0 (the
crates Rojo 7.7.1 uses; cached here) or the `lune-roblox` 0.4.0 crate [ST §6]. Parsing: Luau's own parser through a small
C++ shim (the `luau-ast` CLI the prototype calls is `Luau::Parser::parse` plus a JSON encoder, `CLI/src/Ast.cpp:69`;
`luau0-src` 0.22.0 already builds `Ast/src` into the host, `src/lib.rs:176`; verified) or `full_moon` (3.0.0 on crates.io, `cargo search` 2026-10-15; darklua 0.19 uses 2.2.0 with
the `roblox` feature, `darklua/Cargo.toml:37`). The parser should be the same Luau version the place runs, so new
syntax (`const`, attributes, explicit instantiation) never parses differently; a script that fails to parse is left
unwoven and reported (`unparsed`), never dropped.

**Development loop.** `rojo serve` keeps syncing unwoven sources into Studio, so playtests use the shard path and
release builds the woven path. The two must produce the same bytes (§4.3 differential). To test a woven build:
open `release.rbxl` in Studio locally, or publish it as a `Saved` version and run an Open Cloud Luau Execution task
against it (5 per minute per key owner; scripts do not auto-run; data-model changes are not persisted) [ST §4].

**Where the woven place goes.** If a team also edits the published place in Team Create, publishing woven output
puts woven scripts into their editor, which is the refused case by another route. So weaving fits projects whose
scripts are file-managed (Rojo, roblox-ts) and whose release place is written only by CI: a separate release place,
or the start place with development in a copy. What Roblox does to an open Team Create session when Open Cloud
publishes a new version: **unverified**. Studio-only projects stay on the shard path; the least work for them is
nothing (§9 `weave.mode = "off"` is their default by necessity).

**Least work for the developer.** One CI line between build and publish: `lync weave game.rbxl -o release.rbxl`
(or `lync build --weave` doing both). No source annotation, no API change, no per-script opt-in; the report lists
what was woven and what was left (§4).

## 3. The typed API on both solvers and roblox-ts

- **Types come from the source, which weaving never changes.** Game code requires the generated shard and types
  against it exactly as `v5.md` §3.2 specifies (concrete types that narrow on both solvers). luau-analyze, luau-lsp
  and tsc run on the developer's files; the woven copy is compiled, never type-checked, and needs no types: Luau
  erases annotations at compile time, so a woven script with annotations compiles to the same instruction kinds as
  any other (the woven `Weapon` keeps `target: number, aim: Vector3` and compiles; `woven_Weapon.luau.txt`).
- **The built shard stays in the place.** It is the module the woven scripts' bindings still require; woven code
  reaches the runtime through it (`Net.__lync` in the prototype), and every unwoven call still goes through its API.
  Whether it keeps the generic encoders of closed definitions is an option (§9 `weave.dropClosed`), never a
  correctness question: §4's closure rule means no unmodified call reaches them.
- **Hot comments survive.** Directives must precede the first token [luau skill, host.md]; the weaver never inserts
  before the first token (imports go at the end of the binding statement). Verified: the woven `Weapon` keeps
  `--!strict` and `--!optimize 2` on lines 1–2.
- **roblox-ts.** The `.d.ts` is unchanged. What the weaver must recognise in `rbxtsc` output (read from roblox-ts
  source and snapshots, verified):
  - imports compile to `TS.import(script, <base>, "seg", …)` with the export as a field,
    `local value = TS.import(script, script.Parent, "value").value` (`tests/compiler/__snapshots__/imports.test.ts.snap:23`,
    `src/TSTransformer/util/createImportExpression.ts:256`); the resolver treats `TS.import(script, base, segs…)`
    like `base.seg…` and the export field like the binding;
  - a `this: void` member compiles to a dot call, `object.callback(123)`, a method to `object:method(123)`
    (`callbacksVsMethods.test.ts.snap`); v5 §3.6 declares dot calls, so the weaver accepts both `def.fire(v)` and
    `def:fire(v)` (the prototype matches the verb whatever the operator);
  - object literals compile to table constructors; anything else (a spread, a value built elsewhere) is not a
    constructor, so that site stays on the shard (§4). Not run here: an `rbxtsc` build of a fixture, so the share of
    TS sites that compile to resolvable shapes is **unmeasured**.
- **The runtime path** (`Lync.client(schema)`, no build) is not woven: it has no build step by definition.

## 4. Finding call sites and proving a definition closed

Two different questions, kept apart: **can this site be woven** (local, per call) and **is this definition
closed** (global: no unmodified client code can reach its generic API). Weaving never needs closure; only §7's
fact and §9's `dropClosed` do.

### 4.1 Resolution (prototype `weave.py`, verified on `fixture/`)

- **Shard binding:** a local initialised by `require(E)`, where `E` resolves statically to the shard's instance
  path through `game:GetService("X")`, `.Name`, `:WaitForChild("Name")`, `:FindFirstChild("Name")`, `script`,
  `.Parent`, or a local bound to one of those. `TS.import(script, base, segs…)` resolves the same way (not built in
  the prototype). A module whose only export is a binding (`return Net`) is itself a binding source for its
  requirers (not built in the prototype).
- **Definition alias:** a local initialised by `binding.def` (`local chat = Net.chat`).
- **Neither may be reassigned** (an `AstStatAssign` to it is an escape).
- **Wovable site:** a call *statement* `binding.def:fire(ARG)` or `alias:fire(ARG)` (dot or colon), where ARG is a
  table constructor whose keys are constant strings equal to the record's field set (for a non-record codec, any
  single expression). Requests (`invoke`) are expressions and yield; the prototype leaves them on the shard; a
  helper-call form (§5) can weave them.
- **Literal site:** every field value is a constant; the encoder is folded at build time (range checks done by the
  weaver, the bits written as one constant word; `shop()`'s `Net.buy:fire({ item = "sword" })` becomes one
  `begin` plus one 1-bit write; `woven_Weapon.luau.txt` line 22).

### 4.2 Closure

A definition is **closed** when (a) the namespace is complete and (b) every occurrence of its name in the scanned
scripts, as `anything.name` or as the constant string `"name"`, is part of a woven site or an alias declaration
whose uses are all woven.
- **Complete** means every use of every binding is `binding.def` (or an alias), with no other use anywhere:
  passed as an argument, returned (until module aliases are tracked), stored in a table, indexed by a non-constant,
  iterated, or reassigned. Each such use is listed as an escape with script and line.
- **Why (b) as well as (a):** a binding can be obtained by code the resolver cannot follow (a dynamic `require`,
  a module loader). Such code can still reach the API only by naming the definition, unless it iterates or
  computes the name, and iteration or computation over a tracked binding is an escape under (a). The rule
  over-approximates, as `v5-integrity.md` §3 does: an unrelated `player.chat` keeps `chat` open.
- **Scope:** every script in the built place, client and server, any container: a `ModuleScript` in
  `ServerStorage` that a server clones into a client is in the place and scanned. What is outside the guarantee:
  code that is not in the place file (an asset inserted at run time), and, in Studio, the command bar and plugins.
- **Result on the fixture** (`weave_report.json`): 4 sites woven (one `strike`, one six-line `move6`, one literal
  `buy`, one `chat` through an alias), 1 left (`Net.buy:invoke`, expression context); closed: `strike`, `move6`,
  `chat` (and `announce`, which no client code names); open: `buy` (an unwoven site). With one module that stores
  the binding in a table (`fixture/variant-escape/Hud.luau`, `registry.net = Net`), the namespace is incomplete and
  nothing is closed, while the same 4 sites are still woven (`weave_report_escape.json`).
- **Coverage on real games: unmeasured.** Frameworks that hold the namespace in a field (`self.Net`, a services
  table) make it incomplete; they still get woven sites wherever a site is a direct binding call.

**A gap in `v5-integrity.md` §3, found while deriving (b)** (reasoned, not run): its rule makes a namespace
incomplete "only when its shard value is indexed with a non-literal expression" and treats passing the namespace
around as no escape. Generalised iteration (`for name, d in Net do d:fire(x) end`) is not an index expression and
names no definition, so a definition fired only that way is inferred unreachable and an unmodified client produces
`unreachable` (`declared` 0) with no listed cause. Iteration of a binding, and any use of a value that escaped
into code the scan does not follow, should make the namespace incomplete there too.

### 4.3 What the weaver checks before it writes

| Check | Failure mode it prevents | On failure |
|---|---|---|
| parse succeeds at the place's Luau version | a script the parser misreads | script left unwoven, listed `unparsed` |
| no local named `type`, `math`, `buffer`, `vector` or `__lync_*` is in scope at a site | woven code calling a shadowed builtin | site left unwoven (the prototype captures `buffer.writebits` at the binding and prefixes its own names, but does not yet check `type`/`math`: a gap) |
| the woven script compiles (`luau-compile`, or mlua's compiler in the host) | the 200-local, 200-upvalue and 255-register limits [GS §4.2]: woven imports add locals at the binding's scope and upvalues to each function with a site | script left unwoven |
| line count unchanged (`assert` in `weave.py`) | shifted error lines (§5) | build error (a weaver bug) |
| differential: each woven site's bytes equal the shard encoder's for sampled values, and refusals raise the same message | a woven encoder that differs from the shard | build error |

The differential was run on the fixture: original and woven `Weapon` driven with 200 sampled value sets each
(`diff_drive.luau`) produce identical runtime bytes (3,466 B of bits and tails, FNV-1a `b6d1ccd0`) and the same
refusal text for an out-of-range field, at both `-O1` and `-O2` (`diff.out`).

## 5. Line preservation and error positions (source maps)

- **Line-preserving splice, so the map is the identity.** Each replacement holds exactly as many newlines as the
  text it replaces; each argument expression keeps its original text and starts on its original line; the encoder
  goes on the statement's last line; imports go on the binding statement's last line. Every line of every woven
  script keeps its number, and instance paths do not change, so Rojo's `sourcemap.json` (instance path → file)
  maps woven errors to the developer's file and line with no extra artefact. [ST §10] proposed a generated-line
  map; it is not needed. Verified: `Weapon` has 27 lines before and after; a runtime error at its line 23 reports
  line 23 in both versions; `weave.py` asserts the count for every script.
- **luau-lsp needs nothing**: it analyses the source files, which weaving never touches.
- **Which form keeps refusal lines exact** (`error_lines.luau`, `error_lines.out`; luau 0.740; v5's caller walk
  skips Lync frames and frames named `__lync*`):

  | Form | `-O1` (Studio) | `-O2` (live) |
  |---|---|---|
  | inline at the site (W2) | call line | call line |
  | helper in a table, `__lync.def(…)` (W1t) | call line | call line |
  | `local function __lync_def(…)` helper (W1) | call line | **the helper's line**: inlined at `-O2`, so its frame is gone |

  W1 is excluded: Studio and live would report different lines, the hazard `v5.md` §7.1 already avoids for
  `error(msg, 2)`.
- **Multi-line calls.** An unwoven multi-line call's refusal reports the call's *first* line (`-O1`, checked);
  woven checks run on the *last* line. Fix at no hot-path cost: the weaver passes the site's source line as a
  constant to the cold `fail` call (`__lync_fail(code, path, got, LINE)`), so the position is exact whatever the
  layout, inlining or optimisation level, and the woven error path skips the `debug.info` walk (133–619 ns,
  `v5.md` §7.1). Cost: one `LOADN` per check, in the cold branch only.
- **Columns** are not in Luau debug info (`debug.info` gives source, line, name, arity, function), so packing a
  site onto one line loses nothing a stack trace or the Error Report shows.
- **Stack traces** through inline sites contain only the game's own frames; through W1t, one `__lync.def` frame.
