# Lync v5: client-side integrity (milestone 5)

Draft 3.6, 2026-10-15. Part of the v5 design (`v5.md`); changes from draft 3.5 are in
`v5-3.6-changes-integrity.md`. The tag, the replay window, the id permutation and the key derivation are part of
the frame format and are specified in `v5.md` §4.5 (milestone 2). This file specifies the rest and gives the case
for each measure; everything in it is milestone 5, except the published-place check (§11, milestone 6). Refused
measures, re-judged, are in `v5-changes.md`. "Unmodified client" is defined in `v5.md` §1.

## 1. How measures are judged

An executor reads and rewrites every Lync table, upvalue and constant on its client and can call Lync's own API
`[client-security §1.2]`. Client-side measures cannot make a forged message impossible. A measure is adopted when
its fact is exact (an exact trigger, and every cause on an unmodified client listed, or "none" with the argument)
and its runtime, wire, size and developer cost is stated; by `v5.md` principle 2 cost is weighed, never a veto by
itself, and where it matters an option controls it. What a measure can't do is stated in its section, never used
as the reason against it: each section carries one line, **Universal counter:** yes or no, naming the one change
that defeats the measure in every Lync game and build where one exists. Whether a fact with a universal counter
informs anything is the developer's call, and where such a measure has a cost, an option turns it off. Only the
values of §2 and `v5.md` §4.5 (key, permutation) vary per build, server, session or player, so only for them does
a counter have to be rebuilt or re-run against the next. Every measure is judged against the capability classes
below `[security-tooling §9]` `[generation-methods §0]`.

| Capability class | What a modified client does with it | Measures that price it |
|---|---|---|
| none (no key): raw sender, replayer, static forger | fires Lync's remotes with built or captured frames | tag, replay window, permutation, the server's shape and budget checks (`v5.md` §4.5, §6.1) |
| **code**: reading its own bytecode and constants | reads layouts, constants and lists from the shards | per-build values (§2): each build's must be read again |
| **mem**: reading and writing Lync's upvalues, stack and GC objects | reads key, count and permutation; calls Lync's internal encoder and tag function | count lockstep (slips are `tagMismatch`/`frameGap`), per-session key and permutation, per-build values |
| **api**: requiring client modules, calling Lync's API | fires definitions through Lync's own encoder | traps and reachability (§3), caller probe (§4), reactions and challenges (§7) |
| **hook**: hooking functions and metamethods | changes values above the encoder; spies on remotes; replaces Lync's own functions | server checks; the tag, for edits below the encoder within `tag.cover`; the self-check of Lync's tables, for replaced entries (§5) |
| **signal**: firing or disabling its own connections | injects inbound frames into its own view | refused and injected frame counts (§5) |
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
  messages, which have no handler) and reports facts. Whatever it would have to guess, name, place or weigh is the
  developer's: trap names (§3), decoy placement and keys (§8), canary text (§9), thresholds that encode a judgement
  (§7). Every game callback Lync runs (decoy behaviours, canary formats) runs as `v5-collections.md` §8.7 states:
  on a pooled thread per call site, a throw or a yield detected at the call, reported natively, and the stated
  fallback applied. It has no quiet mitigation hooks (R22), no suspicion
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
- **One build per connection.** S, the tag constants and the mask are per connection (one tag covers runs of every
  namespace in a frame), so every namespace a client uses must come from one build run (one `buildId`), or every
  one from the runtime path: a `HELLO` whose `buildId` differs from the connection's first accepted `HELLO` is
  `MISMATCH` (`v5.md` §4.6).

### 2.2 Values drawn per build

- **Streams.** A per-build value is drawn from the stream of a label L (UTF-8 text): xorshift32 (`v5.md` §4.5)
  seeded with the low 32 bits of HalfSipHash-2-4 keyed by `rotationSeed` (two u32, low first) over L with 64-bit
  output, 0 replaced by `0x9E3779B9`. v64(L) is that 64-bit output itself. Within a stream one value can give the rest (a stream's
  whole sequence is a function of its 32-bit state); across streams none does. Values are emitted as literals: a literal
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
- **Per place.** A game with several places can build each separately: each run draws its own `rotationSeed`, so
  layouts and tag constants differ between places with no setting, and a teleport opens a new connection whose
  `HELLO` names that place's build. Code generated per client or per server at run time is refused: no engine
  member delivers code to a client `[refusals-rejudged-4 R8]`.
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
    nonzero value differing from m_1 … m_(v−1). Masks are per build run, not per namespace: one upstream frame holds
    runs of several namespaces under one tag (`v5.md` §4.5), so a connection has one mask. The build writes one set
    of N `ModuleScript`s, `ServerStorage.LyncVariants.<v>` for v = 1 … N, each returning its mask as an integer
    literal (line 1 and digest as `v5-tooling.md` §1.1 gives every Lync output); every server shard of the run
    holds the N masks and `VARIANT_OF` (mask to v). `ServerStorage` never replicates.
  - **Assignment**, at `Players.PlayerAdded` and for players present when the server runtime starts, before cloning:
    uniform (server `Random`) among the variants no present player holds; when every variant is held, uniform among
    those the fewest present players hold. It lasts for the connection; a rejoin is assigned again. While N is at
    least the number of concurrent players, no two present players share a variant.
  - **Delivery.** In the assignment thread the server waits for the player's `PlayerGui` (`WaitForChild`), clones
    `LyncVariants.<v>` as a `ModuleScript` named `Value` into a new `ScreenGui` named `Lync` (`ResetOnSpawn` false,
    `Enabled` false, attribute `LyncVariant` true) and parents it to `PlayerGui`, whose children replicate to that
    player only `[generation-security §2.1]` `[interest-rewind §13.1]`. It answers that player's first `HELLO` only
    after parenting, so the client's `variantMissing` clock never starts before the variant exists.
  - **Client.** At first use the shared client shard starts a thread that waits for the first child of `PlayerGui`
    whose attribute `LyncVariant` is true, requires its `Value` and installs the mask; `require` of the shard never
    yields. It binds once per connection and ignores later changes under `PlayerGui`.
  - **Tag** (`v5.md` §4.5). The client's tag is the keyed hash XOR m_v; the server verifies under the assigned
    mask. A frame that fails under it at every candidate, and whose tag XOR the keyed hash at some candidate is
    another variant's mask, is `tagVariant` (§10) in place of `tagMismatch`: dropped, e unchanged, counted toward
    `desync`.
  - **Join.** `HELLO` is untagged and comes from the shared shard, so it never waits for the variant. A namespace's
    join hold (`v5.md` §5.3) releases once its `WELCOME` has arrived and the variant is installed; until then
    reliable sends wait in the hold, and an unreliable send after `WELCOME` but before the variant is dropped as
    `sendDropped` with its own cause (`v5.md` §7.3). Held sends stay encoded bytes: the tag is computed at send and
    layouts don't vary per player. `REPORT` and `BEACON` become pending only once frames can be tagged (§4, §6).
  - **`Lync.variantOf(player)`** (server) returns v, or 0 when there are no variants: the developer's input for
    logging assignments.
  - A variant not installed 10 s after the connection's first `WELCOME` is `variantMissing` (§10); the client keeps
    waiting.
- **What `tagVariant` proves, exactly:** the frame's sender held this session's key and variant u's mask. Masks are
  per build and shared by every server of the build, so every account assigned u on any server of this build has
  been sent u's mask; the player holding u on this server is not thereby the frame's source. What a game concludes,
  and against whom, is the developer's.
- **Prices** **share**: a tag routine, mask or byte tool carried from one account to another fails under the
  receiving player's mask, and each such frame is reported with the variant whose mask it carried. Not priced: a
  tool that reads its own client's variant (**code**, **mem**), **api** and **hook** (`fire` tags with the client's
  own mask), and keyless senders, which meet it only by chance (§10). **Universal counter:** yes, reading the
  `Value` module under `PlayerGui`'s marked `ScreenGui` and tagging with it, the same in every Lync game.
- **Decision: what a variant holds.**
  - *Problem.* A variant can vary the tag alone, or the upstream layouts as well; downstream stays per build either
    way (§2.2). The join hold holds encoded bytes, and a layout that arrives with the variant can't encode a send
    made before it.
  - *Options:* **a mask only**; the mask plus upstream encoders under the variant's own order and offsets, with
    held sends kept as values charged at their worst-case size `[generation-methods M12]` or at the seed-0 plan, and
    `HELLO` sent only after binding and accepted only with the assigned variant `[interest-rewind §13.2]`; masks
    drawn per server at start and delivered as a value.
  - *Choice: a mask only, per build.* A carried artefact already fails under another player's mask and is dropped
    and reported before decode, so any layout it carries is never decoded; a tool that reads its own variant reads
    the layouts in the same module in the same pass. Per-variant layouts therefore add no recurring work beyond the
    mask, while costing N times the upstream codec bytecode in the place and the server shard (about 1.1 MB at 200
    definitions and 16 variants), a value hold and a second join rule, and they don't compose with weaving, whose
    scripts every player shares `[codecs-in-scripts §8]`. Per-server masks would change on every server, so no
    tool would carry one and the mask would be a longer key `[generation-methods M13]`; per build, a mask is
    stable enough to be carried, which is what the measure reports. Verifying under the assigned mask alone keeps a
    client from choosing its variant, the property `[interest-rewind §13.2]` rule 4 asks for. Per-variant tag
    constants or key secrets are not used: naming the other variant would take 5 × (N − 1) full hashes per failing
    frame, 31.4 µs native per 64 B frame at N = 16 `[generation-methods M13]`.
- **Cost.** Place: N modules of one integer. Server: the masks and `VARIANT_OF`, 13,312 B at N = 256; one index
  per player; one XOR per accepted frame (within noise); up to 5 table lookups per failing frame, +0.5 µs
  interpreted and +0.24 µs native at 64 B `[generation-methods M13]`. Client: one XOR per frame; one `ScreenGui`
  and module per player. Join: tagged sends wait max(0, variant arrival − first send); the arrival time after
  `WELCOME` and `PlayerGui`'s presence at `PlayerAdded` are unmeasured (§12). Wire: none.

### 2.5 Options (`lync.toml`)

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `build.seed` | `"release"`, or 16 hex digits | — | `"0000000000000000"` (identity) to `"ffffffffffffffff"` | `"release"` (derived: only a fresh private seed per run makes §2.2's values per build) | below |
| `build.offsets` | boolean | — | — | `true` (derived below) | +5.0 ns encode and +7.3 ns decode per bounded field interpreted, +5.0 and +5.9 ns native; 224 → 356 B per encoder and 223 → 351 B per decoder (+59%); column bits per §2.2; only at a nonzero `rotationSeed` `[generation-methods M3]` |
| `build.playerVariants` | integer | variants | 1–256 | 1 (chosen, below) | §2.4; 1 means no variants |

- **`"release"`**: each `lync build`, each `lync watch` rebuild and the plugin's "Prepare release" draws `buildId`
  uniform on 1–2^32 − 1 and `rotationSeed` uniform on 1–2^64 − 1, independently, from OS entropy, for every
  namespace and both sides of that run. Shards of different runs carry different `buildId`s and get `MISMATCH`.
- **16 hex digits** fix `rotationSeed`; `buildId` is then the low 32 bits of HalfSipHash-2-4 (zero key) over the
  16 hex digits and the canonical text of every `[build]` key, 0 replaced by 1, so any option difference changes
  it; it is 0 for the identity build only (`v5-tooling.md` §1.2). This is for tests and reproducible builds: that
  `buildId` is a 32-bit check value over `rotationSeed`, which still leaves a 2^64 search. Under a fixed seed every
  value of §2.2 is the same in every build with that seed, so "per build" holds per seed change, and a seed in a
  public `lync.toml` is public. The manifest records which entropy source a
  run drew from (`rotation.entropy`, `v5-tooling.md` §1.2, §4.1).
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

One fact, `unreachable`, for a message of a client-sent definition that the developer declared, or opted in as,
fired by no unmodified client code, with evidence `basis` naming what established that: 0 the scan found no
reference, 1 `:trap()`, 2 a closed definition's generic id `[review-redundancy-2 5]` `[codecs-in-scripts §7.1]`.
Three triggers with one meaning, so one reason with one evidence value per trigger (`v5.md` principle 4). A
trapped definition reports `basis` 1, never 0 or 2.

- **Completeness** (generated path). A namespace is incomplete, and nothing is inferred or closed for it, when the
  scan of the client scan set (`v5-tooling.md` §3.3: scripts in replicating containers, the top-level services
  without the reflection tag `NotReplicated`; `Packages/`; every `LocalScript` and every `Script` with
  `RunContext = Client` wherever stored; the scripts under `check.clientRoots`; for roblox-ts, the compiled Luau)
  finds a dynamic access of one of its namespace values, each reported as `dynamicAccess`: (1) an index whose key
  is not one string literal; (2) iteration, as the subject of a generic `for … in` or the argument of `pairs`,
  `ipairs` or `next`; (3) a hand-off the scan cannot follow by name: an argument to a function with no definition in
  the scanned code, an entry of a table constructor without a name, or a store under a computed key. A namespace
  value is the result of `require` or `TS.import` whose static path matches the client shard's full instance path
  suffix, and anything one is assigned to: a local, a field (`self.net = Net` makes every `.net` read a namespace
  value), a module's return value (its requirers' results are namespace values) and the parameter at that position
  of every function of that name in the scanned code. So aliases, field stores, returns and arguments to such
  functions are followed, not escapes `[build-checks §2.2]`. Following is by name, not scope, so it can only add
  namespace values and turn inference off more often. The predicate is computed once per build and read by
  inference, the caller probe's source lists (§4) and weave closure (`v5-tooling.md` §5.4); `check.dynamicAccess`
  sets only the diagnostic's severity `[build-checks §2.7]`.
- **Declared trap** (`basis` 1, both paths). The developer adds an ordinary client-sent event or request to the
  schema, under a name, kind, lane and codec of their choosing, and calls `Net.x:trap()` on its server view. Lync's
  outputs (schema module, client shard, types, manifest, ids, wire) treat it as any definition, by the same emitter
  (`v5-tooling.md` §1.1). A trap has no handler: `connect`, `handle` or `validate` on it, or `:trap()` on a
  definition that has one, throws `trapHandled` at the caller. Its messages are dropped after `limit` (`v5.md` §6.1),
  since there is nothing to deliver to: an ask over the bucket is answered `limited` as any definition's is, and
  every other ask `rejected`, the answer a `validate` refusal gives. So nothing Lync writes or sends tells a trap
  apart before its first message reaches the server; after it, a trap answers `rejected` to every input.
  - **What the game's own scripts show** is the developer's: every name a client script uses as a field is a string
    constant of its bytecode (`GETTABLEKS … ['buyItem']`), so a driver that fires only names found in client
    bytecode skips a trap no client script names. Naming the trap in client code that never runs (a field access or
    string literal) defeats that test.
- **No scanned reference** (`basis` 0, generated path, definitions opted in by `check.reachability`). For each
  complete namespace the build writes the exact list of its client-sent definitions with no `.name`, `:name` or
  `"name"` token in the client scan set, with that set, to the manifest and the report (`v5-tooling.md` §1.2). It
  is exact about the scan set and nothing more: a `ModuleScript` outside it (inside a `Tool` in `ServerStorage` that
  game code clones into a `Backpack`, an asset inserted at run time) can fire such a definition. Only the developer
  knows whether their game has such code, so only definitions they opt in are reported at run time: a message of an
  opted-in listed definition is delivered and reported.
- **Generic ids of closed definitions** (`basis` 2, woven builds with `weave.ids` `"site"` or `"definition"`,
  definitions opted in by `check.reachability`). A closed definition (closure as `v5-tooling.md` §5.4 defines it,
  computed from the sites that passed the weave gate) has every unmodified call from the scan set on a site id
  (§5.5 there), so a message on its generic id is delivered and reported. Closure is exact relative to the scan set
  as the list above is, so it takes the same opt-in.
- **Prices** **api** drivers firing a definition unmodified client code never fires (declared, listed), and drivers
  calling a closed definition through the shard (generic). It doesn't price drivers that fire only what game code
  fires (the caller probe covers those, §4), or **packet** and blind senders (an unknown id is already `malformed`).
  **Universal counter:** yes for declared traps and listed definitions, the bytecode-constant test above, unless
  the game names them in client code; no for generic ids, which need the build's site ids, per build.
- **Cost.** Run time: one flag check and one table index per message. Wire: none; a declared trap is an ordinary
  definition and takes an id like one. Build: the scan at 11.0–12.3 MB/s interpreted and 19.4–20.1 MB/s native,
  `dynamicAccess` included `[build-checks §2.6]`.

| Option (`lync.toml`) | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `check.reachability` | `false`, `true`, or an array of namespace names and definition paths (`"arena"`, `"arena.chat"`) | — | names and paths of the project | `false` (derived: whether code outside the scan set fires a listed definition is the game's knowledge) | the opted-in definitions' lists in the server shard; one flag check and one table index per message; the scan runs whatever the value |
| `check.clientRoots` | array of instance paths | — | — | `[]` | the scripts under each path join the client scan set |

- **Decision: traps generated by the build.**
  - *Problem.* Generated traps would add bait to namespaces with few unreferenced definitions
    `[generation-methods M15a]`. The hard constraint: the shared schema module replicates to every client (`v5.md`
    §3.5), and a generated trap can't be in it, since the schema is the developer's source.
  - *Options:* traps in the shards only, named by the build from the namespace's own name tokens; the same with
    names the developer lists in `lync.toml`; **none generated: a trap is a definition the developer declares.**
  - *Choice: none generated.* Choosing a trap's name, codec and number is a judgement of what passes for a real
    definition, which is the developer's (the brief's rule); and with the schema module on the client, the
    difference between its keys and the client shard's names is exactly a generated set, in every build
    `[review v5-3.6-tooling B4]`. A declared trap is in the schema, so that difference finds nothing; R13 stays
    refused for the generated form.
- Execution coverage (`ScriptContext:EnableCoverage`) in play tests is not a second reachability check: in a play
  test the server's `unreachable` already reports each message of an opted-in listed definition
  (`v5-tooling.md` §4.2).
- A Studio-only line naming a fired trap (R40) is not added: the console line for `unreachable` (`v5.md` §7.4)
  carries the fact's `definition` (§10) in its context at the first occurrence in each window, in Studio and live.

## 4. Caller probe and `REPORT`

- **Probe.** Each client `fire` or `invoke` is probed with probability 1/`callerProbe.oneIn` (one draw per call),
  at most `callerProbe.maxPerSecond` probes a second (a bucket of that rate and capacity, `v5.md` §5.4's rule). A
  probe makes two reads:
  - **identity:** in `pcall`, one member that fails at identity 2 (game scripts) and succeeds at 8 (executor
    threads by default) `[client-security §1.2, §2.1]`, drawn per build (stream `probe`, §2.2) from a list Studio
    confirms. Candidates: the 21 `RobloxScriptSecurity` property reads on services every client has, such as
    `RunService.ClientGitHash`; a `RobloxScriptSecurity` member also keeps the Studio command bar out if the
    command bar runs below that level `[security-tooling §2]`. A success adds 1 to `identitySucceeded`.
  - **source** (generated path; skipped for definitions with no listed scripts and in incomplete namespaces, §3):
    `debug.info` walked by source, never by level (inlining differs between Studio's `-O1` and live `-O2`), from
    level 1 to the first frame whose source is not Lync's, skipping `[C]` frames (which also skips `pcall` and
    `newcclosure` frames) `[client-self-checks Impl10]`. That source is looked up in the build's list of client
    scripts that reference the definition, after mapping Roblox's clones of starter containers
    (`StarterPlayerScripts` to `PlayerScripts`, `StarterCharacterScripts` to the character, `StarterGui` to
    `PlayerGui`, `StarterPack` to `Backpack`; the player's name read once from `Players.LocalPlayer.Name`). A
    source not on the list fails the check; a stack with no frame outside Lync fails it under
    `callerProbe.noOuterFrame = "unlisted"` and is not checked under `"ignored"`. `check.reachability = false`
    removes the lists, and with them the source check. Lync never calls `getfenv` to reach a caller: it
    deoptimises the caller's environment, 3.5–4× on an encoder step `[security-tooling §2]`.
- **The caller bit** `[client-self-checks U7 (b)]`. A frame holding the message of any probed call whose source
  check failed carries `caller` = 1 in its header, repeated in the tag input's lane byte, so it is covered at every
  `tag.cover` and the server hashes each candidate once (`v5.md` §4.1, §4.5, which decides where the bit
  travels). An accepted frame with `caller` 1 is delivered and records `reportedSourceUnlisted` (§10), client-stated.
  The bit replaces draft 3.5's `sourceUnlisted` count: it names the frame, and the definition when the frame holds
  one.
- **`REPORT`** (control type 5, up; field layout `v5.md` §4.6): `probes`, `identitySucceeded`, `refusedFrames`,
  `injectedFrames` (§5), `selfCheckFailures`, `selfCheckItem`, `selfCheckKind` (§5), EG0 each, counts since the
  previous `REPORT` (`selfCheckItem` and `selfCheckKind` describe the first failure, 0 when none). After the
  connection's first `WELCOME`, a `REPORT` with a non-zero `identitySucceeded`, `refusedFrames`, `injectedFrames` or
  `selfCheckFailures` is pending reliable data (`v5.md` §5.1): the next flush sends it, in the reliable frame with
  other data, alone otherwise; `probes` alone makes nothing pending; at most one per frame; it never counts toward
  `missedFlush` and never enters the join hold `[refusals-rejudged-2 R26]`. The server reports one fact per
  non-zero count, each client-stated (§10): `reportedIdentity`, `reportedRefusedFrames`, `reportedInjectedFrames`,
  `reportedSelfCheck`.
- **Prices** **identity**: API drivers left at identity 8; with every call probed (the default) the first call
  reports, at `oneIn` = n with probability 1 − (1 − 1/n)^calls. **naming**: drivers whose chunk is not on the
  definition's list. Not priced: a patched Lync, which zeroes the counts and the bit (§1); a thread lowered to
  identity 2 (`setthreadidentity`); a chunk named as a listed script, or frames hidden from the walk; calls through
  a listed game function, whose script is the first frame outside Lync `[client-self-checks U7]`.
- **The identity result stays a count.** A second header bit would add per-frame evidence for a count `REPORT`
  delivers within one flush, and `REPORT` exists anyway for the counts that have no upstream frame of their own
  (§5) (`v5.md` §4.5). A tag keyed by each caller's source and checked against a server-only list is refused: its
  server cost is the product of list sizes per frame, without bound `[client-self-checks U7 (a)]`.
- **Cost.** Client: one draw per call, 25–33 ns; per probe, a failing `pcall` of 2.4–2.8 µs when the failure is
  Lua-raised and 3.9–4.5 µs when C-raised (the unwind is the cost, not the error string, so only `oneIn` scales it),
  plus the walk and lookup, 0.19 µs through one Lync frame and 0.6 µs through five; at 60 probes a second
  0.15–0.19 ms/s or 0.24–0.25 ms/s interpreted on the CLI; which of the two Roblox's capability error matches is
  unmeasured `[security-costs claim 7]` `[client-self-checks U7]`. Wire: the caller bit, 0 or 1 B per upstream
  frame (`v5.md` §4.1). `REPORT`: a forced frame is 8–12 B with the tag; at most 60 forced frames a second, only
  while a count changes every flush, about 0.14 ms/s of client CPU interpreted at that bound
  `[refusals-rejudged-2 R26]` (`v5.md` §4.6).

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `callerProbe.oneIn` | integer | calls per probe | 0 (off) or 1–255 | 1 (below) | one draw per call; u8 in `WELCOME` |
| `callerProbe.maxPerSecond` | integer | probes/s | 1–63 | 60 (below) | ≤ 4.5 µs per probe; ≤ 0.25 ms/s at 60; u6 in `WELCOME` |
| `callerProbe.noOuterFrame` | `"unlisted"` \| `"ignored"` | — | — | `"unlisted"` (below) | none; `"ignored"`: a call with no frame outside Lync sets no bit and is counted nowhere; 1 bit in `WELCOME` |

- **Defaults.** `oneIn` 1: every call probed, so an identity-8 driver's first call reports; Studio showing that a
  caught capability failure writes a client log line would move it back to sampling (§12). `maxPerSecond` 60: one
  probe per automatic flush at the client's 60 flushes a second (`v5.md` §4.9). `noOuterFrame` `"unlisted"`: a
  call started with no game frame on its thread (`task.spawn(view.fire, view, v)`, `coroutine.wrap`) is also how
  executor code can reach `fire`, so ignoring it by default would leave that route unobserved in every game; game
  code removes the cause by calling `fire` from a function of its own `[client-self-checks U7]`.
- `callerProbe.splitFrames` (the unlisted calls' messages in a frame of their own) is not adopted: it breaks
  `v5.md` §4.1's one reliable frame per player per flush, on which the reliable frame budget's default and the
  bound on forced `REPORT`s rest, and an unmodified client with a library-callback cause would send up to 120
  reliable frames a second, the whole default budget.
- **Unverified, checked in Studio before release (§12):** a suitable member and its cost on devices; whether a
  caught capability failure writes a client log line; whether unmodified sources follow the clone mapping (if not,
  the source check is removed); the command bar's identity and source string; whether a script renamed or moved
  after loading keeps its source string; whether `task.spawn` and signal routes leave no outer frame on Roblox.

## 5. Inbound frames and self-check

Three client counts that `REPORT` (§4) carries within one flush, each client-stated.

- **Refused frames.** The client decoder is as strict as the server's (`v5.md` §4.8). Each downstream frame it
  refuses is counted (`refusedFrames`, `v5.md` §7.4). It prices **signal** injectors of non-canonical frames into
  the client's own view (`getconnections`, `firesignal`) `[security-tooling §9]`, who must build canonical frames
  for this build and server or patch Lync. Cost: none beyond decode.
- **Injected frames** `[refusals-rejudged-3 R1 (d)]`. The function Lync passes to `Reliable.OnClientEvent:Connect`
  and `Unreliable.OnClientEvent:Connect` reads `debug.info(2, "f")` as its first statement, in that function itself
  and never in a helper, which `-O2` could inline. The engine resumes the listener as the first function of its
  thread, so nothing is below it; a synchronous call from other code leaves a function below it. A frame so entered
  is decoded and delivered as usual and counted in `injectedFrames`. It prices **signal** injection of canonical
  frames (replayed captures, frames built with Lync's own encoder) fired synchronously into the listener. It
  doesn't see injection fired from a thread of its own (a deferred fire starts like an engine delivery), **packet**
  receive injection, which the engine delivers normally (non-canonical frames still reach `refusedFrames`), or a
  client that patches Lync. Cost: 30.0–38.2 ns per frame interpreted, at most 3.1 µs/s at the busy model's 80
  downstream frames a second. No option: the cost leaves no game a trade to make (`v5.md` principle 2).
  - **Unverified, gating (§12):** that `debug.info(2, "f")` is nil inside the listener for every engine delivery,
    under both `Workspace.SignalBehavior` values, including events queued before the listener connected (the
    engine "queues it and delivers it, in order, as soon as a handler connects"). The design assumes it holds; if
    any case finds a function below, the check is removed.
- **Self-check of Lync's own tables** `[refusals-rejudged-4 R18]`.
  - **Frozen API tables.** Lync freezes every table it hands to game code that holds a Lync closure: each namespace
    table, view, field handle and method table reached through a metatable. Game code that writes a field into one
    raises "attempt to modify a readonly table" at the write.
  - **Items.** The client shard holds one list of (table, key, closure, expected line) for every entry of those
    tables that holds a Lync closure; `manifest.json` names each item by its 1-based index. On the runtime path the
    modules build the same list at load, reading lines with `debug.info(f, "l")` in their own module before
    `require` returns. An item's expected source is `debug.info(1, "s")` read by the module defining the closure.
  - **Check, in this order, stopping at the first failure:** kind 3, `rawequal(rawget(t, k), f)` is false; kind 4,
    `table.isfrozen(t)` is false; kind 1, `debug.info(f, "s")` differs from the expected source; kind 2,
    `debug.info(f, "l")` differs from the expected line. Function values only, never stack levels.
  - **Schedule.** One pass over the list per second, spread over flushes: each flush checks the next
    ⌈|list| × Δt⌉ items, Δt the time since the previous flush's check, capped at |list| (a runtime constant,
    chosen: a hook that persists is found within 1 s; no schedule finds one removed between passes).
  - **Report.** `selfCheckFailures` (failing items), `selfCheckItem` and `selfCheckKind` (the first failure) in
    `REPORT`; a persistent failure forces at most one `REPORT` a second. The build runs the emitted check against
    the emitted shard before writing it; an item failing there is a build error, a Lync emission bug.
  - **What it states, exactly.** Kind 3 (an entry replaced) and kind 4 (a table unfrozen) have no cause on an
    unmodified client: freezing is irreversible, and writes to a frozen table raise, `rawset` included, for game
    code, plugins and the command bar alike (verified in the VM). `rawequal` and `rawget` are fast calls, so an
    in-place hook of them can't change what kind 3 sees while Lync's environment is safe. Kinds 1 and 2 (source or
    line differs) catch an in-place hook of Lync's closures only if the executor's hook changes what `debug.info`
    reports for the original reference, which is unverified.
  - **What it doesn't price.** `table.isfrozen` and `debug.info` are ordinary calls: one spoof of the two that
    returns the originals' values passes kinds 1, 2 and 4 in every Lync game and every build, since generation
    varies which items and lines are checked, never the functions the check calls; kind 3 falls too once the
    environment-safety capability turns fast calls back into hookable ones. Also **mem** (the counts zeroed before
    `REPORT`), **naming** (`debug.setinfo` makes a hook report any source and line), hooks that leave Lync's
    functions alone (engine functions, **packet**, values changed above the API), and hooks installed and removed
    between two passes. Checks of engine functions and the environment stay refused: they inspect functions
    generation can't change, which `newcclosure` makes look unchanged, and one bypass covers every Lync game.
  - **Cost.** Per item, interpreted: kind 3 alone 31.7–33.8 ns, kinds 3–4 48.7–51.4 ns, kinds 1–2 77.1–84.9 ns; a
    pass over 202 items 21.9–24.7 µs, so 22–25 µs of client CPU a second for 200 views. While an item fails, up to
    one forced `REPORT` a second, 3 B of fields beyond the others. Shard: four values per item. No option: the
    cost scales with the list, not with traffic.
- Downstream tags and a client replay window stay refused: a per-recipient tag ends `FireAllClients`, a shared key
  is held by every client that could inject, and a frame number would change the seed-0 golden frames to catch
  replays only `[refusals-rejudged-3 R1]`.

## 6. Clock beacon

- **Client.** After the connection's first `WELCOME`, a `BEACON` (control type 6, up: ⌊`GetServerTimeNow()` ×
  1000⌋ mod 2^16 as u16, read when the frame is encoded) is due once `clock.beacon` tenths of a second of
  `os.clock()` have passed since the last frame carrying one was passed to `FireServer` (for the first, since the
  first `WELCOME`). A due `BEACON` is pending reliable data (`v5.md` §5.1): the next flush puts it in its reliable
  frame, with other data or alone. It never counts toward `missedFlush` and never enters the join hold; under
  `Lync.scheduler("manual")` it waits for the game's next `Lync.flush()`. With a pending `REPORT` it shares the
  frame `[clock-facts, BEACON gap]`. Without forcing, a client sending fewer than 3 reliable messages a second got
  a fit in 0–0.6% of epochs, so input-only and idle clients were never measured.
- **Server estimator, per player** `[clock-facts §U3.2]` (constants: `v5.md` §4.9):
  1. **Arrival** is server `os.clock()` at the decode of the frame holding the `BEACON`. `os.clock` is not adjusted
     by NTP, so a server clock adjustment can't enter every player's estimate at once.
  2. **Stamps** are extended: the first of a connection, and the first after a restart, to the value nearest
     ⌊1000 × the server's `GetServerTimeNow()`⌋; each later one to the value within ±32,768 ms of the previous
     extended stamp. Each beacon gives o = arrival − stamp (s).
  3. **Windows** on one server grid: index ⌊t / 5⌋, t the arrival; each window keeps its minimum o. At each epoch
     boundary (t a multiple of 5 s), a player with 12 consecutive windows ending there gets a fit: the Theil–Sen
     slope of the 12 minima (median of the 66 pairwise slopes).
  4. **Sign:** s = −(that slope), in seconds of client-clock gain per second of server `os.clock()`; positive is a
     fast client clock, negative a slow one.
  5. **Split halves:** for a fit with |s| > `clock.reportSlope`, windows 1–6 and 7–12 are fitted too (15 pairs
     each, the 8th order statistic), giving `firstHalf` and `secondHalf`. The fit **counts** when s, `firstHalf`
     and `secondHalf` all exceed `clock.reportSlope` in magnitude with s's sign. One level shift lies inside one
     half, so the other is flat; a rate, from a modified clock or a delay ramp, shows in both.
  6. **Run:** consecutive counting fits of one sign; a non-counting fit, a sign change or a restart ends it.
     `clockRate` (§10) fires at the end of each fit that makes the run at least `clock.reportFits` long.
  - The first 30 s after join are ignored, and an arrival gap over 3 × `clock.beacon` restarts the estimate.
  - **Together, as evidence:** `othersSlope`, the median of s over the other players whose fit completed at the
    same epoch, and `others`, their count (`othersSlope` is 0 when `others` is 0). The counters `clockFits`,
    `clockRestarts` and `clockSlope` per player and `clockSlopeMedian` and `clockSlopeFits` per server are in
    `v5.md` §7.4.
- **Decision: server-wide corrections in the trigger.**
  - *Problem.* A cause common to every player (a server-side inbound queue building or draining) moves every slope
    at once; correcting for it needs a server-wide rule, and any such rule also sees a majority of players running
    the same clock tool.
  - *Options:* the research's literal rule (discard a window when more than half moved the same way); *discard*
    (freeze runs at an epoch where more than half of 3 or more fits exceed the threshold one way); *guard* (test s
    against the epoch median M); **no correction, with "together" as evidence.**
  - *Choice: no correction.* The literal rule drops 71.5–91.5% of windows with no common cause; discard and guard
    both remove a simulated server-wide drain but hide any majority (55 of 100 players at +5% gave 0 of 275
    modified players a fact), and the fact would stop being a statement about one player's data. Cost is not the
    reason: the guard costs 3.0–3.5 ns per fit `[clock-facts §U3.3]`. `othersSlope` lets the game tell the two.
- **Defaults, derived from simulation** `[clock-facts §U3.1, §U3.5]`. The largest |s| simulated for an unmodified
  client is 0.00691 (a sustained 0.6% slew, the documented bound, on the mobile model), so `reportSlope` 0.01
  leaves a margin of 1.45; at `reportSlope` ≤ 0.0069 that slew is a known cause. With the split halves,
  `reportFits` 3 gives 0 of 300 simulated players a fact for any single delay step, where a 0.5 s step fired for
  188 of 300 without them; a +1% clock is found for 30 of 30 (first fact p50 170 s). Device noise, slew and delay
  ramps are unmeasured (§12); measuring them would change both defaults.
- **Prices** **clock**: tools that accelerate or slow the client clock while Lync's stamps follow it. Not priced:
  stamps kept on unmodified time, or patched; a client that blocks Lync's frames, which leaves a count gap
  (`frameGap` on the next reliable frame) and, blocking every beacon, no fit (`clockRestarts` counts the gaps).
- **Cost** `[clock-facts §U3.6, BEACON gap]` `[security-costs claim 9]`. Wire: a forced `BEACON`-only frame is 9 B
  with the tag, 11 B with a `REPORT` (`v5.md` §4.6); riding another frame, 20 bits of chunk plus 2–4 bits of toc;
  ≤ 9 B/s and one `FireServer` a second per idle client at the default (≤ 18 B/s at 5). Client: ≤ 1.8 µs per
  forced frame interpreted. Server, native: 8.8 ns per beacon, 1.52–1.59 µs per fit, 0.56–0.60 µs for the halves
  (only beyond the threshold), 1.72–2.10 µs per epoch to sort 100 slopes, ≤ 0.12 µs per fact: ≤ 71 µs/s at 100
  players (0.007% of a core), plus ≤ 16 µs/s for 100 idle players' forced frames. Memory: one number per player
  (the first window's o, for `drift`) and one reused array of slopes per server.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `clock.beacon` | integer | tenths of a second | 0 (off) or 5–15 | 10 | ≤ 9 B and one reliable `FireServer` per beacon on a client with no other reliable data; u4 in `WELCOME` |
| `clock.reportSlope` | number (real) | s/s (seconds of drift per second) | 0.001–1 | 0.01 (derived above) | none; server-only |
| `clock.reportFits` | integer | consecutive counting fits | 1–12 | 3 (derived above) | none; server-only |

## 7. Timing facts

Three server measures time a client's answer against when it could have seen what it answers: early answers to
server asks (§7.2), reactions to declared stimuli (§7.3) and challenges (§7.4). They share one clock, one origin and
one bound, so a fact's evidence equals the timing fields of the server's request result (`v5.md` §3.5) for the
same answer `[clock-facts §U4.1]` `[server-facts §U10.4]`.

### 7.1 Clock, origin and bound

- **Clock:** server `os.clock()` for every time below; it is not moved by system clock adjustments.
- **t_s** is the flush that passed the frame holding the outgoing message to the engine (for a held send, the flush
  that released it). **t_r** is the decode of the frame holding the incoming message.
- **Bound b** per player, at t_r: the minimum over the last 10 s of the player's `Player:GetNetworkPing()` samples,
  one taken at each t_s of an ask, a stimulus or a challenge and at each t_r of an answer or challenge attempt,
  and of Lync's own ack round trips where state frames flow (`v5-collections.md`). Engine ping excludes
  deserialization and processing, so it sits below the full path; the ack round trip is not smoothed and follows
  a latency drop within one state frame. Kept as 10 one-second minima, 40 B per player.
- **Factor default, derived.** An option `factor` compares elapsed time with factor × b. On `v5.md` §9's default
  network an unmodified automatic answer's `roundTrip` / ping is 0.97 at p1; after a one-way latency drop from
  0.10 s to 0.03 s, `roundTrip` over a ping-only minimum falls to 0.52–0.59 within 0.5 s (smoothing time constant
  assumed), and with ack round trips in the bound it stays at 1.64 `[clock-facts §U4.3]`. So 0.5 sits under every
  simulated unmodified case; the smoothing measurement (§12) would change it.

### 7.2 Early answers

- **Mechanism.** For each server `invoke`, Lync keeps t_s and the ping sample in the request slot. An answer whose
  `roundTrip` = t_r − t_s is below `earlyAnswer.factor` × b is delivered and reported as `earlyAnswer` (§10) with
  `challenge` 0; `roundTrip` and `minPing` are the result's fields for that answer.
- **Prices** answers sent before the ask could arrive: a bot predicting a timed prompt gains up to one round trip
  (**clock**, **api**).
- **Cost.** 6.3–7.2 ns native per ask to record t_s and the sample; the bound's minimum, 44–56 ns native per answer
  (cacheable per second); one `GetNetworkPing` per ask and per answer (engine cost unmeasured, §12). No bytes.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `earlyAnswer.factor` | number (real) | fraction of b | 0 (off) to 1 | 0.5 (§7.1) | as above; server-only |

### 7.3 Reactions (`reactsTo`)

- **Declaration** (server view, invisible to the client, not hashed) `[server-facts §U10]`:
  `Net.<response>:field(keyPath):reactsTo(stimulus, { floor, factor, track })` (field handles, `v5.md` §3.4). The
  response is a client-sent event or request, and `keyPath` the response field that pairs it with its stimulus.
  `stimulus` is a collection view (`Net.coins`: the stimulus is a record's add to this viewer, paired by record
  key) or a field handle of a server-sent event on either lane (`Net.prompt:field("id")`: paired by equal values).
  A second call on one response replaces the first. Examples:
  `Net.collect:field("coin"):reactsTo(Net.coins, { floor = 0.12 })`,
  `Net.answer:field("id"):reactsTo(Net.prompt:field("id"), { floor = 0.15 })`.
  - Errors at the caller (the generated path makes most of them type errors): a stimulus that is neither a
    collection view nor a server-sent event's field handle (a server request is `earlyAnswer`'s), `stimulusKind`;
    key fields whose codecs differ, `fieldCodec`; an option out of range, `valueRefused`; an unknown option key,
    `unknownOption`.
- **Candidates.** Events: the stimuli with the response's key value among the last `track` sent to the player.
  Collections: the record's first add to this viewer in its current incarnation. Of several candidates Lync takes
  the **oldest**, which gives the longest elapsed time, so a pairing error can only miss a fact. A key with no
  candidate (an event outside the ring, a record no longer live) counts `reactionsUnmatched` (`v5.md` §7.4) and
  raises no fact.
- **Receipt.** Each upstream reliable frame's header carries `rcv`, the client's count of downstream reliable
  frames received mod 256, extended by the server against its own count (`v5.md` §4.1). It is client-stated: a
  modified runtime that overstates it leaves only the time rule. A client 256 or more frames behind reads as having
  received early, which can only miss a fact.
- **Triggers** (with t_s the candidate's, t_r the response's, b §7.1):
  1. **case 3, never sent** (collections): the key names a live record whose current incarnation was never added
     to this viewer;
  2. **case 1, before stimulus:** exactly, when the response came in a reliable frame, every candidate is a
     reliable stimulus and every candidate's frame number exceeds the extended receipt; otherwise by time, when
     t_r − t_s of the oldest candidate < `factor` × b;
  3. **case 2, below the floor:** `floor` > 0 and (t_r − t_s) − b < `floor`, measured to the oldest candidate the
     receipt shows received (the oldest candidate, without a receipt).
  Each is the fact `earlyReaction` (§10). The message is always delivered: Lync drops nothing for a timing fact
  `[server-facts §U10.5]`.
- **Pipeline:** `v5.md` §6.1 step 5's report-only checks, after `limit`. Stimuli are recorded in the flush that
  builds each player's frame.
- **Prices** **api** and **clock**: a client acting on data Lync hadn't delivered (a bot pre-firing a timed prompt,
  data from another path, a blind auto-collector firing on every key), and, with a floor, responses faster than the
  game accepts from a person. Not priced: a client that waits for the stimulus and answers at a human-looking delay
  (it prices speed, not automation); a modified runtime overstating the receipt, which the time rule still bounds.
- **Simulated** on `v5.md` §9's default network `[server-facts §U10.6]`: with b at or below the true path the
  estimate never falls below the true reaction; at b 0.02 s above it, 1.35% of 0.10 s reactions read under a 0.10 s
  floor, hence the docs' rule: floor ≤ the fastest reaction the game accepts, minus 0.02 s. Responses fired at the
  moment the stimulus left: case 1 by receipt 100%, by time 0%; floor 0.10 s 99.2%.
- **Cost** (native; interpreted in `[server-facts §U10.7]`): a stimulus ring push 8.6–10.2 ns per recipient; a
  response to an event 34.7–38.1 ns at `track` 8, to a collection add 8.2–8.3 ns; a ping sample 7.9–8.1 ns per
  stimulus sent; the bound 45.4–46.0 ns per response. Memory: 24 B × `track` per (player, declaration); 4 B per
  (viewer, slot) per watched collection (400 KB at 100 viewers and 1024 slots); per player a ring of the last 256
  reliable frames' send times (2 KB). Wire: the receipt, 1 B per upstream reliable frame, ≤ 120 B/s at the default
  frame budget.

| Option (`reactsTo`) | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `stimulus` (argument) | collection view, or field handle of a server-sent event | — | its codec equal to the key field's | required | collections: 4 B per (viewer, slot) |
| `floor` | number (real) | s | 0 (off) or 0.01–2 | 0 (derived: the floor is the game's; none is a default human floor) | none beyond the response test |
| `factor` | number (real) | fraction of b | 0 (off) to 1 | 0.5 (§7.1) | none |
| `track` | integer | event stimuli remembered per player | 1–64 | 8 (chosen: a response more than 8 stimuli of its definition behind counts `reactionsUnmatched`, never a fact) | 24 B per entry per player; the scan is linear in it |

- The key field is required: paired with "the newest stimulus" instead, a slow answer to frequent stimuli pairs
  with the wrong one, and the floor fires on an unmodified client. The frame-time ring is 256 because the
  receipt's range is 256 frames.

### 7.4 Challenges

- **What Lync carries, and what the game designs** `[decoy-challenge-facts §5]`. Lync draws an unpredictable token,
  matches every value arriving on declared answer fields against the player's open challenge, and keeps the
  deadline, extension, cancellation and attempts; the game chooses which of its own messages carries the token down
  and the answer up, what the player sees or hears, and what an outcome means. Nothing marks a challenge in the
  shared schema, on the wire or in Lync's client: a challenge shape in Lync's client would be the same in every
  Lync game, and one hook on it would answer them all.
- **API** (server):
  - `Net.d:field(path):answers()` on the server view of a client-sent event or request: `path` names a top-level
    `t.int(min, max)` or `t.optional` of one (another codec: `fieldCodec`; on the generated path a type error). Several
    definitions may declare one. A message's answer is read in `v5.md` §6.1 step 5's report-only checks, after
    `unresolved` and `limit`, before validators; a nil field answers nothing.
  - `Lync.challenge(player, { within, values, attempts })` returns a handle. `token` = `Random:NextInteger(0,
    values − 1)` from a server `Random` created with no seed (seeded from an internal entropy source, documented).
    One open challenge per player: a second call throws `challengeOpen`. `values` must fit some declared answers
    field (0 and values − 1 within its range), else `valueRefused`; an unknown option key throws `unknownOption`,
    which neither Luau solver catches as a type error.
  - The handle: `token`; `deadline`, the `GetServerTimeNow()` value at which it closes, for display; `wait()`,
    which yields until close and returns the frozen outcome (at once, the same value, after close);
    `extend(seconds)`, which moves the deadline later while open (seconds 1–3600, `within` plus extensions at most
    3600 s, else `valueRefused`; nothing on a closed challenge); `cancel()`. A leaving player closes it as `left`;
    `BindToClose` closes every open one as `shutdown`.
- **Timing.** t_s is the first flush after the `Lync.challenge` call: the token can leave no sooner, so elapsed
  times can only be long. The deadline is t_s + `within` (plus extensions) in `os.clock()`, swept once per flush.
- **Outcome** (a result value, not a fact: the issuer waits for it, as for an `invoke`, and a fact would print a
  console line per answered challenge and have to be matched back to its call):

| Field | Type | Meaning |
|---|---|---|
| `outcome` | `"answered" \| "mismatched" \| "timeout" \| "cancelled" \| "left" \| "shutdown"` | `answered`: a value equal to `token` arrived on an answers field from that player while open; `mismatched`: `attempts` values arrived and none was equal; `timeout`: the deadline passed first; the rest as above |
| `after` | number (s), or nil | answered or mismatched: t_r of the closing value's frame − t_s |
| `firstAfter` | number (s), or nil | the same for the first value received; nil if none |
| `attempts` | integer | values received while open, the closing one included |
| `minPing` | number (s) | b (§7.1) at close |
| `definition` | string, or nil | the answers definition that carried the closing value |

- A value closing a challenge as `answered` with `after` < `earlyAnswer.factor` × b is also `earlyAnswer` with
  `challenge` 1. A non-nil answer from a player with no open challenge is `unsolicitedAnswer` (§10). A value from
  another player is that player's attempt at their own challenge; tokens of 10^4 values coincide between players by
  chance, so equality across players proves nothing and has no fact.
- **Prices** automation that doesn't produce the game's response: idle-timer defeaters, **api** farm bots firing
  gameplay definitions without per-game prompt handling, and blind guessing, which closes a challenge as `answered`
  with probability at most `attempts`/`values` (3/10^4 at the docs' values). Deadlines and `after` are server time,
  so **clock** changes nothing. Not priced: a bot that reads the token (from Lync's decoded payload, the UI or a
  collection: **state**, **mem**) and answers through the game's action, which is byte-identical to a person's
  answer except for its timing; programs that read the screen (OCR, trained solvers); human farms.
- **Known causes on an unmodified client** `[decoy-challenge-facts §7]`. `timeout`: the player is away; slower than
  `within` (people with physical disabilities often need more time, WCAG 2.2 SC 2.2.1); a prompt a gamepad or
  touch screen can't answer; a visual-only prompt for a player who can't see it (no scriptable screen-reader API
  exists); reduced-motion and text-size settings; the prompt covered (the Roblox menu, a modal, a loading screen,
  the app in the background); a reliable-lane stall longer than the time left, or a challenge issued before
  `WELCOME`, waiting in the join hold. `mismatched`: typos and misclicks, controller drift, a misread code, an
  answers field that also carries values in ordinary play. `answered` close to `minPing`: game code that fills the
  answer itself, a confirm key still held from the previous action. The docs page "Challenges" gives the recipe:
  `within` from a saved per-player setting over at least a 10× range, a warning 20 s before the deadline with
  `extend` on any simple action, `attempts` at least 3 for typed codes, selectable answer buttons, a visual and a
  sound form, a still form under `ReducedMotionEnabled`, and the statement that one `timeout` tells none of these
  apart from a program.
- **Cost** (server native, `[decoy-challenge-facts §8.2]`): the token draw 27–28 ns (with `math.random` standing in
  for `Random`); the answers check 2.4–2.5 ns per message when the field is nil, 14.3–14.6 ns with a value and no
  open challenge, 23.6–30.5 ns with one open; the deadline sweep about 6 ns per open challenge per flush; one
  `GetNetworkPing` at issue, per attempt and at close. Memory: one record per open challenge and three numbers per
  player for `unsolicitedAnswer`. Wire: only the game's own fields (`t.optional(t.int(0, 9999))` is 1 bit on every
  message of the carrying definition, 15 bits when set).

| Option (`Lync.challenge`) | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `within` | number (real) | s | 1–3600 | required | one open record held up to `within` plus extensions |
| `values` | integer | token values | 2–2^32 | required (it must match how the game shows the token) | none; must fit a declared answers field |
| `attempts` | integer | values received | 1–255 | required (it depends on the answer's form; the docs give at least 3 for typed codes) | none; the blind-guess bound rises in proportion |

## 8. Decoys

- **Mechanism.** `Net.fighters:decoys(behaviour, { maxPerViewer = n })` on the server view of a collection. Each
  state tick Lync calls `behaviour(viewer, tick)` for each viewer, in a pooled thread; it returns
  `{ [Key]: Record }` or nil. Lync diffs the result against the viewer's previous decoys and sends adds, updates and
  removes. Where decoys go and what they hold is the behaviour's, so the developer's: only the game knows where its
  own rendering and logic never look `[generation-methods M15b]`. Lync checks every returned record as `set` checks
  one, and each failure below throws in the behaviour's thread and leaves that decoy unsent:
  - a record a codec refuses, `valueRefused`;
  - a key equal to a live record's key, or one that becomes a real key while the decoy lives, `decoyKeyLive`;
  - under `interest` (`v5-collections.md`), a decoy whose filed cell is outside the viewer's block and hysteresis
    ring, or whose PVS bit for (viewer cell, decoy cell) is 0, `decoyOutsideInterest`: a real record there is never
    sent, so a decoy there would be the only record of its kind outside the viewer's region
    `[interest-rewind §6.1]`.
- **Values from a live record.** `Net.c:decoyFrom(sourceKey, overrides)` returns a new record: a copy of the live
  record `sourceKey` with the fields of `overrides` replaced, so every value is one the game itself produced; nil
  when `sourceKey` has no live record, which leaves that key out of the behaviour's result. An `overrides` field the
  record lacks throws `unknownField`. Cost: 81–85 ns native per decoy of 6 fields (118–138 ns interpreted). It
  supplies values only; the decoy's own placement still passes the interest test above.
- **Slots: one allocator** `[refusals-rejudged-4 R16]`. A decoy add takes its slot as a real `set` does: uniform
  among free slots (server `Random`), held from its add until 2 s after its remove (`v5-collections.md` §2). Each
  viewer's decoys hold their own slots. Decoys hold at most `Players.MaxPlayers` × `maxPerViewer` slots per
  collection, so `maxRecords` must cover live records, those removed in the last 2 s, and that product. A decoy add
  that finds no free slot is not made that tick and counts `decoysUnplaced` (`v5.md` §7.4); the next result retries
  it. A real `set` that finds none throws `recordLimit`, whose causes gain decoys holding slots under a `maxRecords`
  that doesn't cover the product. Every add carries its slot's generation (`gen:u2`, `v5-collections.md` §3),
  which shared slots need: viewers sent different adds in one slot would otherwise count its generations
  differently. One viewer's statistic over slot reuse (an add's time since that slot's last remove) separates its
  decoys at 0.506–0.507 balanced accuracy under one allocator, against 0.65–1.00 under draft 3.5's shared pool and
  1.00 under a separate slot range, which stays refused as an exact mark.
- **No placement tell in the encoding.** A viewer's copy of a changed shared chunk (under `interest`, of a changed
  cell chunk) is re-encoded with its decoys' rows only in a flush where its decoys have adds or updates in that
  chunk; otherwise it gets the shared chunk as other viewers do, and stays in `FireAllClients` for that flush if
  nothing else in its frame is per viewer. A decoy's remove goes into the viewer's copy of the remove chunk. The
  re-encode uses the full mode and k search: the reference encoder is deterministic and minimal, so a copied chunk
  is the minimal encoding of the real rows and a re-encoded one of real and decoy rows, and a client re-costing
  columns finds both minimal. Reusing the shared chunk's k (1.8–2.0× faster native) is refused: it leaves
  non-minimal encodings (+0–17% bytes), which mark a chunk as holding rows other viewers didn't get
  `[security-costs claim 6]`. A decoy's `:newest()` rows are per-viewer rows like any other. A decoys-only-in-
  `:newest()` mode is not offered: a behaviour that moves only `:newest()` fields already pays one re-encode per
  add.
- **History.** Per viewer and collection, each decoy's (slot, add tick, remove tick, add time, remove time), kept
  while it lives and for r after its remove: r = 2 s, or max(2 s, `maxRewind` + 0.25 s) when the collection has
  `rewind` (`v5-collections.md`) (a runtime constant, `v5.md` §4.9). `decoyReferenced` and `decoyInteraction` match
  against it `[decoy-challenge-facts §1, §2]`.
- **References.** `Net.d:field(path):refers(Net.c)` on the server view of a client-sent event or request declares
  that a field holds keys of collection `c`: a top-level field whose codec is `c`'s key codec, `t.optional` of it,
  or `t.array` of it, each element matched (another codec: `fieldCodec`; on the generated path a type error). A
  delivered message whose referenced key is in the sender's decoy history is `decoyReferenced` (§10), one
  occurrence per matching element. Keys deeper in a payload are reported through `reportInteraction`.
- **Rewind** (a collection with both `decoys` and `rewind`) `[decoy-challenge-facts §1]`. After each state tick's
  result is applied, each live decoy's `rewind` fields are written into a ring per (viewer, decoy), the 24 B slot
  and length real records use, holding the decoded quantized values that viewer was sent. `rewound(seen, key)` and
  `rewoundSpan(seen, key)` for a key that is one of `seen`'s player's decoys return from that ring, in the shape a
  real record's result has; a tick outside the decoy's life gives `notHeld`; another viewer's decoy key gives
  `unknownKey`, as a key never live does; `at(tick, key)` gives `unknownKey` for every decoy, which has no truth,
  only what one viewer was shown. `Net.c:held(seen)` returns a frozen array, in slot order, of every key k for
  which `rewound(seen, k)` is `ok`: the records in the viewer's audience and interest at some tick of the window,
  those removed since its low end, and the viewer's decoys alive in it. Slot order puts decoys among real records,
  so a ray-tested shot that names no target reaches a decoy through the game's own test. Lync builds no hit test
  and puts no decoy flag on a result: the game decides hits.
- **Interactions.** `Net.c:reportInteraction(player, key, kind)` (server view of any collection) states that the
  game resolved an interaction of `player` with `key`; `kind` is the game's integer 0–255 (otherwise
  `valueRefused`). It returns nothing for real and decoy keys alike, so game code calls it for every interaction
  it resolves without branching; a key in the player's decoy history is `decoyInteraction` (§10). It belongs where
  the client's own message selected the record (named, aimed at, touched, opened), never where the server selected
  it (area damage, server auto-target), which would make the fact fire with no client involvement.
- **Prices** **state** readers that act on what they read (aim, target selection, auto-collect choosing records from
  replicated state rather than the screen) and **api** drivers firing at every key they find. The fact is computed
  on the server from the client's own message and the game's own test, so a modified client can avoid it only by
  never choosing a decoy. What it proves is exact: the server sent this record only to this player, and the
  player's message named it or the game's test found an interaction with it; what that means rests on placement,
  which is the game's. Not priced: tools acting only on what is rendered; readers that reproduce the game's
  visibility; passive readers; engine-replicated parts; and **share**: two accounts comparing key sets spot a decoy
  only one of them holds (R15 stays refused). Nothing on the client marks a decoy (R19 stays refused), so **mem**
  and **code** learn nothing new.
- **Known causes on an unmodified client** `[decoy-challenge-facts §4.2]` (for `decoyReferenced`, `decoyInteraction`
  and a rewound hit): (1) placement the game's client renders; (2) a camera turn faster than the behaviour follows:
  "behind" is relative to the server's last view, so after a fast turn a "behind" decoy can be on screen for about
  rtt + 1/`state.rate` + D, 0.25 s at 100 ms round trip, 20 Hz and D = 0.1 s (derived, unmeasured); (3) in-flight
  removes and interpolation: a decoy moved out of view stays drawn at its old place for up to one-way latency + D
  (`removedAgo` at most about rtt + D, `heldAtPerceived` 1); (4) streamed-out occluders, absent on the client with
  `StreamingEnabled` (`Model.ModelStreamingMode = Persistent` keeps them); (5) a hit test that doesn't raycast the
  world first; (6) server-selected interactions passed to `reportInteraction`; (7) game code that targets every
  record it holds (aim assist, target lock, tab-targeting, an auto-collect magnet, "select nearest", a report
  button).
- **Cost** (server native). Behaviour call and diff 0.21–0.32 µs per viewer per state tick; per decoy viewer one
  full-search re-encode of each changed chunk in flushes where its decoys have rows there, 19.3 µs at one decoy,
  2× a shared-chunk encode at 16 and 15× at 256 (an upper bound: the probe's encoder runs at about twice the
  build's ns per value) `[security-costs claim 6]`; a behaviour that moves only `:newest()` fields and replaces its
  decoy every 5 s pays 3.9 µs/s per viewer. Ring push 9.5–10.5 ns per decoy per tick; ring memory 24 B × K per
  (viewer, decoy), 65 KB at 100 viewers, one decoy, 20 Hz and `maxRewind` 1 s. `held` 316–564 ns per call at 65
  keys, 808–891 ns at 301. `reportInteraction` 24–36 ns for a real key, 44–54 ns for a decoy. History: one map
  update per decoy add and remove. Wire: the decoys' own rows, and 1 bit per slot field of the collection whenever
  the product raises ⌈log2 `maxRecords`⌉ (a 64-record collection at 100 players: 7 → 8 bits, about +1% of the
  100-player shooter's rows).
- **Developer cost.** The behaviour must place decoys where the game's own rendering and logic never use them;
  `maxRecords` must cover the decoy slots.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `maxPerViewer` | integer | records | 1–256 | 1 | above; up to `MaxPlayers` × `maxPerViewer` slots of `maxRecords` |
| `kind` (argument of `reportInteraction`) | integer | — | 0–255 | required | none; evidence only |

## 9. Canaries

- **Declaration.** `Net.c:field(path):canary()` on the server view of a collection marks a top-level `t.string`
  or `t.buffer` field with `maxBytes` ≥ 12 (another codec or a shorter one: `fieldCodec`). A field the `strings`
  extension may intern throws `canaryInterned` at the call: an interned value would travel as a shared table
  entry, and an echo as a reference rather than bytes `[refusals-rejudged-1 R33]`. `set` or `patch` of a canary
  field is `canaryWrite`. The UI must never show or send the field.
- **Values.** On each add Lync fills the field:
  - `canary.perViewer` false: 12 random characters of `[A-Za-z0-9]` (strings) or 12 random bytes (buffers), unique
    per record per server, the same for every viewer;
  - `canary.perViewer` true `[generation-methods M15c]`: 8 such characters or bytes, unique per record per server,
    then a 4-character (4-byte) suffix per viewer carrying s = j XOR p, where j is the viewer's join number on this
    server mod 2^23 and p the low 23 bits of HalfSipHash-1-3 keyed by a 64-bit server key (drawn at start from an
    entropy-seeded `Random`, never sent) over (slot u16le ‖ the slot's add count u32le). Strings write s as 4
    base-62 digits of `[A-Za-z0-9]`, most significant first (62^4 ≥ 2^23); buffers write it as u32le. The bit
    section of a state chunk is the same for every viewer (strings and buffers live in the tail, `v5.md` §4.2), so
    the chunk is encoded once and each viewer's copy has 4 tail bytes patched; frames holding such adds leave
    `FireAllClients` for that flush.
  - The server keeps one map from value (from its 8-byte prefix with `perViewer`) to slot and, per viewer, a bitset
    of the slots whose add it sent.
- **Matching.** Every inbound string or buffer value of length 12 is looked up whole (a buffer converted only after
  the length test). A value of 13 to `canary.scanBytes` bytes is searched at every offset, and a longer one in its
  first `canary.scanBytes` bytes: per offset, the 4-byte prefix is read (`readu32` of the value as a buffer), its low
  16 bits tested in a 64 Kbit bitset, then looked up in a map of canary prefixes, then compared in full
  `[security-costs claim 10]`. A hit is a live canary sent to some player: without `perViewer`, one sent to the
  sender; with it, any viewer whose bitset holds the slot, named by the suffix. It is delivered and reported as
  `canaryEchoed` (§10).
- **Prices** **state** readers that send hidden values back, and, with `perViewer`, **share**: a value relayed
  through another account, or found outside the game, names the session it was sent to. Not priced: readers that
  never send values back or normalise them before sharing; per-build variation adds nothing, since a canary that
  varied per build but not per viewer would name only the build.
- **Cost.** 12 B per add. Matching: 13 ns per inbound value of length 12; per offset of a longer value 5.2–6.0 ns
  native (44–51 ns interpreted), so at most 0.34–0.39 ms/s per player native when strings fill the default
  65,536 B/s of inbound bytes; the bitset 8 KB per server; the map and bitsets 47 KB for 100 players × 1024 records.
  `perViewer`: 220 ns native per (viewer, add) for the suffix, 67 ns per viewer for the patched copy, 312 ns per hit
  to recover j; about 0.29 ms/s at 100 viewers × 10 canary adds a second; one 64-bit key and one join-number table
  (one `UserId` per join) per server.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `canary.scanBytes` | integer | B | 0 (whole values only) or 13–16,000 | 256 (chosen: a chat line of 200 B is scanned whole) | up to `scanBytes` − 11 offsets per inbound string or buffer value longer than 12 B, 5.2–6.0 ns native each; server-only |
| `canary.perViewer` | boolean | — | — | `true` (below) | as above; frames holding canary adds leave `FireAllClients`; server-only |

- **`canary.perViewer` default, derived.** It reports every echo the shared form reports, plus echoes from players
  the value wasn't sent to, and names the session of a value found outside the game, for 0.29 ms/s at 100 viewers
  and 10 adds a second. The engine's cost of one `FireClient` per recipient against one `FireAllClients` is
  unmeasured (§12); a measurement showing it material is what would change the default.

## 10. Facts

Evidence is numbers only; times are in seconds and −1 marks "no such moment". "Client-stated" means the number
comes from the client's own frame or `REPORT`: a modified client can send any value or none. Coalescing, caps and
console lines are `v5.md` §7.3's; a fact's `definition` is named where a row says so.

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `unreachable` | a message of a client-sent definition that is: `basis` 1, trapped with `:trap()`; 0, of a complete namespace and unreferenced in the client scan set (generated path, `check.reachability`); 2, on the generic id of a closed definition (woven build, `weave.ids` not `"generic"`) (§3) | 1: dropped (no handler), ask `rejected`; 0, 2: delivered | `basis` | 1: client code firing a definition the server traps, a mistake in the game's declaration; the Studio command bar or a plugin calling it (Studio only). 0: a script outside the client scan set firing the definition (a `ModuleScript` stored in `ServerStorage` or inside a `Tool` and cloned to a client at run time; `check.clientRoots` removes it); a shard reached through a `require` the scan can't resolve and then iterated or indexed by a computed key. 2: code not in the woven place (an asset inserted at run time) firing the definition; a `ModuleScript` outside the client scan set (in `ServerStorage`, say) that the server clones into a client and that fires the definition through the shard (`check.clientRoots` removes it); the command bar or a plugin calling the shard (Studio only) |
| `earlyAnswer` | `challenge` 0: an answer to a server ask whose `roundTrip` < `earlyAnswer.factor` × `minPing`; 1: a value closing a challenge as `answered` whose `after` < `earlyAnswer.factor` × `minPing` (§7) | delivered | `roundTrip` (s; `after` for a challenge), `minPing` (s, b of §7.1), `challenge` | `minPing` above the true path: `GetNetworkPing` is smoothed and lags a sudden latency drop where no ack round trip is in the bound (simulated: a ping-only `roundTrip`/`minPing` of 0.52–0.59 within 0.5 s of a one-way drop from 0.10 to 0.03 s, smoothing assumed). `challenge` 1 also: game client code that sends the answers field when no prompt is shown, matching by chance with probability 1/`values` per value |
| `earlyReaction` | for a message of a definition with `reactsTo`, §7.3's case 1, 2 or 3 | delivered | `case` (1 before stimulus, 2 below floor, 3 never sent), `exact` (1 decided by the receipt or by never-sent, 0 by time), `elapsed` (s, t_r − t_s; −1 in case 3), `minPing` (s, b), `floor` (s, 0 when off), `behind` (frames: the oldest candidate's frame number − the extended receipt in exact case 1, else 0) | every case: game code acting on the same information delivered another way (the entity replicated through `Workspace`, another remote, a client timer that knows when the stimulus comes). Case 1 exact: a key the game reuses for more than `track` stimuli while an older one is still being answered; a Lync bug. Case 1 by time: those, and b above the true path (as `earlyAnswer`); on `v5.md` §9's default network 0 of 200,000 instant responses at b of 0.10 and 0.12 s. Case 2: a response fired by game code from the stimulus handler; a stimulus a player can predict; a person faster than the floor; b 0.02 s above the true path, at which 1.35% of 0.10 s reactions read under a 0.10 s floor. Case 3: the game showing the entity by another path while the viewer's audience or interest excludes the record |
| `unsolicitedAnswer` | a non-nil value in an answers field (§7.4) from a player with no open challenge; `definition` is the answers definition | none (the message is delivered as usual) | `closedAgo` (s since that player's last challenge closed; −1 if none this session), `closedAs` (0 answered, 1 mismatched, 2 timeout, 3 cancelled, −1 none), `matchesLast` (1 the value equals that challenge's token, 0 not, −1 none) | an answer after the deadline (`closedAs` 2, `matchesLast` 1, small `closedAgo`): the player needed more than `within`; a repeated answer (`closedAs` 0, `matchesLast` 1): a double press or game code that resends; game client code that fills the field on messages sent with no prompt shown; an answer entered after the game cancelled |
| `reportedIdentity` | a `REPORT` with `identitySucceeded` > 0 | none | `reported`, `probes` (both client-stated) | Lync called from the Studio command bar or a plugin (Studio only) |
| `reportedSourceUnlisted` | an accepted upstream frame with `caller` 1 (§4); `definition` set when the frame holds messages of one definition only | none (delivered) | `lane`, `messages` (the frame's message count); client-stated | a call started with no game frame on its thread (`task.spawn(view.fire, view, v)`, `coroutine.wrap`, a signal connected directly to `view.fire`) under `callerProbe.noOuterFrame = "unlisted"`; `fire` reached through a function value a library calls with no game frame between (a promise library); a script outside the clone mapping (one game code cloned outside the starter containers); a character model game code renamed; the Studio command bar (Studio only) |
| `reportedRefusedFrames` | a `REPORT` with `refusedFrames` > 0 | none | `reported` (client-stated) | a Lync bug, in which case the client also lost that server frame |
| `reportedInjectedFrames` | a `REPORT` with `injectedFrames` > 0 | none | `reported` (client-stated) | none, while §5's Studio check holds (events queued before the listener connected are the case it settles) |
| `reportedSelfCheck` | a `REPORT` with `selfCheckFailures` > 0 | none | `reported`, `item` (index in the build's list, which `manifest.json` names), `kind` (1 source differs, 2 line differs, 3 entry is another value, 4 table not frozen); all client-stated | kinds 3 and 4: none (§5: a frozen table can't be written or unfrozen by game code, plugins or the command bar). Kinds 1 and 2: a Lync emission bug, which the build's check removes before release; whether `debug.info(1, "s")` and `debug.info(f, "s")` agree within one module on Roblox is unverified (§12) |
| `clockRate` | at the end of a fit, the player's last `clock.reportFits` fits each counted (§6 rules 5–6): \|`slope`\|, \|`firstHalf`\| and \|`secondHalf`\| above `clock.reportSlope`, all of one sign | none | `slope` (s/s, signed, positive = client clock fast), `fits` (the run so far), `firstHalf`, `secondHalf` (s/s), `othersSlope` (s/s; 0 when `others` is 0), `others` (fits), `drift` (s: o of the first window since the last restart minus o of this fit's last window, sign as `slope`) | a one-way delay whose lower envelope rises (`slope` < 0) or falls (> 0) by more than `reportSlope` s/s across both halves of `reportFits` fits, for at least 60 + 5 × (`reportFits` − 1) s: a queue building or draining on the client's uplink (other traffic on the link; multi-second queues are reported on consumer links, Gettys & Nichols 2011, unmeasured on Roblox) or in the server's inbound processing (then `othersSlope` is within fit noise of `slope`; unmeasured on Roblox). Simulated: a 1 s queue built over 60 s fires for 300 of 300 players, 0.5 s over 60 s for 0 at the default and 232 of 300 at `reportSlope` 0.0068. At `reportSlope` ≤ 0.0069 only: a clock correcting at the documented 0.6% bound plus fit noise (simulated maximum 0.00691). Not causes (simulated): network jitter, one delay step of any size, hitches up to 10 s. `drift` bounds a queue at its depth (p50 0.70 s, max 1.03 s at the first fact), where a modified clock's grows |
| `tagVariant` | a tagged upstream frame that fails under the player's assigned mask at every candidate, and whose tag XOR the keyed hash at one candidate is another variant's mask (§2.4); in place of `tagMismatch` | frame dropped; e unchanged; counts toward `desync` | `lane`, `variant` (the matching mask's), `assigned` (the player's), `skipped` (reliable: j, the candidate's offset from e; unreliable: −1, 0 or 1, the neighbour of the extended seq) | chance: a frame failing for a `tagMismatch` cause matches one of the N − 1 other masks with probability (N − 1) × 5 × 2^−32 (reliable) or (N − 1) × 3 × 2^−32 (unreliable): for a keyless sender at the default budgets one per 37.7 days at N = 2, 14.3 h at 64, 3.5 h at 256, each beside about 4.5 × 10^6 `tagMismatch` occurrences from the same player, while a carried mask matches on every frame; a Lync bug installing a variant other than the one assigned |
| `variantMissing` | local, client: `build.playerVariants` ≥ 2 and no variant installed 10 s after the connection's first `WELCOME` | keeps waiting; tagged sends stay held | none | a server error before the variant was parented; game code removing `PlayerGui.Lync` before the client bound it; a variant arriving more than 10 s after `WELCOME` (arrival time unmeasured, §12) |
| `decoyReferenced` | a delivered message whose `refers` field, or any element of it, holds a key in the sender's decoy history for that collection (§8): a decoy of that player live now, or removed less than r ago; one occurrence per matching element | delivered | `sentAgo` (s since the decoy's add to that player), `removedAgo` (s since its remove; −1 while live) | §8's seven causes |
| `decoyInteraction` | game code calls `Net.c:reportInteraction(player, key, kind)` with `key` in `player`'s decoy history for `c`; `definition` is the collection | none (the call is the game's; Lync records it) | `kind` (the game's integer), `sentAgo`, `removedAgo` (as above), `heldAtPerceived` (1 the decoy was alive for that player at some tick of the perceived window of the message being dispatched; 0 not; −1 no window: called outside a handler's synchronous part, or `c` has no `rewind`) | §8's seven causes |
| `canaryEchoed` | an inbound string or buffer value that is, or within its first `canary.scanBytes` bytes contains, a live canary sent to some player (§9): without `canary.perViewer`, to the sender | delivered | `sentAgo` (s since the record's add), `sentToUserId` (the player it was sent to; without `perViewer`, the sender), `sameViewer` (1 the sender; without `perViewer`, always 1) | `sameViewer` 1: game code that sends a record's fields back, canary included; a player's text containing a live canary by chance, probability 62^−12 per 12-byte window per canary sent to that player. `sameViewer` 0: chance only, about 62^−8 × (viewers sent the add) / 2^23 per 12-byte window (5.5 × 10^−20 at 100 viewers), since an unmodified client never receives another viewer's suffix |

## 11. Published-place attestation (milestone 6)

- **What it states** `[refusals-rejudged-1 R11]`. A server runs one place version until it is shut down, and its
  clients get their scripts from it, so the client scripts an unmodified client runs are the published version's.
  `lync check --published` compares that version's shard parts, woven copies and scanned client scripts with the
  build's manifest, through one Luau Execution task (mechanism, codes and the decision for an unreadable `Source`:
  `v5-tooling.md` §3.4, §4.3).
- **What it prices.** None of §1's classes: it finds published client code that differs from the reviewed build (a
  collaborator's Studio publish over a CI release, a shard pair from another run, an edited shard). A modified
  client is untouched by it, and it attests nothing about what any client runs beyond the unmodified case.
- **Run-time self-attestation stays refused.** No API lets an unmodified client read its own code (`Source` needs
  `PluginOrOpenCloud`, `Script:GetHash` is `LocalUserSecurity`), and anything the shard computes about itself a
  modified client computes by running the same shard, which proves only what a valid tag already proves. §5's
  self-check is different in kind: it reports changes to Lync's own live tables, not an attestation of code.
- **Cost.** Zero at run time and on the wire; one task and one SHA-256 per listed script per check.

## 12. Pending measurements

Each has the default or assumption the design uses until it is measured (`v5.md` principle 8); `v5.md` §10 lists
the Roblox-wide items.
- **Seeds:** an OS entropy source in Lune and the entropy of `HttpService:GenerateGUID()` in Studio; until checked,
  those builds have a public-quality seed (§2.1).
- **Variants:** a server-parented `PlayerGui` child's arrival time after `WELCOME` (join latency, the
  `build.playerVariants` default, `variantMissing`'s 10 s); measured from `os.clock()` at a `ReplicatedFirst`
  script's start to the module's `ChildAdded` (§2.4).
- **Caller probe** (Studio, before release): a member that fails at identity 2 and succeeds at 8, and its cost on
  devices; whether a caught capability failure writes a client log line (if it does, `oneIn` returns to sampling);
  whether unmodified sources follow the clone mapping (if not, the source check is removed); the command bar's
  identity and source string; whether a script renamed or moved after loading keeps its source string; whether
  `task.spawn` and signal routes leave no outer frame (§4).
- **Listener check** (Studio, gating): `debug.info(2, "f")` nil for every engine delivery under both
  `SignalBehavior` values, queued events included; if not, the check is removed (§5).
- **Self-check:** whether `debug.info(1, "s")` and `debug.info(f, "s")` agree within one module on Roblox; what
  `debug.info` reports for a Lua function an executor hooked in place (kinds 1–2's reach) (§5).
- **Clock:** fit noise and slew on devices, delay-envelope ramps on client uplinks, server inbound backlog under
  load; every figure in §6 is simulated (the 0.01 and 3 defaults).
- **Timing:** `GetNetworkPing`'s smoothing and per-call cost on servers (the 0.5 factor, §7.1); whether remotes
  fired at `PostSimulation` leave in that frame's network step (0–16.7 ms inside every elapsed time); real answer
  times for human-gated prompts; reliable-lane stalls on mobile and whether a backgrounded client keeps receiving
  (challenge `timeout` causes); `Random:NextInteger` cost on servers (§7).
- **Decoys:** the camera-turn window for "behind" placements, derived only (§8).
- **Canaries:** the engine's cost of one `FireClient` per recipient against one `FireAllClients` (the
  `canary.perViewer` default, §9).
- **Published place:** whether a Luau Execution task can read `Source` (§11; `v5-tooling.md` §4.3).
