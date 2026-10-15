# Lync v5: client-side integrity (milestone 5)

Draft 3.6, 2026-10-15. Part of the v5 design (`v5.md`); changes from draft 3.5 are in
`v5-3.6-changes-integrity.md`. The tag, the replay window, the id permutation and the key derivation are part of
the frame format and are specified in `v5.md` §4.5 (milestone 2). This file specifies the rest and gives the case
for each measure; everything in it is milestone 5, except the published-place check (§11, milestone 6). Refused
measures, re-judged, are in `v5-changes.md`. "Unmodified client" is defined in `v5.md` §1.

## 1. How measures are judged

An executor reads and rewrites every Lync table, upvalue and constant on its client and can call Lync's own API
`[client-security §1.2]`. Client-side measures cannot make a forged message impossible. Each is judged by the
recurring work it imposes on a modified client against its runtime, wire, size and developer cost, and by `v5.md`
principle 2 that cost is weighed, never a veto by itself: where it matters, an option controls it. "A modified
client with full memory access can defeat it" and "a universal counter exists" are not reasons on their own: Lync
varies what a counter depends on per build (§2), per server (permutation), per session (the key) and per player
(§2.4), so a counter written against one has to be rebuilt or re-run against the next. Every measure is judged
against the capability classes below `[security-tooling §9]` `[generation-methods §0]`.

| Capability class | What a modified client does with it | Measures that price it |
|---|---|---|
| none (no key): raw sender, replayer, static forger | fires Lync's remotes with built or captured frames | tag, replay window, permutation, the server's shape and budget checks (`v5.md` §4.5, §6.1) |
| **code**: reading its own bytecode and constants | reads layouts, constants and lists from the shards | per-build values (§2): each build's must be read again |
| **mem**: reading and writing Lync's upvalues, stack and GC objects | reads key, count and permutation; calls Lync's internal encoder and tag function | count lockstep (slips are `tagMismatch`/`frameGap`), per-session key and permutation, per-build values |
| **api**: requiring client modules, calling Lync's API | fires definitions through Lync's own encoder | traps and reachability (§3), caller probe (§4), reactions and challenges (§7) |
| **hook**: hooking functions and metamethods | changes values above the encoder; spies on remotes | server checks only; the tag, for edits below the encoder within `tag.cover` |
| **signal**: firing or disabling its own connections | injects inbound frames into its own view | refused-frame report (§5) |
| **packet**: send and receive hooks below Luau | reads, drops or edits frames | tag and replay window; the key derived from a `WELCOME` nonce (`v5.md` §4.5) |
| **identity**: thread identity control | runs at identity 8 by default | caller probe, identity read (§4) |
| **naming**: naming or hiding chunks and stack frames | makes executor code read as game code | caller probe, source check (§4) |
| **clock**: clock and frame-rate control | accelerates or slows its clock; answers before an ask could arrive | clock beacon (§6), timing facts (§7) |
| **state**: reading replicated state | reads everything Lync replicates to it (ESP, aim, auto-collect) | decoys (§8), canaries (§9) |
| **share**: carrying artefacts between machines and accounts | runs a tool, layout, mask or value taken from another account | per-build values (§2), per-player variants (§2.4), per-viewer canaries (§9) |

- **Tamper cost of the milestone 2 measures.** The tag makes a forger hold this session's key and keep the count
  in lockstep with Lync's own sends. The key reaches the client as a nonce it derives the key from under a
  per-build secret (`v5.md` §4.5), so a packet-level hook must also read that secret from the shard each build; a
  memory reader takes the derived key from Lync's state. The permutation makes a byte tool read this server's seed
  every session `[review-2 m5]` `[generation-methods M8]`.
- **Client-stated measures** (`REPORT`, the caller bit) are judged against the tools they target, which leave Lync
  unpatched: executor code calling Lync's API and injectors of inbound frames. "A patched Lync suppresses it" is
  true of every client-stated count and is no reason about one `[refusals-rejudged-2 Impl2]`.
- **Facts, never consequences.** Lync drops only what it cannot deliver (malformed input, budgets, a trap's
  messages, which have no handler) and reports facts. It has no quiet mitigation hooks (R22), no suspicion
  weights or scores (R23) and no automatic kick, ban, throttle or client-visible rejection (R24): each would be
  Lync deciding policy, which is the game's code (`v5.md` §0).

## 2. Per-build and per-player values

### 2.1 Decision: what the build publishes and what it keeps

- **Problem.** Every per-build value is a pure function of the planner (open source, pure Luau), the shared schema
  module (replicated to every client) and a seed. Draft 3.5's seed travelled in `HELLO` and every shard header, so
  a tool that runs Lync's planner on the schema and the seed from a captured `HELLO` reproduced every per-build
  value with no per-build work, and the values priced only tools that hard-code them `[generation-methods §0.1]`.
  The server still has to tell shards of different build runs apart, which needs a value both sides carry.
- **Options:** one public seed (draft 3.5); a private seed in the shards only, with no identity check (shards of
  different runs would then decode each other's frames wrongly and silently); **two values per build run: a public
  `buildId` that `HELLO`, the shard bodies and the manifest carry, and a private 64-bit `rotationSeed` that only
  the manifest holds, from which every per-build value is drawn.**
- **Choice: two values** `[generation-methods M1]`. The server compares `buildId` (a difference is `MISMATCH`,
  `v5.md` §4.6). 64 bits remove the offline search that one observed record order would allow against a 32-bit
  secret. The seed must come from OS entropy, since a clock-seeded draw is searchable from the build's approximate
  time; the manifest never ships (`v5-tooling.md` §1.2). Re-deriving the values then takes the shard's code each
  build (**code**) or a calibration through the shard's own encoder (**mem**), redone per build.
- **Public-quality seeds.** A host with no verified OS entropy source draws a seed that may be searchable: the
  Lune host, and the Studio plugin's "Prepare release" (`HttpService:GenerateGUID()`, entropy source undocumented)
  (`v5-tooling.md` §4.1, §4.2; §12). Under such a seed every value below prices only tools that hard-code it.

### 2.2 Values drawn per build

- **Streams.** A per-build value is drawn from the stream of a label L (UTF-8 text): xorshift32 (`v5.md` §4.5)
  seeded with the low 32 bits of HalfSipHash-2-4 keyed by `rotationSeed` (two u32, low first) over L with 64-bit
  output, 0 replaced by `0x9E3779B9`. v64(L) is that 64-bit output itself. Values are emitted as literals: a literal
  and a folded constant cost the same, and a value computed at load costs one `GETUPVAL` per use
  `[generation-security §3.2]`. Woven sites take every value from the same IR as the shard (`v5-tooling.md` §5.6).
- **Identity.** At `rotationSeed` 0 every value takes its identity (name order, offsets 0, the reference constants,
  S = 0, no masks) and `buildId` is 0, so the seed-0 golden set (`v5.md` §4.10) is unchanged
  `[generation-methods §0.4]`.
- **Codec paths** are the planner's diagnostic paths (`arena.strike.data.target`,
  `arena.trade.data.offers[].item`), with a map's keys at `<path>{k}` and its values at `<path>{v}`, and a
  collection's key at `<namespace>.<collection>.key`.

| Value | Stream | Rule | Changes | Prices (§1) |
|---|---|---|---|---|
| field order of each record | `order:<record path>` (`order:arena.fighters.data`) | Fisher–Yates over the fields in name order, from the last index down, j = x mod (i + 1) | the order of field writes in single rows, and of a record's columns in column blocks (`v5.md` §4.3), both directions | static encoders, decoders and byte scripts made against another build (**code**, **share**); a one-field record, a bare codec and a union's index have no order to rotate |
| code offsets (`build.offsets`) | `offset:<codec path>`; a codec with several bounded codes takes consecutive outputs in write order | a bounded code q of n codes travels as w = (q + c) mod n with c = x mod n, written `if q >= n − c then q − (n − c) else q + c` (exact up to n = 2^53); the decoder checks w < n (rule 2), inverts, then applies rules 3 and 6 to q | the value-to-code map of `t.int(min, max)`, `t.number`, `t.angle`, `t.color3` channels, `t.direction` and `t.rotation` components, list-enum and union-variant indices, bools (an XOR), and string, buffer, array and map lengths and counts; not `t.int()` (EG-coded), raw `t.f32`/`t.f64`/`t.vector3f32` bits, Roblox enums, instance indices or protocol fields | as field order, and also the definitions field order leaves fixed (`buy`'s enum, `announce`'s variant index); one known value of a field gives its c |
| tag initialisation constants | `tag` | the first two outputs replace `0x6c796765` and `0x74656462` | the tag of every upstream frame | tag reimplementations that don't call Lync's own tag function; not a **mem** tool, which calls it |
| key-derivation secret S | v64(`session`), 0 replaced by 1 | `v5.md` §4.5 derives the session key and permutation seed from the first `WELCOME`'s nonce under S | none: the fields keep their widths | **packet** tools that read the key from `WELCOME`, which must now read S from the shard each build |
| identity-probe member | `probe` | index x mod (list length) into §4's list | none | a tool that spoofs one member's read |
| variant masks | `mask:<v>:<r>` | §2.4 | §2.4 | §2.4 |
| generated trap names and source codecs | `trap:<namespace>:<k>` | §3 | §3 | §3 |

- **Not varied per build:** union variant order and ids `[review-2 m1]`; the column mode, which a build could fix
  but which prices no capability class at +7% to +588% bits per column `[generation-methods M5]`; and enum and
  variant indices by permutation, which prices the same tools as an offset at 0 to +194 bits per structured column
  block against an offset's 0 to +77 `[generation-methods M3]` `[security-costs claim 11d]`.
- **Never per session or per player downstream.** Downstream chunks are encoded once and copied, and identical
  frames go through `FireAllClients`; a layout that varied per session or per player would end both
  `[generation-methods §0.2]`. Per-session and per-player values vary the tag and nothing downstream.
- **Column blocks** code the first row against 0 (`v5.md` §4.3), so an offset shows in every value of a block, at
  up to +77 bits per column in the measured patterns and fewer at n = 4; coding it against c would cost 0 bits and
  leave the block readable by a decoder that ignores c `[generation-methods M3]`.
- **Runtime path.** It has no build and so no private value: `layout.vary` varies field order, offsets and tag
  constants per server from what `WELCOME` carries (`v5.md` §4.5, §7.5), which prices only tools that hard-code a
  no-build game's layout `[generation-methods M14]`.
- **What the values price, overall:** a modified client that encodes or decodes outside Lync's own functions
  (static forgers, extractors encoding outside `fire`, byte scripts carried between accounts) must re-read the
  shard's code, or recalibrate through its encoder, every build. Not priced: **api** (Lync applies every value for
  its caller), **hook**, **state**, and a tool that calibrates against the loaded shard each session
  `[generation-methods §0.3]`.

### 2.3 Decision: tag rotation amounts and round counts

- **Problem.** Two levers beside the constants vary the tag function: its six rotation amounts (reference
  5, 16, 8, 7, 13, 16) and its round counts (1-3). Amounts and finalization rounds are build-time immediates at no
  measurable run-time cost; each compression round above 1 costs about 19 ns per covered byte interpreted and
  2.7 ns native. The hard constraint: the reference amounts carry HalfSipHash's published analysis, altered sets
  have none, and 16 of 40 random sets need one round more for full diffusion `[client-self-checks U2]`.
- **Options:** (a) reference amounts and rounds `[generation-methods M2]`; (b) amounts from a vetted pool of 16–64
  sets (4–6 bits of variation) and finalization rounds d from {3, 4}, each pool entry with its own golden vectors;
  (c) (b) plus `build.tagRounds = [min, max]`, compression rounds drawn per build `[client-self-checks U2]`.
- **Choice: (a).** Amounts and round counts sit in the function, and are read in the pass, that the two constants
  already make a tool re-read each build, so a tool that reads the constants gains them by a one-time change: (b)
  and (c) add no recurring work `[client-self-checks U2, "What it does not price"]`. (b) also gives up the analysed
  reference for unanalysed sets, a cost to the tag's own strength. Keyless acceptance is set by the tag width and
  is unchanged by either `[refusals-rejudged-3 R28]`. The round count stays a protocol constant (`v5.md` §4.9).

### 2.4 Per-player variants

- **Mechanism** (generated path; `build.playerVariants` N ≥ 2 and a nonzero `rotationSeed`)
  `[generation-methods M7, M10, M12, M13]`:
  - **Masks.** m_v (v = 1 … N) is the low 32 bits of v64(`mask:<v>:<r>`) for the first r = 0, 1, … that gives a
    nonzero value differing from m_1 … m_(v−1). The server shard holds every mask and `VARIANT_OF` (mask to v);
    the build writes `ModuleScript`s `Variant1` … `VariantN` as children of the server shard (never replicated),
    each returning its mask as an integer literal.
  - **Assignment**, at `Players.PlayerAdded` and for players present when the server shard loads, before cloning:
    the lowest-numbered variant no present player holds; when every variant is held, the one the fewest present
    players hold, lowest number first. It lasts for the connection; a rejoin is assigned again. While N is at least
    the number of concurrent players, no two present players share a variant.
  - **Delivery.** The server clones `Variant<v>` into a new `ScreenGui` named `Lync` (`ResetOnSpawn` false,
    `Enabled` false) parented to the player's `PlayerGui`, whose children replicate to that player only
    `[generation-security §2.1]` `[interest-rewind §13.1]`.
  - **Client.** At first use the shared client shard starts a thread that waits for `PlayerGui.Lync`, requires its
    module and installs the mask; `require` of the shard never yields. It binds once per connection and ignores
    later changes under `PlayerGui`.
  - **Tag** (`v5.md` §4.5). The client's tag is the keyed hash XOR m_v; the server verifies under the assigned
    mask. A frame that fails under it at every candidate, and whose tag XOR the keyed hash at some candidate is
    another variant's mask, is `tagVariant` (§10) in place of `tagMismatch`: dropped, e unchanged, counted toward
    `desync`.
  - **Join.** `HELLO` is untagged and comes from the shared shard, so it never waits for the variant. A namespace's
    join hold (`v5.md` §5.3) releases once its `WELCOME` has arrived and the variant is installed; until then
    reliable sends wait in the hold, and an unreliable send after `WELCOME` but before the variant is dropped as
    `sendDropped` with its own cause (`v5.md` §7.3). Held sends stay encoded bytes: the tag is computed at send and
    layouts don't vary per player.
  - **`Lync.variantOf(player)`** (server) returns v, or 0 when there are no variants, so a game can log assignments
    and tie a `tagVariant` to the player who held that variant.
  - A variant not installed 10 s after the connection's first `WELCOME` is `variantMissing` (§10); the client keeps
    waiting.
- **Prices** **share**: a tag routine, mask or byte tool carried from one account to another fails under the
  receiving player's mask, and the server names its source variant on each frame, which the assignment ties to a
  player. Not priced: a tool that reads its own client's variant (**code**, **mem**: one integer in one module),
  **api** and **hook** (`fire` tags with the client's own mask), and keyless senders, which meet it only by chance
  (§10).
- **Decision: what a variant holds.**
  - *Problem.* A variant can vary the tag alone, or the upstream layouts as well; downstream stays per build either
    way (§2.2). The join hold holds encoded bytes, and a layout that arrives with the variant can't encode a send
    made before it.
  - *Options:* **a mask only**; the mask plus upstream encoders under the variant's own order and offsets, with
    held sends kept as values charged at their worst-case size `[generation-methods M12]` or at the seed-0 plan, and
    `HELLO` sent only after binding and accepted only with the assigned variant `[interest-rewind §13.2]`.
  - *Choice: a mask only.* A carried artefact already fails under another player's mask and is dropped and named
    before decode, so any layout it carries is never decoded; a tool that reads its own variant reads the layouts
    in the same module in the same pass. Per-variant layouts therefore add no recurring work beyond the mask, while
    costing N times the upstream codec bytecode in the place and the server shard (about 1.1 MB at 200 definitions
    and 16 variants), a value hold, a second join rule, and weaving, whose scripts every player shares
    `[codecs-in-scripts §8]`. Verifying under the assigned mask alone keeps a client from choosing its variant, the
    property `[interest-rewind §13.2]` rule 4 asks for. Per-variant tag constants or key secrets are not used:
    naming the other variant would take 5 × (N − 1) full hashes per failing frame, 31.4 µs native per 64 B frame
    at N = 16 `[generation-methods M13]`.
- **Cost.** Place: N modules of one integer. Server: the masks and `VARIANT_OF`, 13,312 B at N = 256; one index
  per player; one XOR per accepted frame (within noise); up to 5 table lookups per failing frame, +0.5 µs
  interpreted and +0.24 µs native at 64 B `[generation-methods M13]`. Client: one XOR per frame; one `ScreenGui`
  and module per player. Join: tagged sends wait max(0, variant arrival − first send); the arrival time after
  `WELCOME` is unmeasured (§12). Wire: none.

### 2.5 Options (`lync.toml`)

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `build.seed` | `"release"`, or 16 hex digits | — | `"0000000000000000"` (identity) to `"ffffffffffffffff"` | `"release"` | below |
| `build.offsets` | boolean | — | — | `true` (derived below) | +5.0 ns encode and +7.3 ns decode per bounded field interpreted, +5.0 and +5.9 ns native; 224 → 356 B per encoder and 223 → 351 B per decoder (+59%); column bits per §2.2; only at a nonzero `rotationSeed` `[generation-methods M3]` |
| `build.playerVariants` | integer | variants | 1–256 | 1 (chosen, below) | §2.4; 1 means no variants |

- **`"release"`**: each `lync build`, each `lync watch` rebuild and the plugin's "Prepare release" draws `buildId`
  uniform on 1–2^32 − 1 and `rotationSeed` uniform on 1–2^64 − 1, independently, from OS entropy, for every
  namespace and both sides of that run. Shards of different runs carry different `buildId`s and get `MISMATCH`.
- **16 hex digits** fix `rotationSeed`; `buildId` is then the low 32 bits of v64(`build`) (0 replaced by 1), or 0
  when `rotationSeed` is 0. This is for tests and reproducible builds: that `buildId` is a 32-bit check value over
  `rotationSeed`, which still leaves a 2^64 search.
- **Seed cost.** Zero at run time: seeded shards compile to the same opcode sequences (an 8-field codec pair is
  116 instructions and 1012 B at both seeds `[generation-methods M1]`); zero bytes; one HalfSipHash-2-4 per stream
  at build time. Developer: every `"release"` build changes every shard's bytes; client and server shards must come
  from one run; offline decoding (`lync replay`, the inspector) needs that run's manifest, since a captured `HELLO`
  no longer suffices (`v5-tooling.md` §1.2).
- **`build.offsets` default, derived.** At the busy model's 70 upstream messages a second (`v5.md` §4.1) with 3
  bounded fields each, offsets cost a client 70 × 3 × 5.0 ns ≈ 1.1 µs/s to encode; a collection of 64 records
  whose 5 bounded fields change at 20 Hz costs it 6,400 × 7.3 ns ≈ 47 µs/s to decode; 200 definitions add at most
  200 × 132 B ≈ 26 KB of client bytecode, 13–63 µs of load per join at 0.5–2.4 ns per byte
  `[generation-security §5.1]`. For that, every bounded field varies per build, including those of definitions
  whose field order can't.
- **`build.playerVariants` default, chosen.** At N ≥ 2 each join's tagged sends wait for an instance replication
  whose timing after `WELCOME` is unmeasured (§12); that measurement would change the default.

## 3. Traps and reachability

- **One fact, `unreachable`, evidence `declared` (0 or 1)** `[review-redundancy-2 5]`: a message of a client-sent
  definition that client code doesn't fire.
  - **Declared:** `Net.x:trap()` on the server view of an ordinary client-sent definition. The shared schema shows
    nothing special. Any arrival is dropped (a trap has no handler; `connect` or `handle` on it is a caller error;
    an ask is answered `rejected`, which is indistinguishable from a `validate` refusal, `v5.md` §5.2) and reported
    with `declared = 1`. Works on both paths.
  - **Inferred** (generated path, `check.reachability = true`): the build marks a client-sent definition reachable
    when its name appears after `.` or `:` as a field access, or as a string literal, anywhere in the scanned client
    code: scripts in replicating containers, `Packages/`, every `LocalScript` and every `Script` with
    `RunContext = Client` wherever it is stored, and every script under the instance paths listed in
    `check.clientRoots` (for roblox-ts, the compiled Luau). A namespace is incomplete, and nothing is inferred for
    it, only when its shard value is indexed with a non-literal expression. Aliases, `return Net`,
    `self.Net = Net` and passing the namespace around are not escapes `[review-2 m7]`. A message of an
    unreachable definition is delivered and reported with `declared = 0`. The rule over-approximates (any `.chat`
    counts), so an unmodified client produces it only through code the scan didn't cover: a `ModuleScript` stored
    outside the scanned code (in `ServerStorage`, say, inside a `Tool` cloned to a `Backpack` at run time) that
    fires the definition. Listing that container in `check.clientRoots` removes the cause.
- **Prices** API drivers firing definitions by name: they must learn, per game, what unmodified client code fires.
- **Cost.** One flag check and one table index per message; a trap takes one id. No bytes. The build scans the
  text of every scanned script once per build; its cost per MB of source is measured in milestone 5.

## 4. Caller probe and `REPORT`

- **Mechanism.** Each client `fire` or `invoke` is probed with probability 1/`callerProbe.oneIn`, at most
  `callerProbe.maxPerSecond` probes per second. A probe:
  - **identity:** reads, in `pcall`, one member that fails at identity 2 (game scripts) and succeeds at 8 (executor
    threads by default) `[client-security §1.2, §2.1]`; the member is chosen per build from those Studio confirms;
  - **source** (generated path, skipped for definitions with no listed scripts and for incomplete namespaces):
    reads `debug.info` source of the first frame outside Lync and checks it against the build's list of client
    scripts that reference the definition, after mapping Roblox's clones of starter containers
    (`StarterPlayerScripts` to `PlayerScripts`, `StarterCharacterScripts` to the character, `StarterGui` to
    `PlayerGui`, `StarterPack` to `Backpack`). `check.reachability = false` removes the lists, and with them the
    source check.
- **`REPORT`** (control type 5, up): `probes:EG0 identitySucceeded:EG0 sourceUnlisted:EG0 refusedFrames:EG0`,
  counts since the previous `REPORT`. It is sent only when one of the last three is non-zero, in the next frame the
  client sends anyway; it never forces a frame `[review-redundancy-2 8]`. The server reports one fact per non-zero
  count, each marked client-stated (§10): `reportedIdentity`, `reportedSourceUnlisted`, `reportedRefusedFrames`.
- **Prices** API drivers running at identity 8 under an unlisted chunk name: with every call probed (the default),
  the first call reports itself; at `oneIn` = n, with probability 1 − (1 − 1/n)^calls. A patched Lync stops sending
  counts, which the server can't tell from an unmodified client with nothing to report.
- **Cost.** A random draw per fire, 24–32 ns; at most `maxPerSecond` failing `pcall`s of 2.2–3.3 µs and source reads
  of 57–72 ns `[probes review-redundancy-2 inbound_hotpath]` `[client-security §2.2]`: at the defaults, at most
  0.2 ms of client CPU a second. No bytes beyond `REPORT`.
- **Unverified, checked in Studio before release:** a suitable member and its cost on devices; whether a capability
  failure caught by `pcall` is logged (if it is, every probe writes a client log line, which would move the default
  back to sampling); whether unmodified sources follow the clone mapping. If the last fails, the source check is
  removed.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `callerProbe.oneIn` | integer | calls per probe | 0 (off) or 1–255 | 1 | one draw per call; u8 in `WELCOME` |
| `callerProbe.maxPerSecond` | integer | probes/s | 1–63 | 60 | ≤ 3.3 µs per probe, ≤ 0.2 ms/s at 60; u6 in `WELCOME` |

## 5. Refused-frame report

The client decoder is as strict as the server's (`v5.md` §4.8). Each downstream frame it refuses is counted
(`refusedFrames`, `v5.md` §7.4) and reported in `REPORT`. It prices injectors of non-canonical frames into a
client's own view, who must build canonical frames for this build and server or patch Lync. Cost: none beyond
decode.

## 6. Clock beacon

- **Mechanism.** The client puts `BEACON` (control type 6, up: ⌊`GetServerTimeNow()` × 1000⌋ mod 2^16 as u16) in
  the first reliable frame it sends once `clock.beacon` tenths of a second have passed since its last beacon; it
  never forces a frame. Per player, the server keeps, per 5 s window, the minimum of arrival time − stamp, and every
  5 s fits a Theil–Sen slope over the last 12 windows (66 pairwise slopes) `[client-security §4 T1]`. It reports
  `clockRate` (§10) when `clock.reportFits` consecutive fits each have a slope above `clock.reportSlope`. The first
  30 s after join are ignored, and an arrival gap over 3 × `clock.beacon` restarts the estimate `[review-2 M7]`
  (constants: `v5.md` §4.9).
- **Default threshold.** `GetServerTimeNow` moves within 0.6% of the local clock, and the research estimates the
  fit's noise at 0.03–0.08% for envelope noise σ = 20–50 ms `[client-security §4 T1]`, so an unmodified client's
  slope stays under about 0.0068. The default 0.01 leaves a margin of about 4 times the upper noise estimate;
  the research proposed 0.03. Both noise and slew are unmeasured on Roblox devices (`v5.md` §10).
- **Prices** tools that accelerate the client's clock; they must keep Lync's stamps on unaccelerated time.
- **Cost.** 20 bits per beacon (type u3, count−1 EG0, u16), plus 2–4 bits of toc when the frame has no other
  control chunk: at most 3 B a second per player at the default. One 66-slope fit per 5 s per player on the server
  (CPU unmeasured, milestone 5).

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `clock.beacon` | integer | tenths of a second | 0 (off) or 5–15 | 10 | ≤ 3 B per beacon; u4 in `WELCOME` |
| `clock.reportSlope` | number (real) | fraction (seconds of drift per second) | 0.001–1 | 0.01 | none; server-only |
| `clock.reportFits` | integer | consecutive fits | 1–12 | 3 | none; server-only |

## 7. Early answers

- **Mechanism.** For each server `invoke`, Lync records the send time and samples `Player:GetNetworkPing()`. An
  answer arriving sooner than `earlyAnswer.factor` × the smallest ping sampled for that player in the last 10 s is
  delivered and reported as `earlyAnswer` (§10).
- **Prices** answers sent before the ask could arrive (a bot predicting a timed prompt gains up to one round trip).

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `earlyAnswer.factor` | number (real) | fraction of the minimum ping | 0 (off) to 1 | 0.5 | one clock read and one `GetNetworkPing` per server ask; no bytes |

## 8. Decoys

- **Mechanism.** `Net.fighters:decoys(behaviour, { maxPerViewer = n })` on the server view. Each state tick Lync
  calls `behaviour(viewer, tick)` for each viewer; it returns `{ [Key]: Record }` or nil. Lync diffs the result
  against the viewer's previous decoys and sends adds, updates and removes.
  - **No placement tell** `[review-2 M4]`: a viewer with decoys gets its own copy of each partition state chunk
    that has changes, re-encoded with its decoys' rows mixed in, so decoy updates ride where real updates ride.
    Their `:newest()` rows are per-viewer rows like any other.
  - **Slots.** Decoys take slots from a pool of `maxPerViewer` slots per collection, drawn at random among free
    slots and shared by every viewer's decoys (viewer A's j-th decoy and viewer B's j-th decoy use pool slot j).
    Real allocation never uses pool slots, so `maxRecords` must cover live records, the 2 s reuse delay and
    `maxPerViewer`. A decoy's key equal to a live record's key, or one that later becomes a real key while the decoy
    lives, throws `decoyKeyLive` in the behaviour's thread and the decoy is removed.
  - `Net.strike:refers("target", "fighters")` declares that a client-sent field holds keys of a collection; unknown
    fields or collections throw `unknownField` at the caller `[review-2 m10]`. A delivered message whose referenced
    key is a decoy sent to that player is reported as `decoyReferenced` (§10).
- **Prices** raw-state readers: a raw-state reader must reproduce the game's notion of visibility, per game and per
  behaviour. Remaining tell: two colluding accounts comparing key sets can spot a decoy where every viewer sees
  every record.
- **Developer cost.** The behaviour must place decoys where the game's own rendering and logic never use them; game
  code that targets every record it holds (aim assist, "target everything") produces `decoyReferenced`.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `maxPerViewer` | integer | records | 1–256 | 1 | per viewer with decoys: one re-encode of each changed partition chunk per flush and the decoys' bytes; one behaviour call and diff per viewer per state tick, 236 ns native `[probes review-redundancy-2 integrity_state]`; such viewers leave `FireAllClients` for those flushes; the pool takes `maxPerViewer` slots out of `maxRecords` |

## 9. Canaries

- **Mechanism.** `Net.inventory:canary("promoCode")` on the server view marks a top-level `t.string` or `t.buffer`
  field of a collection with `maxBytes` ≥ 12 (an unknown field throws `unknownField` at the caller, a shorter one
  `valueRefused`). On each add Lync fills it with 12 random characters from `[A-Za-z0-9]` (strings) or 12 random
  bytes (buffers), unique per record per server; `set` or `patch` of it is `canaryWrite`. The server keeps one
  server-wide map from value to slot and, per viewer, a bitset of slots whose add it sent.
- **Matching.** Every inbound string or buffer value of length 12 is looked up whole (a buffer is converted only
  after the length test). A value of 13 to `canary.scanBytes` bytes is also searched at every offset, and a longer
  one in its first `canary.scanBytes` bytes. A hit for a slot sent to that player is delivered and reported as
  `canaryEchoed` (§10) `[review-redundancy-2 9]`. Draft 3 matched whole values only `[review-2 m3]`; the scan finds
  a canary pasted into a chat line.
- **Prices** raw-state readers that send hidden values back, and attributes leaks (a canary found outside the game
  names its record and server).
- **Cost.** 12 B per add; 13 ns per inbound string of length 12, no allocation for buffers of other lengths; up to
  `scanBytes` − 11 lookups per longer value (per-offset cost measured in milestone 5); 47 KB for 100 players ×
  1024 records against 3.2 MB for per-player sets. Developer: the UI must never show or send the field.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `canary.scanBytes` | integer | B | 0 (whole values only) or 13–16,000 | 256 | up to `scanBytes` − 11 map lookups per inbound string or buffer value longer than 12 B, server-only |

## 10. Facts

Evidence is numbers only. "Client-stated" means the number comes from the client's own `REPORT`: a modified client
can send any value or none.

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `unreachable` | a message of a trapped definition (`declared` 1), or of a client-sent definition the build found no reference to in the scanned client code (`declared` 0; generated path, `check.reachability`) | trap: dropped, ask `rejected`; inferred: delivered | `declared` | declared: client code firing a definition the server marked with `:trap()`, a mistake in the game's declaration; inferred: a script outside the scanned code (§3), cloned to a client at run time, firing the definition |
| `earlyAnswer` | an answer to a server ask arriving sooner than `earlyAnswer.factor` × the smallest `GetNetworkPing()` sampled for the player in the last 10 s | delivered | `roundTrip`, `minPing` (s) | `GetNetworkPing` is smoothed, so it lags a sudden drop in latency (by how much is unmeasured, `v5.md` §10) |
| `reportedIdentity` | a `REPORT` with `identitySucceeded` > 0 | none | `reported` (client-stated count), `probes` (client-stated) | Lync called from the Studio command bar or a plugin (Studio only) |
| `reportedSourceUnlisted` | a `REPORT` with `sourceUnlisted` > 0 | none | `reported`, `probes` (both client-stated) | a client script firing the definition from a place the clone mapping (§4) doesn't cover, such as a script game code cloned outside the starter containers |
| `reportedRefusedFrames` | a `REPORT` with `refusedFrames` > 0 | none | `reported` (client-stated) | a Lync bug, in which case the client also lost that server frame |
| `clockRate` | at the end of a fit, the last `clock.reportFits` fits each had a slope above `clock.reportSlope` | none | `slope` (this fit's), `fits` (the run of consecutive fits above the threshold so far) | at the default threshold, none while the engine's 0.6% bound holds and fit noise stays under 0.4%; at a threshold of 0.0068 or less, a client correcting its clock at the maximum slew for `reportFits` fits, plus fit noise (0.03–0.08% at σ = 20–50 ms, estimated) |
| `decoyReferenced` | a delivered message whose `refers` field holds a key of a decoy sent to that player | delivered | `sentAgo` (s since the decoy's add) | game code that targets every record it holds (aim assist, "target everything"); a behaviour that places decoys where game code reads them |
| `canaryEchoed` | an inbound string or buffer value that is, or within `canary.scanBytes` contains, a live canary sent to that player | delivered | `sentAgo` (s since the record's add) | game code that sends a record's fields back to the server, canary included; a player's text containing a live canary by chance, probability 62^−12 per 12-byte window per canary sent to that player |
