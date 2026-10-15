# Client-side security for Lync v5: build-time and whole-project transformation

Researcher brief, 2026-10-15. Scope: everything a Lync build/edit-time tool can do *outside the running wire
protocol* to raise the cost of exploiting a game that uses Lync — polymorphic builds, scattering and dissolving
network code (the developer's *and Lync's own*) across the game tree, build manifests, per-release rotation, and
the precise developer-facing configuration surface. Server-side hard guarantees (per-player budgets before decode,
strict canonical decode, server-only validation/rate limits) are assumed, not re-argued. The runtime/wire side
(timing, environment checks, wire/runtime randomization, attacker model, server signals) is covered by the second
researcher in `client-security.md`; I read it and do not repeat it. Where the two meet I point at it.

Labels: **verified** = I ran it on the pinned toolchain (`luau`/`luau-compile` 0.740, Intel Xeon 2.1 GHz, Linux;
API dump Roblox 0.741.19) or read the tool's own source in `.data/projects`. **documented** = official docs or a
tool's own docs. **reported** = third party. **unverified** = my inference. Probe/bench files:
`.data/docs/probes/client-security-build/*.luau`.

The author does **not** want a `security = "hardened"` preset. Every measure below is phrased as a named, typed,
unit-bearing knob with a default and a cost, so the surface in §4 is built from them, not bolted on.

---

## 0. Bottom line

1. **The ceiling is set elsewhere.** The runtime brief's finding stands: the cheapest real attack on a typed
   library is `require(game.ReplicatedStorage.Net).Chat.send({...})` — calling the honest client's own encoder.
   No build transformation touches that, because the transformed code still exposes *some* callable that produces
   valid frames, and an injected script at identity 8 can reach it (`getgc`, `getsenv`, `getloadedmodules` — all
   documented executor APIs). **Build-time work buys cost and breadth-of-break, never a wall.** Be honest about
   this in every knob's doc string or the feature becomes theatre the author already rejected.
2. **What build-time genuinely buys, that runtime-only cannot:** (a) *polymorphism* — a different code shape, names,
   constants, ordering and module split every release, so a static patch, a signature scan, or a public paste
   script written against build N breaks on build N+1 for zero marginal attacker-value-per-game; (b) *dissolution*
   — there is no single `Net` module to decompile, hook, or `require`, because the codec and remote handles are
   generated into the game's own scripts; (c) *provenance* — the build knows the complete set of scripts and their
   hashes, so it can emit a manifest the game checks itself against and refuse to ship if a client script touches a
   raw remote; (d) *specialization* — the wire format, ids, and keyed-tag constants baked per build (and, narrowly,
   per server) so one universal bypass does not cover every Lync game.
3. **Lync's unique lever is that it is open source and shared.** A measure identical across every Lync game invites
   one universal bypass authored once and pasted forever. The entire value of build-time polymorphism is to make
   the *per-game, per-release* attacker cost non-zero while keeping the *library author's* cost zero. That is only
   achievable by generation, not by shipping a fixed obfuscated blob.
4. **Interpreted client is the hard budget.** Clients run the Luau interpreter; native codegen is server/Studio
   only (runtime brief §2, confirmed: no client `loadstring`, API dump 0.741). So every transformation is measured
   against the interpreter. My benches (§1.1): a shared encoder call is ~88 ns, inlined ~53–85 ns, a toy per-op VM
   interpreter **7.3× slower** (§3). VM obfuscation of the hot encode path is off the table on perf grounds alone.
5. **Per-client code variation on Roblox is nearly impossible and must not be promised.** The client receives the
   place's compiled bytecode as-is; there is no client compiler. The only honest "per-client" variation is
   *server-generated module source* delivered through server-only `loadstring`, or *cloned/parented ModuleScripts*
   per player — both real but narrow, both with sharp limits (§1.7). Everything else is per-*build*, not
   per-client.
6. **Refuse-to-ship list exists and is load-bearing** (§Implications). A VM-ing codec, a per-client-source promise,
   a Creator-Store-illegal obfuscation default, and any check whose only effect is a client-side ban all get
   refused by name.

---

## 1. Whole-project and whole-library transformation (Question 1)

A Lync build step sees the full Rojo project (`sourcemap.json` + every `.luau`) or, via a Studio plugin, the whole
DataModel. It can rewrite three bodies of material with equal freedom: **the developer's game scripts**, **Lync's
own runtime**, and **the generated codecs/handshake/transport**. I evaluate each technique the same way: mechanism,
what it breaks, recovery time, perf, bytecode/decompiler effect, debuggability, determinism, maintenance.

### 1.1 Baseline measurements (so every claim below has a number)

`.data/docs/probes/client-security-build/bench2.luau`, min-of-7, 500k iterations, encoding a `{id:u16, x/y/z:f32, flags:u8, name:string}`
record. **verified**:

| Encoder shape | -O1 | -O2 |
|---|---|---|
| shared via module table (`Lync.enc(...)`) | 88.5 ns | 87.7 ns |
| shared local upvalue | 110.7 ns | 79.1 ns |
| inlined at call site | 53.0 ns | 85.4 ns |
| inlined, permuted field order + id xor-mask | 74.0 ns | 63.6 ns |
| shared + per-session id permutation lookup | 113.5 ns | 90.4 ns |
| shared + per-call identity canary (`Lync.enc ~= ref`) | 121.9 ns | 87.8 ns |
| `debug.info(f,"s")` source canary, alone | 43.9 ns | 35.5 ns |
| toy per-op VM interpreter (6 ops) | 243.4 ns | 231.8 ns |
| register-VM (IronBrew-style dispatch, `.data/docs/probes/client-security-build/vm.luau`) | 763 ns | 719 ns (**7.3×**) |

Reading: field permutation and id masking are *free* (same op count, folds to constants, §1.5). A per-call
identity canary adds ~15–30 ns — tolerable off the hot path, not on it. Inlining is not reliably faster on the
interpreter (it trades a `CALL` for register pressure; -O2 sometimes made the inlined form *slower* because the
shared call is a clean `GETIMPORT`+`CALL`). **The perf argument for inlining is weak; the security argument
(no single function to hook) is the real one.**

Bytecode size (`.data/docs/probes/client-security-build/*.luau`, `luau-compile --binary`), 50 call sites: shared encoder **3928 B** (`-g0`)
/ 5245 B (`-g1`); fully inlined **17515 B** / 21125 B. Inlining is ~4.5× the bytecode. This matters: Creator Store
moderation flags "unnecessarily large scripts" (§2, documented), and Zap's single-giant-file problem (research.md
Zap #225) is a real Luau register/constant-limit wall. **Inline selectively, never wholesale.**

### 1.2 Scatter / dissolve network code into the game's own scripts

**Mechanism.** The build parses `sourcemap.json`, finds every call to a Lync API (`Chat.send`, `Chat.on`, etc.),
and emits the encoder/decoder body *at that call site's module* instead of in a central `Net` module. The remote
handles (the `RemoteEvent`/`UnreliableRemoteEvent` references), the definition-id table, and the keyed-tag logic
are likewise split: id constants live in one module, the tag key in another, the flush loop in a third, each under
a build-chosen name, each required by the next through a `convert_require`-rewritten path. There is no file called
`Net` and no single ModuleScript whose `Source` or GC closure set is "the networking library".

**What it breaks.** (a) `getloadedmodules()` / `getscripts()` enumeration (Potassium live sample: 460 scripts, 523
loaded modules) no longer yields an obvious target — the attacker must find the pieces among hundreds of game
modules. (b) `require(path)` by a copy-paste script fails: there is no stable path. (c) A decompile-and-read pass
must reconstruct the protocol from fragments across many files rather than reading one annotated module. (d) A
signature scan for "the Lync encoder" has no single signature.

**Recovery.** A competent attacker recovers in **minutes to an hour per game**, not per build-of-the-same-game.
They find the `UnreliableRemoteEvent`, set a `__namecall` / raknet receive hook, watch which Lua closures run in
the stack when a frame goes out (`getcallstack`, `getscriptthread`), and call those closures directly. Scatter
raises the *find* cost and kills blind paste scripts; it does not stop someone who instruments the live client.
This is the §0.1 ceiling in concrete form.

**Perf.** Neutral-to-good: scattered encoders are the "inlined at call site" row (53–85 ns) or small per-module
shared functions (88 ns). No VM, no indirection.

**Bytecode/decompiler.** Decompilers (Konstant V2/V3-in-progress, Unluau, Potassium's integrated `decompile`,
the browser tools LuaUndo/Luacid — all 2026, **reported**) recover *structure and control flow* well; parameter
names come back `UNNAMED_<addr>` (Potassium `decompile` on functions, **documented**). Scattering does not defeat
any decompiler — each fragment still decompiles cleanly — it defeats the *human* reading task and all path-based
automation. Honest framing: **this is anti-automation and anti-paste, not anti-decompile.**

**Debuggability.** This is the expensive part. A stack trace now points into `PlayerScripts.Weapons.Recoil:142`
instead of `Net:88`. Error messages must still start `[Lync]` and name the schema path (the runtime brief and
attempt.md §7 both require this). The build must therefore keep a **source map from generated spans back to schema
field paths** (see §4 un-permute map) so the inspector and the console observer can say
`[Lync] Chat:fire value.items[3].count …` even though the code lives in a game module. Studio's inspector shows the
generated code, which is readable Luau (not obfuscated), so breakpoints work; they just land in unexpected files.

**Determinism.** Fully seedable: the placement (which call site gets an inlined copy vs a shared helper, which
module holds which constant) is chosen by the build RNG keyed on `seed`. **Seed 0 = identity: one `Net` module,
canonical names, no scatter** — required for goldens and tests (attempt.md harness uses `matchesGolden`).

**Maintenance.** Medium-high for the library author (the generator must correctly rewrite requires and preserve
require-time side-effect ordering — darklua's bundler explicitly warns modules must be side-effect-free at require
time, **documented** `.data/projects/darklua/.../bundle/index.md`). Low for the game developer: it is a build
flag, nothing hand-written.

### 1.3 Dissolve Lync's *own* runtime (the coordinator's hint)

The same machinery applies to Lync's internals, and this is where build-time earns its keep beyond scatter.

- **No fixed runtime blob.** Instead of shipping a versioned `Lync` ModuleScript that every game loads identically
  (the one-universal-bypass problem, §0.3), the build *emits* a runtime: the frame loop, the batch buffer manager,
  the sequence/tag code, the dispatch table — all generated from the schema with build-chosen names, constant
  encodings, control-flow shape, and module boundaries. Two games on the same Lync version share **no byte of
  runtime**. A bypass written against game A's decompiled runtime does not apply to game B.
- **What this breaks that scatter alone does not:** a *cross-game* universal script. Public cheat libraries target
  the *library*, not the game ("ByteNet bypass", "Zap spy"). If there is no stable Lync runtime shape, there is
  nothing to target once; each game must be attacked individually. For an open-source shared library this is the
  single most valuable property build-time provides.
- **Recovery.** Per-game, same as §1.2 — the attacker still instruments the live client. But the *authoring* of a
  reusable tool is defeated: the tool would have to re-derive the protocol per game, i.e. be a general
  packet-analysis framework, not a one-liner. That is the honest value.
- **Perf.** Must be neutral. The generated runtime is ordinary Luau; it is *not* a VM. The only moving parts are
  names/order/constants, which the compiler folds (§1.5). **verified** the folding; the runtime is the same
  bytecode shape regardless of names.
- **Debuggability.** Hardest here. A generated runtime means the author's own stack traces vary per build. Mitigate
  with: (a) seed 0 emits the canonical hand-maintainable runtime the author debugs against; (b) the build emits a
  `*.unmap.json` naming every generated symbol back to its canonical role; (c) the console observer is itself
  generated with stable `[Lync]` strings so user-facing errors never vary.
- **Determinism/maintenance.** The generator *is* the library — this is a large engineering commitment (it is
  effectively "Lync is a compiler that emits its own runtime", the research.md recommendation #1 taken to its
  conclusion). Maintenance is high but it is the author's, paid once; the game developer pays a build flag.

**Honest limit.** Generating the runtime does not change the §0.1 ceiling at all. It changes *who can write the
bypass and how reusable it is*, not whether a determined attacker on one game succeeds. Label it exactly that way.

### 1.4 Polymorphic output per build

**Mechanism.** Everything variable is driven by one `seed`: identifier names (via darklua `rename_variables`, which
uses a deterministic `identifier_permutator`, **verified** in `.data/projects/darklua/src/rules/rename_variables`),
definition-id assignment, field order within records where the schema permits, the xor/rotate masks on ids and the
keyed-tag constant, the module split, and the choice of inline-vs-shared per call site. A release bumps the seed;
every observable constant and name changes.

**What it breaks.** Static patches ("NOP the check at offset X"), signature scans ("find bytes `writeu16 ... bxor
0xA5C3`"), and any public script with a baked-in id or key. An attacker's build-N artifact is worthless on build
N+1. Against a game that ships frequently, the attacker's per-release cost is recurring; against the author it is
one RNG reseed.

**Recovery.** If the attack is *dynamic* (hook the remote, call the live closure) polymorphism changes **nothing** —
the names and constants are irrelevant to someone reading the running stack. Polymorphism only defeats *static*
artifacts. So its value is exactly proportional to how much of the attacker population uses static paste scripts
vs live instrumentation. On Roblox the paste-script population is large (the runtime brief's whole "break public
scripts" goal), so this is worth doing — but it is **not** protection against the skilled attacker and must not be
sold as such.

**Perf.** Zero. Names and constant encodings fold; field order is free (§1.1, §1.5).

**Bytecode/decompiler.** Bytecode differs per build (different constant table, import order). Decompilers still
produce readable output per build — polymorphism does not obfuscate, it *rotates*. The combination with §1.3
(generated runtime) is what makes each build genuinely distinct rather than renamed-identical.

**Determinism.** This is the cleanest seedable feature. The whole point is `seed → build`. Seed 0 = canonical.
The build report records the seed (§4) so a shipped build can be reproduced for debugging.

**Maintenance.** Low once the generator exists. The risk is *flaky goldens*: tests must pin seed 0 or a fixed test
seed, never the release seed.

### 1.5 Inline encoders, per-call-site encoders, distributed constants/secrets — what actually folds

**verified** (`.data/docs/probes/client-security-build/fold.luau`, `luau-compile --dump-constants`): splitting a constant across two locals
and combining them (`local K = bit32.bxor(A,B) + 7*3`) **folds to a single constant at -O2** (`K0: 20778`). At -O1
the intermediate is computed once at module load, still cheap. So "distribute the tag key across several source
constants" gives **no runtime cost and no static-analysis benefit** — the decompiler and the folded bytecode both
show the final constant. Distributing secrets across *modules* (one module exports part of the key, another
combines) survives folding only because it crosses a module boundary the compiler cannot see through; the attacker
reads both modules. **Verdict: constant-splitting within a function is theatre (folds away); cross-module secret
distribution is weak (two reads instead of one). Neither is worth a knob on its own; both come free as a side
effect of §1.2 scatter.**

Field permutation and id xor-masking (§1.1 row 4) are the opposite: free at runtime *and* they change the wire
bytes, so a packet replayer or a hand-built packet from another build/server is rejected at strict decode. This is
a real win and it is a *wire* feature driven by the *build* — it belongs with the runtime brief's per-build wire
randomization but is produced here.

### 1.6 Weave integrity checks, canaries, cross-checks into unrelated game scripts

**Mechanism.** The build injects, at randomized points in game scripts it already parses, small checks: (a) an
*identity canary* — capture a reference to a generated encoder at load, compare `enc ~= ref` before a send (§1.1:
+15–30 ns, so off hot paths only); (b) a *source canary* — `debug.info(enc, "s")` must equal the expected chunk
name (§1.1: ~44 ns alone); (c) a *cross-check* — module X asserts module Y's exported constant has the
build-expected value. A tripped canary does not ban; it folds a bit into the next frame's keyed tag (runtime
brief's mechanism) so the **server** sees a bad tag and scores suspicion. This is the one place a client check has
teeth, because the signal leaves the client.

**What it breaks.** Naive `hookfunction(enc, …)` changes the closure identity and `debug.info` source
(Potassium: "hooking a closure changes its hash", **documented**) — the canary trips. Scattering canaries into
unrelated scripts means the attacker cannot find and neutralize "the check"; there are many, in game code.

**Recovery.** Fast for a skilled attacker: executors have `setstackhidden`, `newcclosure` (hides chunk name),
`debug.setinfo` to spoof source, and can simply *not* hook and instead call the real `enc` (§0.1). The runtime
brief's §0.4 is explicit that every "is this hooked?" check is defeated by documented APIs. **So canaries catch
sloppy tooling only.** Their value is the high-confidence server signal when they do trip, never prevention.

**Perf.** Off-hot-path only. Never put a canary in the per-element encode loop. A per-*flush* canary (once per
frame per player) is ~44 ns/frame — negligible.

**Debuggability.** Canaries woven into game scripts are a support nightmare if they can false-positive. They must
be *measured for false positives on honest clients across platforms* before default-on (the runtime brief warns of
`getfenv`-slowdown detectors and UB-based detectors Roblox removed). **Default off**; opt-in with a documented
false-positive risk.

**Determinism.** Seeded placement; seed 0 = no canaries. The *values* checked are build constants, so goldens are
stable under a fixed seed.

**Maintenance.** Medium. Each canary is a potential false-positive report. Keep the set small and the signal path
(fold-into-tag) uniform.

### 1.7 Per-server / per-player code variation — what Roblox actually allows

This is the coordinator's "per place / per server" question answered precisely. **The client cannot compile code**
(no client `loadstring`, **verified** API dump: `ServerScriptService.LoadStringEnabled` is `NotScriptable`, server
only; runtime brief §2 agrees). So the client always runs the *place's* bytecode, identical for every player on
every server. Honest per-variation options:

1. **Per-build (per-release), all servers/clients identical within a build.** This is §1.3–1.4. The realistic
   default. "Per server" and "per client" below are narrow additions, not replacements.
2. **Server-generated module *source* via `loadstring` — server only.** The server can `loadstring` a
   freshly-generated decoder/validator and run it *on the server*. Useful for rotating the server's *decode* logic
   per server instance so a server-side memory reader (rare) sees different code. **Does nothing for the client**,
   because the result never leaves the server. Gated by `LoadStringEnabled` (a place setting, off by default) and
   Creator-Store-hostile if the shipped place depends on it (§2). **Verdict: niche; recommend off; document as
   server-decode-rotation only.**
3. **ModuleScript cloned/parented per player at runtime.** The server holds generated ModuleScripts in
   ServerStorage (`NotReplicated`, **verified** tag) and, on player join, clones one and parents it into that
   player's `PlayerGui` (tagged `PlayerReplicated`, **verified** — its contents replicate to the owning client and
   are not visible to other clients; runtime/docs **reported** but the tag is authoritative). The client then
   `require`s it. **This gives genuine per-player code variation** that other clients cannot see. But: (a) the
   *source* of each per-player module is still fixed bytecode chosen from a pool the build produced — it is
   *selection* per player, not *generation* per player, because the server has no client compiler to target; (b)
   the owning player's own executor reads their module as normal; (c) it adds join-time replication and a
   `require` round-trip. **Verdict: real but expensive; the honest description is "per-player selection from a
   build-generated pool," not "unique code per client." Recommend off by default; document the replication cost and
   the selection-not-generation limit. Useful mainly to make a leaked per-player module not match another
   player's, frustrating "it worked for my friend" paste sharing.**
4. **Just-in-time parenting of server-held client code.** A LocalScript/ModuleScript can be kept in ServerStorage
   and parented to a client container only after some gate (e.g. after the HELLO handshake). This delays the code
   reaching the client and lets the server withhold it from a client that already looks suspicious. **Limit:** once
   parented it is ordinary client bytecode the executor reads; the delay is the only effect, and it complicates
   load order and `WaitForChild` timing. **Verdict: marginal; off by default.**

**Overall honest answer to "can each client be subtly different?":** *Not in source.* The realistic, recommendable
unit of variation is **per build**. Per-player *selection* (option 3) is the only true runtime variation and it is
selection from a finite build-time pool, with real replication cost. Promise nothing more.

---

## 2. Tooling forms — what each vehicle can and cannot do (Question 2)

Concrete capabilities, from the pinned API dump (Roblox 0.741.19), the tools' own source in `.data/projects`, and
official docs.

### 2.1 Studio plugin

**Can:**
- Read and write any script's `Source` (`ModuleScript.Source`/`Script.Source` are `ProtectedString`, read/write
  capability `PluginOrOpenCloud`, **verified**). Prefer `ScriptEditorService:UpdateSourceAsync(script, callback)`
  (`PluginSecurity`, **verified**) over setting `Source` directly: it computes the new source from the current one
  and **the editor can reject it if the open document is out of date** and re-invoke the callback (**documented**),
  which is the safe way to edit scripts a developer may have open. This is exactly how Blink's plugin writes its
  generated module (research.md §5.1, **reported**).
- Add editor diagnostics and autocomplete without luau-lsp:
  `ScriptEditorService:RegisterScriptAnalysisCallback(name, priority, cb)` — the callback receives `{script=...}`
  and returns `{diagnostics={{range, message, code?, severity?, codeDescription?}}}` (**documented**; `severity`
  is `Enum.Severity`, `codeDescription.href` must be `https` to `create.roblox.com`). Good for schema-aware
  "you fired a server→client event from the client" hints at edit time.
- Walk the whole DataModel (every script, not just Lync's), run its generator, write results, group under one undo
  with `ChangeHistoryService:TryBeginRecording`/`FinishRecording` (`PluginSecurity`, **verified**).
- Run only in **edit mode** (`RunService:IsEdit()` is `PluginSecurity`). A toolbar button triggers it manually.

**Cannot:**
- **Run on publish or save.** `StudioPublishService.OnPublishAttempt`, `.RegisterPublishHold`, `.GamePublishFinished`,
  `.OnSaveOrPublishPlaceToRoblox`, `.PublishAs`, `.PublishLocked`, and `StudioService.OnSaveToRoblox` /
  `.ShowPublishToRoblox` are **all `RobloxScriptSecurity`** (**verified**, API dump). A third-party plugin runs at
  plugin security and **cannot** hook publish, hold a publish, or be notified of a save. There is **no publish
  hook for plugins.** This is the single most important tooling fact for a Studio-only workflow: the transform
  must be a *manual toolbar action the developer runs before publishing*, exactly like Blink's "generate" button.
  There is no way to make it automatic on publish from inside a plugin.
- Run during a play-test as an edit-mode process acting on the running server (the play-test is a separate
  DataModel; the plugin stays in edit mode). The author's harness already worked around this with a `Driven`
  attribute handshake (attempt.md §8).
- Compile Luau to bytecode or decompile — no such plugin API.

### 2.2 Lute/Lune CLI on a Rojo project

**Can (Lute, the natural host — a Luau runtime, so the generator is written in Luau once and runs in CLI *and*
plugin):**
- Read `sourcemap.json` and `project.json`, read/write every `.luau` file.
- **Parse, query, and rewrite Luau via the CST**: `@std/syntax` (parser, printer, visitor, query), and
  `lute transform` applies a `{ [CstNode]: string }` replacement map deterministically (**documented**,
  `.data/projects/lute/docs/guide/code-transforms.md`). This is the right tool for AST-accurate call-site rewriting
  (find every `Lync.send` call, replace with an inlined or scattered encoder) with position mapping preserved.
- **Compile and load bytecode** (`luau.compile`, `luau.load`) and **resolve module types** (`luau.typeofModule`
  returns a full resolved `Type` tree, **verified** `.data/projects/lute/definitions/luau.luau`) — so the CLI can
  read the schema's inferred types to drive codegen and emit `.d.ts` without a separate parse.
- **Cryptography for build-time key/tag derivation**: `@std/crypto` has `digest(hash, msg)`, `secretbox`,
  `password`, so the build can derive the keyed-tag constants and the manifest hashes offline (**verified**
  `.data/projects/lute/definitions/crypto.luau`).
- Produce a standalone executable (`lute compile`) for CI (**documented**).

**Cannot:** touch a Studio-only developer's DataModel (no file system). A CLI is a Rojo/file workflow tool.

**Lune** (research.md: v0.11): its `@lune/roblox` can `deserializePlace`/`serializePlace` a `.rbxl` and read every
instance including `Script.Source` (**documented**, lune docs) — so a Lune step can transform a *built place file*
even for a non-Rojo developer who exports an `.rbxl`. Setters on real properties error by default
(`implementProperty`), but Source is settable on deserialized instances. Useful as a CI post-build pass on the
place file.

### 2.3 darklua

**verified** against `.data/projects/darklua` 0.19.0 source. darklua is a Rust binary driven by a JSON5 rule list;
it is **not** scriptable in Luau — a "custom pass" means forking the Rust or contributing a rule upstream. Its
`get_all_rule_names()` (src/rules/mod.rs) is a fixed set. Relevant existing rules:

- `rename_variables` — deterministic identifier permutation (`identifier_permutator`), with `globals: ["$default",
  "$roblox"]` to avoid clobbering engine globals and `detect_globals` (new in 0.19) to auto-avoid per-file globals.
  **This is the polymorphic-renaming workhorse (§1.4).** It renames; it does not reorder or VM.
- `inject_global_value` (`_G.NAME → value`, or from env/env_json) + `compute_expression` + `remove_unused_if_branch`
  — **build-time feature flags and dead-branch elimination.** Inject `_G.LYNC_SEED`, `_G.LYNC_CANARIES`, etc., and
  the unused branches vanish from client bytecode. This is how a single Lync source compiles to different client
  code per build without a bespoke generator (**documented**, inject_global_value.md).
- `bundle` (path/roblox require modes) — merges the generated modules into fewer files; respects the closest
  `.luaurc` (0.19 changelog). Warning: require-time side effects may reorder (**documented**) — the generated
  runtime must be side-effect-free at require time.
- `remove_comments`, `remove_spaces`, `convert_index_to_field`, `remove_debug_profiling`, `remove_assertions` —
  shrink and strip. `remove_assertions` would strip the author's `assert`-based invariant checks; use
  `apply_to_files`/`skip_files` (0.18) to keep them in debug builds.
- `apply_to_files`/`skip_files` (0.18) — scope rules per file, so canaries/renaming apply to shipped client
  scripts but not test or server-only files.

**What a custom pass would need:** field-order permutation, call-site inlining, scatter, and canary injection are
**not** expressible as darklua rules (they are schema-aware and cross-module). Those belong in the Lync Lute
generator (§2.2), which emits the scattered/inlined source; darklua then does the *generic* polymorphic finish
(rename, inject flags, dead-branch, bundle, strip). **Division: Lync CLI does schema-aware generation; darklua does
generic polymorphism and stripping.**

### 2.4 Rojo itself

**verified** `.data/projects/rojo` 7.7.1. Rojo is **not** a transform engine: no Luau plugin system, no source
rewriting. It has `rojo sourcemap` (the `{name, className, filePaths, children}` tree the Lync generator consumes),
`rojo build`, `rojo serve`, `rojo syncback` (place→files), and `rojo upload` (Open Cloud place upload). The Lync
integration with Rojo is: (a) consume `sourcemap.json`; (b) slot into the build pipeline *before* `rojo build`
(generate → darklua → rojo build), which is the author's existing `scripts/` darklua-watch + rojo-serve flow
(attempt.md §8). Rojo does not itself own any security job; it is the project model and the uploader.

### 2.5 luau-lsp plugin

**verified** `.data/projects/luau-lsp` 1.70.1 plugin README. A luau-lsp source-transform plugin returns
`{ transformSource = function(source, context) → {TextEdit}? }`, runs **before type checking**, with position
mapping preserved, hot-reloads, sandboxed (`string/table/math/bit32/buffer/coroutine/utf8`, plus an `lsp.fs` API;
no `io`/`os`/`debug`). Settings: `luau-lsp.plugins.enabled/paths/timeoutMs/fileSystem.enabled`.

**Owns: edit-time types only, never shipped code.** It can make the developer *see* concrete schema types and
"wrong-direction call" diagnostics as they type, with no build step. It **cannot** affect what ships (it only
transforms the source the *analyzer* sees, not the file). It is experimental ("API subject to change"). **Verdict:
a developer-experience accelerator for the no-codegen-step promise (research.md #11/#16), not a security vehicle.**

### 2.6 roblox-ts transformer

**verified** `.data/projects/roblox-ts` 3.0.0. `compilerOptions.plugins[].transform` (string path) are loaded from
tsconfig and run before emit (`getPluginConfigs.ts`, `compileFiles.ts`). Prior art: flamework-binary-serializer
generates a serializer from a TS type via the Flamework transformer (research.md §5.4). **Owns: the TS→Luau path.**
A Lync roblox-ts transformer can generate the same scattered/inlined/polymorphic codecs from TS types that the Lute
CLI generates from Luau schemas, so roblox-ts users get identical output. It runs at compile time with full type
information — the ideal place for TS-side generation. **It does not help Luau-only or Studio-only developers;** it
is one of three front-ends (Luau CLI, roblox-ts transformer, Studio plugin) that must all drive the *same* IR and
generator so all users get the same security result.

### 2.7 Publishing pipelines (Open Cloud, CI)

**documented** (fetched 2026-10-15):
- **Place publishing**: `POST https://apis.roblox.com/universes/v1/{universeId}/places/{placeId}/versions?versionType=Published`,
  `x-api-key` header, body is the `.rbxl`/`.rbxlx`. **Limit:** does *not* update `EditableImage`, `EditableMesh`,
  `PartOperation`, `SurfaceAppearance`, `BaseWrap` (must publish those from Studio). Scripts are fine. This is the
  CI endpoint: generate → darklua → `rojo build` → upload. **This is the only vehicle that is truly automatic on
  publish**, because it *is* the publish. Studio's own publish cannot be hooked (§2.1); CI publish can run the full
  transform.
- **Engine Open Cloud (instance update)**: `PATCH .../instances/{id}` updates `Script`/`LocalScript`/`ModuleScript`
  Source only, 200 KB/request, scopes `universe-place-instances`, requires a collaborative (Team Create) session,
  cannot touch scripts open in Studio, returns an Operation to poll (**documented**). Niche: lets CI rotate a few
  scripts in a live place without a full republish. Not a primary vehicle.

### 2.8 How Rojo users and Studio-only users get the same result

Three front-ends, one IR, one generator:
- **Rojo/file developer:** Lync Lute CLI reads `sourcemap.json` + schema, generates scattered/inlined/polymorphic
  Luau, darklua finishes it, `rojo build`/Open Cloud publishes. Fully automatable in CI.
- **roblox-ts developer:** the transformer generates from TS types into the same IR; same output.
- **Studio-only developer:** the Lync Studio plugin runs the *same generator* (it is Luau, it runs in the plugin
  too, per Blink's proof) against the DataModel, writes scripts via `UpdateSourceAsync`, under one undo. **But it
  is a manual toolbar action (§2.1): there is no publish hook.** The plugin must therefore show a clear "generated
  for build <seed> — publish now" state and warn if the tree changed since generation. The manifest (§4) is how the
  Studio user knows the build is current.

The honest gap: the Studio user's flow is manual-before-publish; the CI user's is automatic-at-publish. Same
*output*, different *trigger*. Document this; do not pretend the plugin can gate publish.

---

## 3. Obfuscation landscape (Question 3)

**reported** unless marked; I ran the VM-cost measurement myself (**verified**).

- **What decompilers recover (2026):** Konstant (Luau, plusgiant5; V2 "old and bad", V3 in progress; Discord-bot
  `/decompile`), Unluau (C#, "most powerful public Luau decompiler", early alpha), medal/shiny (Rust, "blazingly
  fast Lua(u) decompiler"), browser tools LuaUndo (bytecode v3–14, local) and Luacid (keyless tier 256 KB/30 rpm),
  and Potassium's integrated `decompile` (accepts functions since build `90f2fddd`). Consensus: Luau bytecode maps
  near-1:1 to source including line numbers; local variable *values* and control flow recover well; **parameter and
  local names are stripped** on shipped bytecode (come back `UNNAMED_<addr>` / generic names). A Roblox staff reply
  (**reported**) confirms the client receives *encrypted bytecode* and cannot compile. So: **structure is
  recoverable; original names are already gone before any obfuscator runs.**
- **darklua renaming:** not obfuscation — it renames and strips, deterministically. Compatible with Roblox and
  Creator Store (it produces ordinary Luau), zero runtime cost, defeats *name-based* reading and static scans only.
  This is the right "obfuscation" for network code: it is a rotation, not a VM.
- **Prometheus (open source):** README says **LuaU support is not finished** (**documented**); GPL/AGPL. VM and
  control-flow-flattening modes. Not production-ready for Luau.
- **Luraph (commercial, subscription):** "dominant commercial Roblox obfuscator," compiles to a *heavily randomized
  custom VM whose instruction set changes per run* (vendor copy, **reported**; no independent 2026 benchmark
  found). VM-based, so the cost below applies.
- **IronBrew-style VMs:** classic register-VM + constant encryption + control-flow flattening.
- **VM cost, measured (`.data/docs/probes/client-security-build/vm.luau`, **verified**):** re-expressing the sample encoder as a
  register-VM with table-driven dispatch runs **7.3× slower** than direct Luau on the 0.740 interpreter (719–763 ns
  vs 98–105 ns), both -O1 and -O2. A simpler per-op interpreter (§1.1) is ~2.7×. Because the client is interpreted
  with **no native codegen**, a VM pays the interpreter tax *twice* (the host VM interpreting the guest VM
  interpreting the ops). For a per-frame, per-element hot encode path this is disqualifying.
- **Creator Store legality:** Roblox Creator Store **prohibits obfuscated code** explicitly ("if code is
  obfuscated, creators cannot trust that the script is only doing what it should"), and also restricts "obscuring
  engine features … including LuaVMs, getfenv(), setfenv()", remote `require(assetId)`/`loadstring`, and
  "unnecessarily large scripts" (**documented**, create.roblox.com/.../creator-store). **A VM-obfuscated or
  getfenv-tricked Lync build cannot ship on the Creator Store, and Lync is a library distributed there.** This
  alone refuses VM obfuscation as a default and as a library-level feature.

**Is any obfuscation worth it for network code specifically?** Only the non-VM, Creator-Store-legal, zero-cost
kind: deterministic renaming + dead-branch elimination + the polymorphic rotation from §1.4, plus the scatter from
§1.2. A real VM is both too slow on the interpreted hot path and illegal for a Store-distributed library. **Verdict:
ship rename/strip/rotate; refuse VM.**

---

## 4. Developer effort and configuration surface (Question 4)

Design goal: every measure is an explicit, named, typed knob with a unit, range, default, and a one-line cost in
its doc; no `security="hardened"` meta-preset; everything derived from the schema and project; nothing hand-written
per message. The config is a **separate build config file**, `lync.config.luau`, *not* the schema module (the
schema is shared between client and server and must stay policy-free — attempt.md §6 is emphatic that policy never
goes in the shared schema; the same logic forbids build/security config there). The Studio plugin UI reads and
writes the *same* `lync.config.luau` (serialized through the plugin's settings), so the two front-ends cannot
diverge.

### 4.1 Composition and validation

- Each knob is independent and typed. The build validates at parse time: ranges, enum membership, and
  *cross-knob coherence* (e.g. `canaries.foldIntoTag = true` requires `tag.enabled = true`; `perPlayerSelection`
  requires a server able to clone from ServerStorage; `inline.maxBytecodeGrowth` caps total growth so inlining
  cannot blow the Luau per-script limit). A failed validation is a build error with the knob name and the reason,
  in the `[Lync]` message style.
- `seed = 0` is the global off-switch for *all polymorphism and placement* (not for correctness features). Seed 0
  produces the canonical, golden-stable build. Any nonzero seed enables the placement/rotation knobs that are set.
- Knobs that only affect the wire (field permutation, id mask) coordinate with the runtime brief's per-build wire
  randomization: the build chooses them, the runtime enforces them, the server knows them.

### 4.2 Build report and manifest

Every build emits `lync-build-report.json` (human-readable summary printed too) with, per enabled measure: the
knob values, the measured/estimated cost (ns/op where benched, bytecode-bytes delta, wire-bytes delta), and a
one-line effect-and-limit. And a `lync-build.manifest.json`: the seed, the full set of shipped Lync-touched scripts
with their `getscripthash`-comparable hashes (SHA-384 of bytecode — matches the executor's own `getscripthash`,
so the *game itself* can later compare), the id assignment, and the wire layout. The manifest ships *in the place*
(so the game can self-check, §5) but the **un-permute map ships only to the developer** (`lync-build.unmap.json`:
generated-symbol → canonical-role, span → schema-field-path) and is git-ignored out of the place.

### 4.3 Debugging a hardened build

- The `seed` reproduces the exact build.
- `lync-build.unmap.json` lets the Lync inspector/console translate a generated stack frame or wire byte back to a
  schema path, so `[Lync] Chat:fire value.items[3].count must be …` still works (attempt.md §7 requirement) even
  with scatter and renaming.
- A **decode inspector** (CLI + a Studio plugin pane) takes a captured frame + the manifest + the unmap and prints
  the decoded, named structure — the author's and developer's window into a polymorphic build.
- Seed 0 build for local dev: canonical names, one `Net` module, no canaries — so day-to-day debugging is against
  readable code and the hardened build is produced only for release.

### 4.4 Server consumption of signals

The server (always un-transformed, server-side) receives the runtime brief's signals: bad keyed tag (canary
tripped or packet tampered), wrong-direction id, trap-definition hit, sequence break, ack of an unsent frame,
rate beyond the declared flush cadence. Lync surfaces these as the existing typed frozen event union
(`Dropped|CheckRaised|Mismatch|…` with reasons, attempt.md §7) plus a per-player **suspicion accumulator** the
developer reads; Lync never bans (attempt.md §6: "Lync never kicks; it emits typed events"). The build config only
decides *which client-side canaries exist and how they fold into the tag*; the server-side weighting is the
existing `Lync.escalate` surface, unchanged.

### 4.5 Config syntax sketch (Luau)

```luau
-- lync.config.luau  — build/security config, NOT the shared schema. Read by the Lync CLI,
-- the roblox-ts transformer, and the Studio plugin (same file, one source of truth).
local Lync = require("@lync/config")

return Lync.build {
    -- Reproducibility. seed 0 = canonical golden build: no polymorphism, no scatter, no canaries.
    -- Any nonzero u53 enables the placement/rotation knobs set below. Bump per release.
    seed = 0,                       -- u53; default 0 (off). Cost: none.

    project = {
        sourcemap = "sourcemap.json",   -- path; consumed to find call sites and script set.
        schema    = "src/shared/Net.luau",
        emitDts   = true,               -- also emit .d.ts for the generated surface.
    },

    -- POLYMORPHISM (per-build rotation). All seeded. No runtime cost; breaks static artifacts only.
    polymorphism = {
        renameIdentifiers = true,       -- bool; default true. darklua rename_variables. Cost: none.
        rotateDefinitionIds = true,     -- bool; default true. Per-build id assignment. Cost: none.
        permuteRecordFields = true,     -- bool; default true. Reorders fields where schema allows.
                                        --   Cost: none (folds). Changes wire bytes -> breaks replayers.
        maskIds = "xor",                -- "off"|"xor"|"xor-rotate"; default "xor". Per-build constant.
                                        --   Cost: ~0 (folds to constant, verified).
    },

    -- MODULE LAYOUT (scatter / dissolve). Seeded placement. seed 0 ignores this block.
    layout = {
        scatterRuntime = true,          -- bool; default true. Dissolve Lync runtime into generated modules.
                                        --   Breaks: cross-game universal bypass. Cost: none. Debug: needs unmap.
        scatterEncoders = "perModule",  -- "central"|"perModule"|"perCallSite"; default "perModule".
                                        --   perCallSite inlines (<=~4.5x bytecode, verified) -> bound it below.
        inline = {
            maxBytecodeGrowthPct = 150, -- u16 percent; default 150. Build errors if inlining exceeds it
                                        --   (guards the Luau per-script limit + Creator Store "large script").
            neverInlineHotLoops = true, -- bool; default true. Keep per-element encode a shared call (88ns)
                                        --   rather than a bloated inline; perf, verified neutral-to-worse inline.
        },
        bundle = "darklua",             -- "none"|"darklua"; default "darklua". Must be side-effect-free at require.
    },

    -- CANARIES (server signals, not prevention). Default OFF: false-positive risk, defeated by skilled attackers.
    canaries = {
        enabled = false,                -- bool; default false. Enable only after honest-client FP testing.
        kinds = { "identity", "source", "crossModule" }, -- which checks to weave.
        placement = "offHotPath",       -- "offHotPath"|"perFlush"; default offHotPath.
                                        --   Cost: ~15-44 ns per check per flush (verified). NEVER per element.
        foldIntoTag = true,             -- bool; default true. A tripped canary corrupts the keyed tag so the
                                        --   SERVER sees it. Requires wire.tag.enabled. No client-side action.
        density = 4,                    -- u8 count of canary sites across game scripts; default 4. More = more
                                        --   FP surface and support cost. Range 0..32.
    },

    -- PER-PLAYER SELECTION (the only true runtime variation Roblox allows). Default OFF (replication cost).
    perPlayer = {
        selection = false,              -- bool; default false. Clone one of a build-generated pool into each
                                        --   player's PlayerGui (PlayerReplicated). SELECTION, not generation.
        poolSize = 8,                   -- u8; default 8. Distinct variants in the pool. Range 2..64.
                                        --   Cost: join-time replication + one require per player. Limit: the
                                        --   owning player's executor still reads their variant.
    },

    -- WIRE knobs owned by the runtime brief but chosen at build time; listed so one file configures everything.
    wire = {
        tag = { enabled = true, bytes = 2 },   -- keyed per-build tag over the implicit sequence (runtime brief).
    },

    -- OUTPUT / DEBUG.
    output = {
        report   = "build/lync-build-report.json",   -- per-measure cost + effect + limit.
        manifest = "build/lync-build.manifest.json",  -- ships in place; seed, script hashes, id/wire layout.
        unmap    = "build/lync-build.unmap.json",     -- developer-only; git-ignore; drives the inspector.
    },
}
```

Validation examples the build enforces: `canaries.foldIntoTag` with `wire.tag.enabled=false` → error
`[Lync] config: canaries.foldIntoTag requires wire.tag.enabled`. `layout.scatterEncoders="perCallSite"` pushing
past `inline.maxBytecodeGrowthPct` → error naming the offending module and the measured growth. `seed=0` with any
`polymorphism`/`layout.scatter`/`canaries` set → warning that those are inert at seed 0 (so goldens are honest).

---

## 5. Creative ideas enabled by the full-project view (Question 5)

Judged honestly; theatre labelled.

1. **Build-time proof that no client script references a raw remote.** The build already has the CST of every
   script. It can *fail the build* if any client script calls `:FireServer`/`:InvokeServer` on a Lync remote, or
   references the remote instances directly, instead of going through the Lync API. **Real and valuable** — it is
   a static guarantee, not a runtime check, so it cannot be bypassed; it enforces the invariant that the only way
   to send is through the (canary-able, tag-bearing) generated path. Low cost, high confidence. **Recommend
   default-on as a lint** (warn), opt-in to hard-fail. This is the research.md "build-time proof" idea and it is
   the strongest item here.
2. **Self-check against the build manifest.** The place ships `lync-build.manifest.json` with per-script bytecode
   hashes (SHA-384, matching the executor's own `getscripthash`). A small generated routine lets the *game* compare
   a sample of its own client scripts' hashes to the manifest and fold a mismatch into the tag. **Partly real,
   partly theatre:** an executor can hook the comparison or spoof `getscripthash` — but a *naive injected script
   that adds a new script or edits one* (the common case) changes the live set and trips it, giving a server
   signal. Label: catches crude injection, not skilled; off by default; FP-test across platforms (Roblox updates
   can change bytecode).
3. **Honeypot/trap definitions generated into the schema surface.** The build emits extra definition ids that no
   honest client code path ever uses (and that the type surface hides, attempt.md §6). Any frame carrying a trap id
   is a near-certain injected call. **Real high-confidence signal** (Roblox's own security docs call honeypot
   remotes "a very high-confidence signal", **documented**). Generated, so zero developer effort. The build view
   adds value: it can place traps that *look* like real definitions in the decompiled surface (adjacent ids,
   plausible names) so a copy-paste attacker enumerating definitions hits one. **Recommend default-on**; it has no
   FP risk (honest code never emits the id) and the server scores it.
4. **Decoy traffic, statistically indistinguishable.** Generate background frames that mirror the real traffic's
   size/timing distribution so a passive wire spy cannot tell which frames carry real data. **Mostly theatre and
   costly:** it burns the per-player byte budget the server enforces (attempt.md §6), it costs real bandwidth on
   mobile, and it does nothing against an attacker who reads the client (they see which call produced which frame).
   It only frustrates a pure passive wire observer, a rare and weak attacker. **Refuse as a default; offer only as
   an explicit, clearly-costed knob if at all, labelled theatre.**
5. **Per-release protocol rotation.** The seed already rotates ids/keys/layout per release; extend to a *scheduled*
   rotation where CI republishes with a new seed on a cadence. **Real against static paste scripts** (their shelf
   life becomes one release cycle), **inert against live instrumentation**. Cheap for the author (reseed + CI
   publish via Open Cloud). **Recommend as a documented CI pattern**, not a runtime feature.
6. **Injected-script detection by set comparison.** Beyond hashes (#2), compare the *set* of running scripts
   (`getrunningscripts` is an executor API, but the honest game can enumerate its own tree) against the manifest's
   expected set and fold anomalies into the tag. Same honest limit as #2: crude injection trips it, skilled does
   not. Off by default.
7. **Build-time worst-case size and budget proof.** Not security per se but security-adjacent: the build computes
   each definition's worst-case encoded size from the schema and *proves* it fits the unreliable 1000 B limit and
   the server's per-player budget (Blink #108 is an open request for exactly this). Fail the build otherwise.
   **Real, cheap, prevents a class of DoS-by-oversize-frame at authoring time.** Recommend default-on.

---

## Implications

Ranked by value-per-cost for the author's stated goal (raise exploit cost, break public scripts, detect tampering,
feed the server). Each: vehicle, default, knobs, honest limit.

1. **Build-time proof: no raw-remote access from client scripts** (vehicle: CLI + transformer; Studio plugin lint).
   Default: **on (warn), opt-in hard-fail**. Knob: `proveNoRawRemotes = "warn"|"error"|"off"`. Limit: static only;
   enforces the invariant that sends go through the canary-able path. **Strongest item; cannot be bypassed because
   it is compile-time.**
2. **Honeypot/trap definitions generated into the surface** (vehicle: CLI/transformer/plugin generator). Default:
   **on**. Knobs: `traps.count`, `traps.disguise`. Limit: catches enumeration/paste attacks; a careful attacker
   avoids unknown ids. No FP risk; server-scored. (Roblox docs call this high-confidence.)
3. **Polymorphic per-build rotation of ids/keys/names/field-order** (vehicle: CLI generator + darklua
   `rename_variables`/`inject_global_value`/`remove_unused_if_branch`). Default: **on at any nonzero seed**. Knobs:
   `seed`, `polymorphism.*`. Limit: defeats *static* artifacts and paste scripts only; inert against live
   instrumentation. Zero runtime cost (verified: masks/field-order fold).
4. **Generated/dissolved runtime + scattered encoders** (vehicle: CLI generator; Studio plugin generator). Default:
   `scatterRuntime=on`, `scatterEncoders="perModule"`. Knobs: `layout.*`, `inline.maxBytecodeGrowthPct`,
   `neverInlineHotLoops`. Limit: kills the *cross-game universal bypass* and blind `require`/path attacks; per-game
   live attack unaffected (§0.1). Perf neutral if inlining is bounded; needs the unmap for debugging.
5. **Keyed-tag over implicit sequence, constants chosen per build** (vehicle: runtime brief owns enforcement; CLI
   chooses constants). Default: **on**. Knob: `wire.tag.{enabled,bytes}`. Limit: the one client check with teeth,
   because tampering shows up server-side as a bad tag/sequence; +2 B/frame.
6. **Build-time worst-case size / budget proof** (vehicle: CLI/transformer). Default: **on**. Knob:
   `proveSizes = "error"|"warn"|"off"`. Limit: authoring-time DoS-by-oversize prevention; not a runtime defence.
7. **Canaries folded into the tag** (vehicle: CLI weaves into game scripts). Default: **off**. Knobs: `canaries.*`.
   Limit: catches sloppy tooling only; defeated by `newcclosure`/`setstackhidden`/`debug.setinfo`; real
   false-positive surface — must be platform-FP-tested before any developer turns it on. Off-hot-path only.
8. **Self-check against the manifest / injected-set detection** (vehicle: generator emits routine; manifest ships
   in place). Default: **off**. Knobs: `selfCheck.*`. Limit: catches crude injection, spoofable by executors;
   FP risk on Roblox bytecode changes.
9. **Per-player selection from a build-generated pool** (vehicle: server clones ServerStorage ModuleScript into
   PlayerGui). Default: **off**. Knobs: `perPlayer.{selection,poolSize}`. Limit: the only *true* runtime variation,
   but it is selection not generation; join-time replication cost; owning executor still reads its variant.
10. **luau-lsp source-transform plugin for schema types + wrong-direction diagnostics at edit time** (vehicle:
    luau-lsp plugin). Default: **on if luau-lsp present**. Not a security measure — a DX accelerator for the
    no-codegen-step promise. Experimental API.

**Vehicle ownership summary.** *CLI (Lute)*: schema-aware generation — scatter, inline, runtime emission, field
permutation, traps, proofs, manifest/unmap. *roblox-ts transformer*: the same generation from TS types (same IR).
*Studio plugin*: runs the same generator manually before publish (no publish hook exists — `OnPublishAttempt`/
`OnSaveToRoblox`/`PublishAs` are RobloxScriptSecurity, verified) and provides the inspector pane + edit-time
diagnostics. *darklua*: generic polymorphic finish — rename, inject build flags, dead-branch, strip, bundle.
*CI/Open Cloud*: the only automatic-at-publish trigger; runs the full pipeline. *Runtime*: enforces the tag,
sequence, decode, budgets, and emits server signals.

**Refuse to ship (name them in the docs so the author can point at this list):**
- **VM / bytecode-VM obfuscation of any Lync code** (Luraph/IronBrew/Prometheus style). Measured 7.3× on the
  interpreted client hot path (verified); and **Creator-Store-prohibited** for a Store-distributed library
  ("obfuscated code", "LuaVMs", documented). Both reasons are dispositive.
- **`getfenv`/`setfenv`-based tricks.** They clear the safe-environment flag and slow down *every* script they
  touch (runtime brief §2.2, source-verified), and are explicitly on the Creator Store restricted list.
- **Any promise of unique per-client *source*.** Impossible on Roblox (no client compiler). The honest maximum is
  per-build, with per-player *selection* as a narrow, costed extra. Marketing it otherwise is a lie the first
  decompiler disproves.
- **Client-side bans or any consequence applied on the client.** Lync emits signals; the server decides. Roblox's
  own guidance: "Try to never ban based on client-side detections." A client check that bans is both bypassable
  and a false-positive liability.
- **Decoy/cover traffic as a default.** Burns the server-enforced per-player byte budget and mobile bandwidth,
  defeats only a passive wire spy, inert against a client reader. Theatre; offer only as an explicit, labelled,
  costed opt-in if at all.
- **Constant-splitting within a function as a "secret distribution" feature.** Folds to a single constant at -O2
  (verified); the decompiler shows the final value. Pure theatre. (It is fine as a free side effect of scatter
  across *modules*, but not as a sold knob.)
- **A `security = "hardened"` preset.** Explicitly rejected by the author; the §4 named-knob surface replaces it.
