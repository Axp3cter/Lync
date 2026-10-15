# Generation and client security: platform rules, delivery, limits and cost

Researcher brief, 2026-10-15. **Decision it feeds:** earlier drafts refused several client-side measures. Do those
refusals still hold now that the build generates per-side Luau shards per build, and possibly per player variant?
This brief gives verified facts for re-judging them. It builds on `client-security-build.md` (cited `[CSB §n]`),
`client-security.md` (`[CS §n]`) and `anticheat-design.md` (`[AD §n]`), and does not repeat what they verify.

**What I read:** every file in `.data/docs/design/` and `.data/docs/research/`, the sections the brief named in full
(`v5.md` §0–§2, §4.5, §6, `v5-integrity.md`, `v5-tooling.md`, `v5-changes.md`), and the others for overlap.

**Labels.** **verified**: I ran it or read the source. **documented**: official docs say so. **reported**: a third
party says so. **unverified**: my inference, or nothing found.

**Tools.** Luau 0.742, built from `.data/projects/luau` with cmake and Ninja (RelWithDebInfo) into the scratchpad;
the luau skill's API dump 0.741.19. Machine: Intel Xeon 2.1 GHz, 4 cores, Linux. CLI timings show scale only. Roblox
devices differ, and phones are slower by an unmeasured factor.

**Probes** (`.data/docs/probes/generation-security/`, reproduced by `run.sh BUILD_DIR WORK_DIR`):
- `gen_limits.py` writes modules at the edges of the compiler's limits. Output: `limits.out`.
- `loadcost.cpp` is a harness linked to the 0.742 VM that times `luau_load` and the module's top level. Output:
  `loadcost.out`.
- `placement.luau` shows where a per-build value lands in the bytecode. Output: `placement.out`.

---

## 0. Bottom line

1. **The Creator Store rules do not cover generated shards.** They cover assets distributed through the Creator
   Store (documented). A shard that is generated into the developer's own place, and never published as an asset,
   is outside them. The Lync runtime package and the Studio plugin are distributed there, so the rules still bind
   those two.
2. **Outside the Creator Store, no Roblox rule bans obfuscation as such.** The Community Standards bullet is
   qualified by intent: obfuscated code "that mislead[s] end users or create[s] disruptive experiences". The Terms
   of Use say nothing about obfuscation. Moderation risk for heavy obfuscators in one's own place is **reported**
   only, in anecdotes (§1).
3. **Per-player code delivery works.** `PlayerGui` carries the `PlayerReplicated` tag (verified). It is the only
   per-player container the server can write: `PlayerScripts` is "not accessible to the server" (documented).
   Adonis has delivered its client this way for years (verified, source).
4. **A client can read everything in its own shard,** whatever form the generator gives a value. Constants,
   immediates, folded expressions and values computed at load all sit in the bytecode that client receives
   (verified, §3). Per-player variants change *which* values a client holds. They never hide that client's own
   values from it.
5. **Native codegen does not run on Roblox clients** (documented: "server-side scripts"; an August 2026 bug report
   confirms it for live clients). Client shards must be designed and measured for the interpreter.
6. **Luau's limits are generous for per-build variation.** The limits that bind are 200 locals per function and
   32,767 closures per function prototype (verified, 0.742). Constants allow 2^23 per function, and there is no
   performance cliff at 255 (§4).
7. **Load cost is small.** `luau_load` takes 0.5–1.0 ns per bytecode byte for a few large functions, and about
   2.4 ns per byte for many small ones. A 64 KB-source shard loads in tens to a few hundred µs on this Xeon
   (verified, §5). Whether Roblox caches bytecode across servers is undocumented.

---

## 1. Obfuscation rules by distribution channel

### 1.1 Creator Store: current text and scope (documented)

Source: `Roblox/creator-docs`, `content/en-us/production/creator-store.md`, fetched 2026-10-15, section "Asset
requirements". It opens with: "Every asset that you distribute and sell on the Creator Store must adhere to …". It
then lists:

> In addition, the Creator Store restricts use of the following practices to ensure asset safety:
> - **Obscuring engine features within scripts**, including LuaVMs, `getfenv()`, and `setfenv()`.
> - **Requiring remote assets,** including `require(assetId)`, `loadstring()`, `InsertService:LoadAsset()`,
>   `AssetService:LoadAssetAsync()`, and `ModuleScript.LinkedSource`. Assets that may look useful on the surface
>   could load another "virus" asset at runtime.
> - **Including obfuscated code**. For publicly-shared assets, it's important for creators to understand what they
>   are putting into their games. If code is obfuscated, creators cannot trust that the script is only doing what
>   it should be doing.
> - **Extremely large scripts**. Assets with unnecessarily large scripts, including multiple repeat lines or large
>   strings that are unused, especially if they cause rendering issues in editors.

**Scope.** The rule names its own scope twice: "asset[s] that you distribute and sell on the Creator Store" and
"publicly-shared assets". It also states its reason: buyers must be able to trust code they insert. Code generated
into the developer's own place has no third-party buyer and is never distributed as an asset. *(This updates
CSB §6.1, which applied these rules to "the generated shards" too.)*

What still applies to Lync:
- The **runtime package** on the Creator Store, and the **Studio plugin**, must keep to all four rules.
- A shard that the runtime package itself *ships*, such as a default or example shard, falls under the rules
  because it is part of the asset.

### 1.2 Community Standards (documented)

Source: [about.roblox.com/community-standards](https://about.roblox.com/community-standards), fetched 2026-10-15,
section Security → "Misusing Roblox Systems" → "Disruptive Content and Behavior":

> Uploading content that contains obfuscated code or hidden scripts that mislead end users or create disruptive
> games for them

The OpenTermsArchive copy ([contrib-versions](https://github.com/OpenTermsArchive/contrib-versions/blob/main/Roblox/Community%20Guidelines.md),
"Last Updated: August 15, 2025") reads the same, with "experiences" in place of "games". The live page shows no date.

**Scope.** This bullet applies to all uploaded content, places included. It is qualified, though: obfuscated or
hidden code that *misleads end users* or *disrupts* their experience. A game hardening its own networking misleads
no end user about what the game does. That is my reading of the text (**unverified**: no official
interpretation found).

The same page's "Cheating and Scams" section prohibits "Using or sharing exploits …". That binds players, not
defensive code.

### 1.3 Terms of Use (documented)

Source: the OpenTermsArchive copy of the Terms of Use
([contrib-versions](https://github.com/OpenTermsArchive/contrib-versions/blob/main/Roblox/Terms%20of%20Service.md)),
fetched 2026-10-15. It is the version with "Effective Date: November 1, 2026". The live Help Center returned 403 to
my fetches.
- **No clause mentions obfuscation.** I searched for "obfusc".
- UGC "must not consist of or contain software viruses".
- Users may not "reverse engineer, disassemble, decompile, decode … any Services". This binds the people decompiling
  game clients, not the developer.

### 1.4 Practice and enforcement (reported)

- **Automated script review.** A Roblox Developer Relations announcement of 2020-03-20 says: "We have a system that
  automatically checks code for inappropriate content. If code gets flagged, the script then gets sent to a
  specially-trained team for manual review" ([488833](https://devforum.roblox.com/t/clarification-on-code-flagged-for-safety-review/488833)).
  It lists discriminatory language, personal information and threats as examples, and says nothing about
  obfuscation.
- **Community reading.** A 2023–2026 thread holds that obfuscating your own game is allowed and that the rule targets
  uploads that mislead users ([2501549](https://devforum.roblox.com/t/is-it-allowed-to-obfuscate-our-game-code/2501549)).
  No staff replied.
- **Contrary anecdote.** One user reports an account action after uploading Luraph-obfuscated code
  ([2504080](https://devforum.roblox.com/t/why-is-roblox-banning-for-using-obfuscation/2504080)). It is unconfirmed.
- **Scanner noise.** Automated moderation once flagged `print("require")` [CSB §6.1].

### 1.5 What remains of each refused item, once the Creator Store reason is gone

| Item | Creator Store reason | Reasons that remain for shards in the developer's own place |
|---|---|---|
| Obfuscated or VM-processed shards | does not apply | A VM interpreter loses Luau's fast calls and constant folding [CS §2.2], which costs speed (principle 2: a cost to weigh). A reviewer can't read the output. Moderation risk is anecdotal (§1.4) |
| `getfenv`/`setfenv` in shards | does not apply | **Deoptimises the whole module** (documented: native-code-gen "Code to avoid"; [CS §2.2] traces it in `lvmexecute.cpp`) |
| `loadstring` in client shards | does not apply | **Platform.** Clients have no `loadstring`; `LoadStringEnabled` is server-only and `NotScriptable` [CSB §3.4] |
| `require(assetId)` in client shards | does not apply | **Platform.** Requiring by asset id "only works on the server and will error on the client" (documented, `ModuleScript.yaml`) |
| Large generated scripts | does not apply | `Script.Source` is capped at 200,000 characters when set the ordinary way (**reported**, [3928089](https://devforum.roblox.com/t/increase-script-source-property-character-limit-from-200000-to-support-code-generation-and-export-tools/3928089), 2025-09-10). A reply says `ScriptEditorService:UpdateSourceAsync` went past it to 500,000 |

---

## 2. Per-player code delivery

### 2.1 Which container reaches one player only

| Container | Server can write it | Tags (API dump 0.741.19, verified) | Reaches |
|---|---|---|---|
| `Player.PlayerGui` | yes | `NotCreatable, PlayerReplicated` | that player only (the tag; documented per-player use; Adonis) |
| `Player.PlayerScripts` | **no**: "not accessible to the server" (documented, `PlayerScripts.yaml`, `data-model.md`) | `NotCreatable, NotReplicated` | — |
| `Player.Backpack` | yes | none | every client, through the `Player`, which replicates to all (**unverified** for other players' clients; no tag restricts it) |
| `Player.Character` | yes | — | every client within streaming range |
| `ReplicatedFirst`, `ReplicatedStorage` | yes | — | every client |
| `ServerStorage`, `ServerScriptService` | yes | `ServerStorage`: "only meant for server use"; SSS scripts "never replicated" (documented) | no client |
| Workspace models with `PersistentPerPlayer` | yes | — | not exclusive: they still stream normally to other players (documented, `workspace/streaming/index.md`) |

So the mechanism is this:
1. Keep N variants in `ServerStorage`.
2. At join, clone one into a `ScreenGui` with `ResetOnSpawn = false` under that player's `PlayerGui`.
   - `LayerCollector.ResetOnSpawn` exists (verified).
   - `StarterGui.ResetPlayerGuiOnSpawn` is deprecated (verified).
   - The docs say that on respawn PlayerGui contents "are cleared and replaced" (documented), so the
     `ResetOnSpawn = false` container is required.

**Prior use (verified, source).** Adonis (`Epix-Incorporated/Adonis` HEAD `75b17f0`, `MainModule/Server/Core/Core.luau`
lines 440–480) does exactly this per player:
- `p:FindFirstChildOfClass("PlayerGui") or p:WaitForChild("PlayerGui", 600)`;
- a `ScreenGui` with `ResetOnSpawn = false`, `Enabled = false`;
- a folder named by `HttpService:GenerateGUID(false)`;
- its client modules cloned into that folder.

Its comment reads: "Roblox, seriously, please give the server access to PlayerScripts already so I don't need to do
this."

### 2.2 Does the bytecode go only to that client?

- A `ModuleScript` in `ServerStorage` never replicates (documented). Only the clone parented into one `PlayerGui`
  replicates, and only to that player (the `PlayerReplicated` tag).
- **Roblox does not document** how it transmits script code. Its own docs say clients can "Decompile any replicated
  LocalScript or any ModuleScript, even if they never run on the client" (documented,
  `scripting/security/security-tactics.md`). So code ships with the replicated instance.
- I found no document or engine post on whether bytecode is ever sent outside instance replication, for example by
  a shared cache or a CDN (**unverified**; searched "bytecode replication", "script cache", "join").
- **Another player's variant.** It is not replicated to other clients (the tag). Other clients can only learn it if
  that player shares it. Variants differ per player, so a variant shared between accounts identifies whose variant
  it was. That is the attribution use in [AD §6].

### 2.3 Timing

- **`PlayerGui` exists from join.** "When a player first joins the experience, their PlayerGui is automatically
  inserted into their Player object" (documented). StarterGui contents are copied only when the character first
  spawns, and never while `CharacterAutoLoads = false` (documented). A clone that the server parents itself does
  not wait for spawn. It needs only the `PlayerGui` instance: Adonis waits up to 600 s for it.
- **Before the client's first send?** Lync's client starts on first use [`v5.md` §3.5]. The client shard's
  `require` must find the variant, so the client must `WaitForChild` it under `PlayerGui`. The order between
  `ReplicatedFirst`/`ReplicatedStorage` content and a server-parented `PlayerGui` child is **undocumented**: measure
  it in Studio and live.
- **`ReplicatedFirst`** replicates "before anything else" to *all* clients (documented). It can carry the loader
  that waits, but never a per-player variant.
- **`StreamingEnabled`** applies "exclusively to instances that are descendants of `Workspace`". `ReplicatedStorage`
  and `ReplicatedFirst` "are ineligible for streaming" (documented). `PlayerGui` is not under Workspace, so
  streaming does not delay or drop a variant (my inference from the scope sentence; **unverified** by a test).

### 2.4 Limits

| Limit | Value | Source |
|---|---|---|
| Place file | 100 MB; save or publish "might fail" beyond it | documented, `projects/place-files.md` |
| Script source | 200,000 characters set the ordinary way; 500,000 reached through `UpdateSourceAsync` | reported (§1.5) |
| Scripts per place | no documented limit found | unverified |
| Native code size | a per-game limit, read with `debug.dumpcodesize()` (server) | documented |

**Pool sizing, derived.**
- One 64 KB-source shard (`maxShardBytes` [CSB §5.2]) is about 17–40% of the 200,000-character cap.
- With N variants of S bytes, the place grows by N × S: 100 variants of 64 KB is 6.4 MB, 6.4% of the place limit.
- Server memory grows by N loaded-but-unrequired modules, plus one clone per player (the size of an instance
  holding source and bytecode: unmeasured).

---

## 3. What a client can read from a shard

### 3.1 Already established

- **Executor capabilities.** [CS §1.2] lists what in-process executors can read and call, with sources. That covers
  module requires, the garbage-collector walk, upvalues and constants of Lua closures, nested prototypes, script
  bytecode and decompilation, at identity 8. [CS §2.1] adds that Roblox's own docs confirm decompilation, and that
  local names are not shipped.
- **Rotated constants.** "The constants sit in the client's bytecode as K constants and can be read with
  `getconstants` or a decompiler. Rotation shortens the shelf life of static tooling to one release; it is not a
  secret" [CSB §2.3].
- **No coverage in `anticheat-design.md`.** It defers client tamper detection to `client-security.md` [AD intro].
- The executor API surface itself is the other researcher's topic. This section adds only compiler facts.

### 3.2 Where a per-build value lands, by how the generator writes it (verified, `placement.out`, Luau 0.742 `-O2`)

| Generator form | Bytecode | Where the value sits |
|---|---|---|
| (a) small integer literal, e.g. `1234` | `LOADN R4 1234` | instruction immediate; **not** in the constant table |
| (b) large integer literal, `0x6c796765` | `FASTCALL2K 32 R1 K0` with `K0: 1819895653` | function's constant table |
| (c) expression of literals, `bxor(0x6c796765, 0x12345678)` | folded to a single `K0: 2118988061` | function's constant table: identical to (b) |
| (d) computed at load from a table, held in a local | `GETUPVAL R4 U0` + `FASTCALL2` | the inputs are in the **top-level** prototype's constant table (`K6`, `K7`); the result is an upvalue |

**What this means for the defender:**
- **Placement moves a value; it never removes it.** Each form changes which part of the same bytecode holds the
  value: an immediate, the function's constants, or the module's top level plus an upvalue. In every form the
  value, or what it is computed from, ships in that client's bytecode.
- **Placement buys nothing against a reader of the whole shard.** It only changes the work a tool written against
  one form needs when the form changes. That is the "rebuilt per release" cost [`v5-integrity.md` §2] already
  claims for rotation.
- **Cost of each form.**
  - (b) and (c) are the same, because `-O2` folds constant expressions.
  - (d) replaces `FASTCALL2K` (constant operand) with `GETUPVAL` + `FASTCALL2`: one extra instruction per use.
    CSB §2.3 measured that difference as lost in noise for `tagWord`.
  - (a) is free, but only works for values in the signed 16-bit range.
- **Per-player variants.** These change *which* values each client holds. They do not change what a client can
  read of its own variant.

---

## 4. Generated straight-line code: native codegen and Luau limits

### 4.1 Native codegen on clients

- **Documented:** "server-side scripts in your game can be compiled directly into the machine code"
  (`luau/native-code-gen.md`, fetched 2026-10-15). No client platform is listed.
- **Reported, 2026:**
  - A 2026-08-11 bug report: native codegen "works in Studio on the client but not in the Roblox client"; LuauHeap
    shows `[native]` "on the Server only". A rumour of Android-only client support was not confirmed by its author
    ([4804395](https://devforum.roblox.com/t/native-code-generation-warning-message-inconsistency-and-confusion-supported-devices-give-no-warning-if-it-chose-not-to-compile-as-ncg/4804395)).
  - A non-staff post of 2026-09-03 says Roblox "did enable NCG for Android devices"
    ([3170510 p3](https://devforum.roblox.com/t/enable-native-for-clients/3170510?page=3)). **Unverified**: no
    staff statement found.
- **Consequence.** `--!native` and `@native` in a client shard cost nothing and gain nothing today. This matches
  [AD intro], `landscape.md` §3.2 and `v5.md` §0's split of client figures as interpreted. If client native
  codegen arrives, a client shard's speed changes; its behaviour does not (documented: "behavior … is exactly the
  same").

### 4.2 Compiler and VM limits (verified, Luau 0.742 source and `limits.out`)

From `Bytecode/include/Luau/BytecodeBuilder.h`:

| Limit | Value | What hits it in generated code | Probe result |
|---|---|---|---|
| locals per function | 200 (`kMaxLocalCount`) | 201 top-level `local function`s, or a record encoder that keeps 200+ fields in locals | `locals_201`: "Out of local registers when trying to allocate f199: exceeded limit 200"; `regs_260` fails the same way at `a198`, before the register limit |
| registers per function | 255 (`kMaxRegisterCount`) | very wide expressions or calls; the local limit bites first for straight-line code | — |
| upvalues per function | 200 (`kMaxUpvalueCount`) | a function that captures 200+ top-level locals | from source (`Compiler.cpp:158`) |
| constants per function | 2^23 (`kMaxConstantCount`) | per-build constants | `consts_40000` compiles: 40,000 distinct constants in one function |
| closures per prototype | 2^15 = 32,768 (`kMaxClosureCount`) | more than about 32,767 definition functions written in one module's top level | `closures_33000`: "Exceeded closure limit; simplify the code to compile" |
| jump distance | 2^23 | one function over about 8 M instructions | — |
| instructions per module | 10^9 (`kMaxInstructionCount`) | — | — |

**No constant-count performance cliff.**
- `FASTCALL2K` carries its constant index in a 32-bit AUX word. All 256 and 1,000 constants used `FASTCALL2K` with
  no fallback load (`consts_256`, `consts_1000`).
- Only beyond 32,767 constants does the cold fallback path use `LOADKX` (8,262 of them in `consts_40000`). The fast
  path is unchanged.

**Native limits, server shards only** (documented, and in source `CodeGen/src/CodeGen.cpp:49–56`):
- 1,048,576 IR instructions per module (`CodegenHeuristicsInstructionLimit`);
- 32,768 blocks per function;
- 65,536 instructions per block.

Roblox's values for these FInts are **unverified**. The docs quote "64K", "32K" and "1 million", which match the
defaults.

**Bound on per-build variation, derived.**
- The shapes that varying seeds produce (field order, constants, immediates) do not change register, local or
  closure counts [CSB §2.3: same opcode count per seed].
- The limits therefore bound the *size* of a shard, not how much it varies. The shard rules already respect them:
  definitions in a table, small functions per definition, `maxShardBytes` [CSB §2.1].
- A generator that adds variation by inlining more code per definition reaches the 32,767-closure and 200-local
  limits long before the constant limit.

---

## 5. Generated code size and loading cost

### 5.1 Measured: bytecode load (verified, `loadcost.out`)

`luau_load` deserializes bytecode. On Roblox, that is the step after a ModuleScript's bytecode reaches the client;
clients do not compile [CSB §3.4]. "Top level" is the first call of the chunk, which is what `require` runs. Median
of 41 runs; fresh `lua_State` each run.

| Module | Source | Bytecode `-g0` | `luau_load` median | ns per byte | Top level |
|---|---|---|---|---|---|
| 1 function, 200 constants | 10.6 KB | 15.2 KB | 14.6 µs | 0.96 | 0.3 µs |
| 1 function, 1,000 constants | 53.7 KB | 77.6 KB | 44.7 µs | 0.58 | 1.0 µs |
| 2,000 small definition functions | 140 KB | 188 KB | 446 µs | 2.36 | 88 µs (2,000 closures) |
| 1 function, 40,000 constants | 2.2 MB | 2.78 MB | 1.78 ms | 0.64 | 5.3 µs |

`-g1` (line info) adds 19–22% bytes and about the same load time per byte.

**Per-shard estimate, derived.** A 64 KB-source shard is about 90 KB of bytecode.
- Shaped like one large function: about 50–90 µs to load on this Xeon.
- Shaped as many small definitions: about 200 µs to load, plus about 45 ns per closure at the top level.
- A per-player variant costs the same as a shared shard on that client.
- Phone factor: **unmeasured**.

### 5.2 Not found

- Roblox's own figures for client script load time per KB: none found (searched creator docs and DevForum).
- Whether Roblox caches bytecode across servers or places, on the client or the CDN: **unverified**. No document
  found. One DevForum feature request covers on-disk caching of CDN assets such as meshes and images, not scripts
  ([230003](https://devforum.roblox.com/t/caching-system-for-assets/230003)).

**Consequence.** Per-player variants defeat any cross-player sharing that may exist, because each variant is
distinct. Per-build variants defeat cross-version sharing. Both effects are at most one shard's load cost per join
(§5.1).

---

## 6. Prior art

### 6.1 Roblox

- **Adonis** (verified, source):
  - its server remote is named by `HttpService:GenerateGUID(false)` once per server (`Core.luau:49`, `:235`);
  - each player's client folder and event name are fresh GUIDs (`:444–445`);
  - the client is delivered per player through `PlayerGui` (§2.1);
  - `Remote.luau` carries a keyed `bxor` transform of remote payloads (`Remote.NewDecrypt`, line 32).

  Adonis ships its client anti-exploit checks off by default because of false positives [CS §5]. No public figure on
  what the per-player naming bought was found.
- **Networking libraries.** No Roblox networking library was found that ships per-build or per-player randomized
  codecs.
  - Searched: Blink, Zap, ByteNet, Packet, Warp, Red, QuickNet, Jolt [`landscape.md` §1].
  - Red's README claims a single remote "obfuscates network data" [`landscape.md` §1.5].
  - Blink's ids vary per compile only by accident: issue #101, "non-deterministic ids (derived from the compile
    timestamp)" [`landscape.md` §1.2]. Users filed this as a bug, which shows that unseeded per-build variation
    hurts determinism. Lync's seeded, recorded build seed avoids that [CSB §2.2].

### 6.2 Outside Roblox

- **Per-build opcode renumbering.** It is reported in MMO protocol reverse-engineering. An Aion Classic write-up
  observes that "the cipher + opcode-obfuscation formulas tend to hold across nearby builds, but the opcode values
  and packet offsets can shift"
  ([RaGEZONE](https://forum.ragezone.com/threads/aion-classic-server-protocol-reverse-engineering-%E2%80%94-crypto-opcodes-packet-structures.1267025/),
  reported).
  - What it bought: third-party tools must re-derive the mapping on every build. It is not a barrier.
  - This is the same effect `v5-integrity.md` §2 claims for rotation.
- **Literature.** "SoK: Automated Software Diversity" (Larsen et al., IEEE S&P 2014,
  [pdf](https://oaklandsok.github.io/papers/larsen2014.pdf)) frames diversity as raising the attacker's cost per
  variant. A follow-up warns that diversity techniques "do not compose in general"
  ([Davis et al.](https://people.cs.kuleuven.be/~stijn.volckaert/papers/2016_LAW_Diversity.pdf)). For Lync, stacking
  per-build, per-server and per-player variation needs each layer's effect stated on its own, not assumed to add up.
- **Not found:** a public, measured report from a game studio on what per-build or per-player client polymorphism
  bought against cheats. I searched for MMO opcode shuffling, polymorphic clients, and software diversity in
  anti-cheat. Behavioural server-side detection is the recommendation most often found instead (reported; consistent
  with [AD §5]).

---

## Implications

Each line is a recommendation for the re-judgement, followed by the findings behind it.

1. **Withdraw the Creator Store reason for generated shards. Keep it for the runtime package and the plugin.**
   (§1.1)
2. **Re-judge VM or obfuscator output for shards on cost and reviewability, not on platform rules.** Keep it out
   by default. It removes fast calls and folding. And because a client reads its own shard (§3.2), its only gain is
   more re-derivation work per build. (§1.2, §1.5, §3)
3. **Keep `getfenv`/`setfenv`, `loadstring` and `require(assetId)` refused in client shards,** with corrected
   reasons:
   - `getfenv`/`setfenv`: deoptimisation;
   - `loadstring` and `require(assetId)`: platform (they error or are unavailable on clients). (§1.5)
4. **Per-player variants are feasible.** Re-judge them on cost, now measured:
   - one extra load of about 50–200 µs per join on this Xeon;
   - N × shard bytes in the place (6.4 MB for 100 variants of 64 KB);
   - a `ResetOnSpawn = false` container and a client `WaitForChild`;
   - a Studio measurement of arrival order before the first send. (§2, §5.1)
5. **If variants ship, state their protection exactly.** They make byte tools and shared captures per-player, and
   they attribute a leaked variant to one account. They give no secrecy from that player's own client. (§2.2, §3.2)
6. **Specify the client shard for the interpreter.** Keep `generate.native` at `"server"`. Revisit only when Roblox
   documents client native codegen. (§4.1)
7. **Add generator invariants:**
   - at most 200 locals and 200 upvalues per generated function;
   - at most about 32,000 closures per module prototype;
   - a source size under 200,000 characters per shard (the 64 KB `maxShardBytes` default fits);
   - server shards under the 1 M native IR instruction budget. (§2.4, §4.2)
8. **Choose constant placement by cost alone.** Literals and folded expressions are equivalent; computed-at-load
   costs one `GETUPVAL` per use. None changes what the client holds. (§3.2)
9. **Measure in Studio and live before committing variants:**
   - the arrival order of a `PlayerGui` child against `ReplicatedFirst` and `ReplicatedStorage`;
   - phone load time per KB;
   - whether `Backpack` reaches other clients. (§2.1, §2.3, §5)
10. **Treat bytecode caching as unknown.** Do not claim join-time savings from shared shards, or penalties for
    per-player ones, beyond §5.1's per-load cost. (§5.2)
