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

- [x] 0. Bottom line
- [x] 1. The refusal, re-tested
- [x] 2. Where the transform runs
- [x] 3. The typed API on both solvers and roblox-ts
- [x] 4. Finding call sites and proving a definition closed
- [x] 5. Line preservation and error positions (source maps)
- [x] 6. Cost: bytecode, load, encode and decode time, build time
- [x] 7. Dual-purpose form: site-bound wire ids
- [x] 8. Interaction with seed, rotation, per-player variants, tag, schema hash
- [x] 9. Options
- [x] Implications

## 0. Bottom line

1. **Weaving works when it runs on built output only.** A pass over the place file that `rojo build` produced
   rewrites each call site's built copy and never opens a developer file or Studio script, so the merge and
   `UpdateSourceAsync` reasons for the refusal do not arise. Verified end to end on a fixture: `rojo build` → Lune
   dump → weave → Lune write → re-read identical (§2). A Studio plugin cannot do it without rewriting the open
   place; Studio-only projects stay on shards.
2. **The typed API is untouched.** Game code still requires and types against the shard on both solvers and in
   roblox-ts; only built copies change, and the shard stays in the place as fallback (§3).
3. **The 5.0x is reproduced exactly and is one shape's bound** (50 sites of one definition, full encoder inlined
   at each). Realistic shapes cost 1.03–1.20x (scalar call into the shard) to 1.3–3.0x (inline) of the unwoven
   client's Lync bytecode, or 0.43x when the built shard drops closed encoders; 10–75 µs more load per join (§6.1–6.2).
4. **It is faster, which the record denied.** Per client call, interpreted: 1.3–1.7x on variable sites and 2.9–3.5x
   on literal sites against the specified shard entry; 1.3–3.0x against a shard without the rollback `pcall`. The
   gain is the payload table and method dispatch removed, and checks folded at literal sites; the `pcall` part is
   available to shards without weaving (§6.3). Server handler unpacking adds 1.23–1.40x per delivered message (§6.4).
5. **On the server, call into the native shard; never inline into interpreted scripts** (W3 beats inline there),
   and never use a `local function` helper: at `-O2` it is inlined and refusals report the wrong line (§5, §6.3).
6. **Line-preserving splices make the source map the identity**: every line keeps its number, so Rojo's
   sourcemap and the Error Report point at the developer's file and line with no map artefact (§5).
7. **Correctness never depends on finding every site**: an unresolved call stays on the shard. Completeness only
   gates the security fact (§4).
8. **A dual-purpose form holds: site-bound wire ids.** Woven sites send ids the shard API never sends; a message
   on the generic id of a definition whose every client reference was woven is then a server-observed fact with an
   exact trigger, pricing the cheapest documented route (requiring the client module and calling its API) at
   +1–2 bits per upstream run for typical counts, while literal fields leave the wire (§7). It needs a complete
   namespace, which frameworks that pass the namespace around do not give.
9. **Found on the way:** `v5-integrity.md` §3's reachability rule misses iteration over the namespace (§4.2).

## 1. The refusal, re-tested

The record gives these reasons (`v5-changes.md`: the draft-2 refusals table and 3.4→3.5 part 2; [CSB §3.2]). Each, re-tested:

| Reason | Holds? | Evidence |
|---|---|---|
| Rewrites the developer's scripts each build: merge conflicts, `UpdateSourceAsync` races | **No, if the transform runs on built output only.** A post-build pass over the `.rbxl` never opens a source file or a Studio script | §2; verified end to end: `rojo build` → Lune dump → `weave.py` → Lune apply → re-read gives the woven sources byte for byte (`fixture/`, `place_io.luau`) |
| Removes the typed shard API | **No.** Game code still requires the shard and types against it; only the built copy of each script changes | §3 |
| 5.0x bytecode | **Reproduced, but it is the worst case of one shape**, not a property of weaving | §6.1: the probe re-run gives 22,927 against 4,587 B again (`size_orig.out`, 0.742); realistic shapes give 0.43x to 3.0x of the unwoven client total, and 4.8x when 50 sites fire one definition |
| No speed gain ("a shared call to a straight-line encoder is already a fast path", [CSB §3.2]; repeated in [ST §10]) | **No.** Weaving removes the payload table, the method dispatch and, at literal sites, every check and the variant dispatch; measured 1.3–3.0x faster per call than a shard without the rollback `pcall`, 1.3–3.5x faster than the specified shard entry | §6.3 |
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
nothing: they never run the weave step, and no option applies.

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

## 6. Cost

Forms measured (`gen.py`; one emitter writes every form, and S0 against W2 is checked byte for byte by the §4.3 differential):

| Form | Call site | What runs |
|---|---|---|
| S0 | `Net.def:fire({ … })` | the shard entry as specified: one `pcall` around the encoder for rollback (`v5.md` §4.2) |
| S1 | same | shard entry, check-then-write, no `pcall` (a shard-side change, available without weaving) |
| W3 | `Internal.def(a, b, …)` | woven call into the shard's scalar entry: no payload table, no method dispatch, no duplication |
| W1t | `__lync.def(a, b, …)` | woven helper, one per definition per script, in a table (not inlined) |
| W2 | inline | woven encoder inline at the site, on the site's lines |

Every form keeps the runtime's `begin` (run header) and `reserve` (bit cursor) as calls into the runtime.

### 6.1 Bytecode (verified, `size.py`, `size.out`; luau-compile 0.742 `-O2`)

**The 5.0x, re-derived.** The original probe (`client-security-build/placement/size.py`) re-run on 0.740 and 0.742
gives the same bytes: 22,927 B inline against 4,587 B shared at `-g0`, 27,090 against 5,484 at `-g1`
(`size_orig.out`). It measures one 3-field encoder inlined at 50 sites of **one** definition against one copy plus
50 one-line stubs. The ratio tends to (inlined body) / (call stub) as sites per definition grow, and to about 1
when each definition has one site. It is a bound for one shape, not a cost of weaving.

**Realistic shapes**: 20 definitions cycling the five shapes of `gen.py` (`strike` 40-bit int + direction, `move6`
six fields, `chat` string, `buy` literal enum, `announce` literal union), s sites per definition, each site in its
own script ("spread") or all of a definition's sites in one script ("clustered"). Total = client shard + Lync-
attributable bytes of every script (script minus the same script with no site). `-g1` (line info, as shipped):

| defs × sites | placement | U (unwoven) | W3 | W1t | W2 | W2r (W2, closed encoders dropped from the built shard) |
|---|---|---|---|---|---|---|
| 20 × 1 | spread | 30,877 B (1.00) | 1.03 | 1.41 | 1.34 | 0.43 |
| 20 × 2 | spread | 33,359 (1.00) | 1.06 | 1.75 | 1.64 | 0.79 |
| 20 × 3 | spread | 35,841 (1.00) | 1.09 | 2.05 | 1.89 | 1.10 |
| 20 × 3 | clustered | 34,801 (1.00) | 1.02 | 1.31 | 1.71 | 0.90 |
| 20 × 5 | spread | 40,805 (1.00) | 1.13 | 2.54 | 2.30 | 1.61 |
| 20 × 10 | spread | 53,215 (1.00) | 1.20 | 3.36 | 2.99 | 2.46 |
| 1 × 50 | spread | 8,557 (1.00) | 0.78 | 5.35 | 4.78 | 4.59 |
| 5 × 50 | clustered | 32,042 (1.00) | 0.94 | 0.77 | 3.77 | 3.54 |

- Per site: an unwoven call site costs about 124 B (`-g1`, mostly the payload table constructor); an inline site
  about 650 B; a W3 call about 175 B, and less than U where a site's table had many fields (1 × 50: 0.78x).
- W1t pays one helper per script, so it is cheapest when sites cluster (5 × 50 clustered: 0.77x) and most
  expensive when each script has one site.
- **Bytecode is bounded by choosing the form per site**: inline where a definition has few sites, W3 where it has
  many (§9 `weave.inlineMaxSites`). W3 never exceeds 1.20x in these shapes.

### 6.2 Load time

`luau_load` costs 0.5–2.4 ns per bytecode byte on this Xeon [GS §5.1]; measured here (`load.out`, 0.742,
median of 7 × 20,000 loads): the fixture `Weapon` loads in 1.90 µs unwoven (852 B) and 2.87 µs woven (2,542 B).
At the realistic shapes above, weaving adds 10–32 KB to a client, about 10–75 µs per join; per-player variants
are not involved (§8). Roblox's own per-KB figures and any cross-server bytecode cache: not found [GS §5.2].
Native compilation (server only) is costlier: 183 µs for the unwoven `Weapon` against 424 µs woven, if a server
script with woven sites is `--!native`; it also draws on the per-game native code limit (documented: "a limit on
the total allowed amount of natively compiled code in a game", [native-code-gen](https://create.roblox.com/docs/luau/native-code-gen)).

### 6.3 Encode time per call (verified, `bench.md`; median ns over 3 passes of 11 × 200,000 calls, lowest minimum in brackets)

**Client** (everything interpreted: Roblox clients run no native code, documented and [GS §4.1]):

| Shape | S0 | S1 | W3 | W1t | W2 | best woven / S1 | best woven / S0 |
|---|---|---|---|---|---|---|---|
| `move6` (6 fields) | 605 [544] | 537 [477] | 562 [399] | 416 [366] | 437 [363] | 1.37 (W1 391) | 1.55 |
| `strike` (int + direction) | 819 [696] | 798 [641] | 676 [596] | 664 [596] | 663 [564] | 1.27 (W1 629) | 1.30 |
| `chat` (string) | 244 [224] | 196 [176] | 164 [144] | 172 [146] | 144 [129] | 1.36 | 1.69 |
| `buy`, literal `{ item = "sword" }` | 247 [221] | 172 [154] | — | 108 [94] | 85 [79] | 2.02 | 2.91 |
| `announce`-shaped literal union | 296 [264] | 251 [220] | — | 110 [98] | 84 [79] | 2.99 | 3.52 |

Where the time goes:
- **S0 → S1, 45–110 ns:** the rollback `pcall`. Not a weaving gain: a shard can check every field before writing
  any bit, and needs the `pcall` only for `t.convert`/`t.custom`, whose game code can raise mid-encode.
- **S1 → best woven, 50–170 ns on variable sites:** the payload table (allocation plus GC) and the method dispatch.
  Weave-only, because only the build sees the call site's table constructor.
- **Literal sites, 85–165 ns:** checks and variant dispatch done at build time; the encode becomes one run header,
  one reserve and one constant write. Weave-only.
- The floor is the two runtime calls: an inline literal site costs 84 ns, of which the write is a few.

**Server** (runtime and shard native as a `--!native` shard; game script as Roblox compiles it, interpreted except
`@native` functions):

| Shape | S0 | S1 | W3 | W1n (`@native` local helper) | W1t | W2 |
|---|---|---|---|---|---|---|
| `move6` | 453 | 378 | 291 | 269 | 407 | 395 |
| `strike` | 471 | 433 | 333 | 363 | 411 | 384 |
| `chat` | 176 | 124 | 115 | 113 | 148 | 126 |

On the server, inlining into an interpreted script throws away the shard's native code: W2 is slower than W3 there.
W1n is fast but is a `local function` (the `-O2` line hazard of §5) and makes its whole script optimisation level 2
with type info [luau skill, performance.md]. So server-side sites use W3.

### 6.4 Decode time: handler unpacking (verified, `bench.md`, `move6`)

The server decodes a message, builds the payload table and calls each handler with `(player, value)` (D0). A
woven handler whose parameter is only read as `value.field` can receive the fields as arguments instead (D1); the
generated delivery passes the decoded locals and builds no table. Per message: client 419 → 342 ns (1.23x), server
355 → 262 ns (1.36x), all-native 323 → 230 ns (1.40x). Precondition the weaver must prove: the parameter is never
written, passed, returned, captured by a closure that escapes, or indexed by a non-constant; otherwise the handler
gets the table. Rewriting handler bodies is more transform than call-site weaving (every `v.f` in the body is
renamed); not in the prototype.

### 6.5 Build time (verified, `buildtime.out`)

The prototype (Python, one `luau-ast` process per script) over 303 scripts, 1.68 MB of source, 901 sites: 3.06 s,
of which 2.84 s parse and analysis. One `luau-ast` call on a 5.6 KB script takes 3.7 ms including process start.
An in-process parser in the Rust host would remove the per-script process; its figure is **unmeasured**.

### 6.6 Developer effort

None in source. One CI step (§2). The cost is in reading: a woven release script is denser than its source
(`woven_Weapon.luau.txt`), so a developer debugging a release build reads woven lines in Studio; line numbers and
paths still match the source (§5).

## 7. Dual-purpose form: site-bound wire ids

Weaving alone is a speed measure: woven and shard calls write identical bytes, so the server cannot tell them
apart. One addition makes the same build output a security measure as well, and it holds up.

### 7.1 Mechanism

- **Generic ids stay** exactly as `v5.md` §4.6 defines them; the runtime path and every unwoven call use them.
- **A woven build adds ids in the up space** (client sites only): one per woven site (`weave.ids = "site"`) or one
  per woven definition (`"definition"`). Canonical order: by (script instance path, line), after the generic ids.
  They go through the per-server permutation like every other id (`v5.md` §4.5), at no extra cost.
- **A site id's layout** is its definition's layout minus the fields the site writes as build-time constants
  ("site" mode only). The server's site table maps each site id to (definition, constant fields, remaining layout);
  its decoder reads the remaining fields under the same canonical rules and fills the constants. A fully literal
  site sends no payload bits at all.
- **Delivery is unchanged:** a site-id message is delivered as a message of its definition: the same `limit`
  bucket, `validate`, handlers, element charge (W = 1 + E(remaining fields)). Game code sees no difference.
- **The fact.** A message on the *generic* id of a **closed** definition (§4.2) is delivered and reported. Its
  exact trigger is that id; its known causes on an unmodified client are code not in the woven place file (an asset
  inserted at run time) firing the definition, and, in Studio only, the command bar or a plugin calling the shard.
  Within the build's coverage there is no other cause: every unmodified call of a closed definition uses a site id
  by construction. Two shapes for the code, for the lead (principle 4 favours the first): extend `unreachable`
  (`v5-integrity.md` §3) with evidence `generic` (1 for this trigger, 0 otherwise), since both mean "a path the
  build found no client code using"; or a new reason. Evidence is numbers only, as every fact.

### 7.2 What it does, and how strong it is

- **It prices the cheapest documented route.** The API driver that requires the client module and calls a
  definition's method (`require(…Network).…send(…)`, the 2026 ByteNet thread [CS §1.4]) needs no knowledge of the
  wire. In a woven build that call still works, and for every closed definition it now produces a server-side
  fact with an exact trigger on the first message. That is stronger evidence than the caller probe
  (`v5-integrity.md` §4), whose counts are client-stated; here the server observes the id itself.
- **What defeats it, by class of capability:** reading the woven bytecode of the game's own scripts (decompiler or
  constant reads, which executors have [ST §9]) and re-deriving, per build, the site ids and site layouts, then
  reading the per-server permutation per session as any byte-level tool must; or calling the game's own functions
  that contain the sites, which then send exactly what game code sends. Both are per-build or per-game work; the
  first changes whenever the game's scripts or the build seed change.
- **It narrows what a site id can carry.** A constant field is not on the wire, so a site id cannot vary it: a
  client that wants a value no site writes as a literal must use the generic id (the fact) or another site's id.
  How much this narrows depends on how many fields game code writes as literals; most variable fields stay
  variable. It is reported as structure, not judged.
- **It makes the caller probe's source check exact per message** (`v5-integrity.md` §4): a site id names one
  script, where a definition names a list.
- **Limits.** Closure needs a complete namespace (§4.2): a game that stores the namespace in a framework table gets
  no closed definitions and so no fact, though it still gets woven speed. Unwoven builds (Studio, `rojo serve`)
  close nothing, so the fact cannot fire there.

### 7.3 Cost

- **Id width.** Up-space ids grow from u(⌈log2 D⌉) to u(⌈log2(D + S)⌉) bits, paid once per run (upstream runs
  are mostly single messages). For D = 20 up definitions: S = 20 sites gives 6 bits (+1), S = 60 or 100 gives 7
  (+2), S = 300 gives 9 (+4). At the busy model's 70 upstream frames a second (`v5.md` §4.1) with one or two runs
  each, +1 bit costs 9–18 B/s per player, +2 bits 18–35 B/s. `"definition"` mode costs at most +1 bit
  (u(⌈log2 2D⌉)).
- **Constant elision saves** the constant fields' bits per message: 1 bit for `buy`, 8 for the `announce`-shaped
  literal, the whole payload at a fully literal site.
- **Runs split by site:** consecutive messages of one definition from two sites become two runs (an id and a
  count each). Upstream runs are short, so this is small; downstream is unaffected because site ids are only in the
  up space (server-sent sites gain nothing from provenance: the server is trusted).
- **Server memory:** one site-table entry per site; one decoder per site (generated into the server shard,
  which grows by about one decoder per site).
- **Handshake:** client and server must agree on the site table. Seeds alone do not guarantee it (two weaves of
  different scripts at one fixed seed), so `HELLO` needs the weave's identity: a u32 hash of the site table, 0
  when unwoven (protocol version 2), with `schemaMismatch` evidence `weaveDiffers`. 4 B per namespace per
  connection.
- **Planner and tests:** the site table is an IR extension; the differential test (`v5.md` §2) gains a site case:
  every site's bytes decode on the server to the same value as the generic encoding of the same call.

### 7.4 Forms considered and set aside

- **Removing the generic API from the built shard** (instead of reporting its use): the cheapest driver then gets
  "attempt to call a nil value" instead of a fact, and the server learns nothing. Reporting gives the developer the
  fact; dropping the encoders (`weave.dropClosed`) is still available for size, and then the generic id stays
  decodable on the server, so the fact still fires for a driver that brings its own encoder.
- **Per-site field order** (a rotation per site): adds no recurring work beyond site layouts, which a tool reading
  woven bytecode reads in the same pass; it costs nothing either, so it is an option, not a measure.
- **Stripping the shared schema module from the client build** is independent of weaving (per `v5.md` §3.2, a shard
  evaluates the schema only for Studio's `staleShard` check). It removes the definition names an API driver browses, which is
  also the bait `:trap()` relies on; a trade the lead should make explicitly, not as a side effect of weaving.

## 8. Interaction with seed, rotation, per-player variants, tag, schema hash

| Item | Interaction | Rule |
|---|---|---|
| Build seed | woven fragments, site table and shards must come from one planner run | `lync build --weave` (or `lync weave` regenerating the shards it embeds) plans once at one seed and writes all three; a fragment never comes from a different run than the shard beside it. With `"release"`, client and server from different runs already fail as `schemaMismatch`, `seedDiffers` 1 (`v5-integrity.md` §2) |
| Field rotation | woven encoders write the rotated order: the fragment is emitted from the same IR as the shard encoder | no change; zero run-time cost as for shards [CSB §2.3]; the differential test runs at fixed nonzero seeds too |
| Tag | untouched: the tag is computed at flush over the frame (`v5.md` §4.5); woven code only writes rows through `begin`/`reserve` | site ids are frame bits like any id, covered by `tag.cover` |
| Per-server permutation | site ids are ids in the up space and permute with it | zero cost (`v5.md` §4.5) |
| Per-player variants | excluded for woven code: woven LocalScripts in `StarterPlayerScripts` are copied by the engine to every player, and `PlayerScripts` is not accessible to the server [GS §2.1]; the only per-player container is `PlayerGui` [GS §2] | weaving and per-player shard variants do not combine; per-session variation (key, permutation) is unaffected |
| Schema hash | unchanged: sites are not schema, the hash stays the seed-0 serialization (`v5.md` §4.7) | the weave's identity travels separately (§7.3: `weaveHash` u32 in `HELLO`) |
| `staleShard` | applies to the unwoven development path; a woven build regenerates its shards | no change |
| Reachability (`v5-integrity.md` §3) | weaving's scan is a superset of the reachability scan: an unreferenced definition is closed with no sites | one scan feeds both; fix the iteration gap of §4.2 in that scan |
| `limit`, traps, `validate` | per definition; site ids map to their definition first | no change; a trapped definition with client sites is the developer's declaration mistake as today |
| Golden frames | defined at seed 0, unwoven: unchanged | add vectors for a woven fixture: a site id, a fully literal site with no payload bits |
| Collections `patch` (milestone 4) | a woven `patch(key, { health = 90 })` knows its key set at build time: no key iteration, and `unknownPatchKey` becomes a build diagnostic at that site | inferred; not measured |

## 9. Options

Build-time, in `lync.toml` under `[weave]`, read only by `lync weave` / `lync build --weave` (§2). A project that
never runs that step is unaffected by all of them.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `weave.inlineMaxSites` | integer | client sites per definition | 0–65,535 (0: never inline) | 2 | per inlined site about +530 B of bytecode over an unwoven site (`-g1`, §6.1); a definition with more sites uses the scalar call (W3, about +50 B per site); speed of W3 and W2 within the noise except literal sites (§6.3) |
| `weave.literals` | boolean | — | — | true | none at run time (fewer instructions); a literal site's checks move to the build, and a literal the codec refuses becomes a build diagnostic at that line |
| `weave.server` | `"off"` \| `"call"` | — | — | `"call"` | server sites call the native shard's scalar entry (W3): about +50 B per site, 1.4–1.6x faster than S0 on the server (§6.3); inlining is not offered server-side because it loses native code |
| `weave.handlers` | boolean | — | — | false | handler bodies whose parameter is only read as `value.field` are rewritten to take fields as arguments: 1.23x (client) to 1.36x (server) per delivered message (§6.4); build time to prove the precondition; not prototyped |
| `weave.ids` | `"generic"` \| `"definition"` \| `"site"` | — | — | `"site"` | `"definition"`: ≤ +1 bit per upstream run and the closed-generic fact; `"site"`: +⌈log2(D + S)⌉ − ⌈log2 D⌉ bits per upstream run (+1 to +4 for D = 20, S = 20–300), constant elision, the fact, `weaveHash` (4 B per namespace per connection) in `HELLO` (§7.3); `"generic"`: no change to the wire |
| `weave.dropClosed` | boolean | — | — | false | removes the generic encoders of closed definitions from the built client shard: the client shard shrinks to its skeleton for those definitions (W2r, §6.1); calls from code outside the build then raise at the caller; the server still decodes and reports the generic id |
| `check.weaveCoverage` | `"off"` \| `"warn"` \| `"error"` | — | — | `"warn"` | severity of the build diagnostics below; build time only |

Build diagnostics (LSP shape, `v5-tooling.md` §3), each with script instance path and line:
- `weaveUnresolved`: a call left on the shard; evidence `reason` (1 expression context, 2 argument not a table
  constructor, 3 keys differ from the record, 4 a builtin name shadowed at the site, 5 the woven script failed to
  compile); the definition stays open.
- `weaveEscape`: a binding used other than as `binding.def` (passed, returned, stored, iterated, reassigned,
  indexed by a non-constant); the namespace is incomplete and nothing in it is closed.
- `weaveUnparsed`: a script the parser refused; left unwoven.

The manifest (`v5-tooling.md` §1) records, per definition: closed or open (with the first reason), woven sites
(script, line, form, literal), and the weave hash.

## Implications

1. Lift the refusal: adopt weaving as a build output over the built place, CLI only, never over source (§1, §2).
2. Keep the shard as the type module and fallback in every woven build; weave only what resolves (§3, §4.1).
3. Use the Rust host with Luau's own parser via a C++ shim and rbx-dom for place I/O; Lune was enough to prove it (§2).
4. Splice line for line and pass each site's line to `fail`; ship no line map (§5).
5. Client sites: inline up to `inlineMaxSites`, scalar call beyond; server sites: scalar call into the native shard only (§6.1, §6.3).
6. Never emit `local function` helpers; use inline or a table helper (§5, `error_lines.out`).
7. Fold literal sites at build time; turn a refused literal into a build diagnostic (§4.1, §6.3).
8. Separately, drop the rollback `pcall` from shard entries for codecs without `t.convert`/`t.custom` (check-then-write): 45–110 ns per call, no weaving needed (§6.3).
9. Adopt site-bound ids (`weave.ids = "site"`) and report generic-id messages on closed definitions as a fact, preferably `unreachable` with evidence `generic` (§7).
10. Add `weaveHash` to `HELLO` (protocol version 2) before any site id ships (§7.3).
11. Define closure as in §4.2, compute it in the same scan as reachability, and fix that scan's iteration gap (§4.2, §8).
12. Gate every woven script on compile, line count and a per-site byte differential in CI (§4.3).
13. Keep Studio-only projects on shards, and say in the docs that woven places must be written only by CI, not edited in Team Create (§2).
14. Treat handler unpacking (`weave.handlers`) as a later step after call-site weaving: real gain, larger transform, unprototyped (§6.4).
15. Decide schema stripping for clients separately from weaving; it trades away trap bait (§7.4).
16. Measure before release: share of resolvable sites in real Rojo and roblox-ts games, phone load per KB, and Team Create behaviour under Open Cloud publishing (§4.2, §6.2, §2).
