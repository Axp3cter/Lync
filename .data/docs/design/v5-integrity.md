# Lync v5: client-side integrity (milestone 5)

Draft 3.5, 2026-10-15. Part of the v5 design (`v5.md`). The tag, the replay window and the id permutation are part
of the frame format and are specified in `v5.md` §4.5 (milestone 2). This file specifies the rest, and gives the
case for each measure. Refused measures, re-judged, are in `v5-changes.md`. "Unmodified client" is defined in
`v5.md` §1.

## 1. How measures are judged

An executor reads and rewrites every Lync table, upvalue and constant on its client and can call Lync's own API
`[client-security §1.2]`. Client-side measures cannot make a forged message impossible. Each is judged by the cost
it imposes on tampering against its runtime, wire, size and developer cost, and by `v5.md` principle 2 that cost is
weighed, never a veto by itself: where it matters, an option controls it. "A modified client with full memory
access can defeat it" and "a universal counter exists" are not reasons on their own: Lync varies what a counter
depends on per build (rotation), per server (permutation) and per session (the key), so a counter written against
one has to be rebuilt or re-run against the next.

| Route `[client-security §1.4]` | What the modified client does | Measures that price it |
|---|---|---|
| raw sender, packet injector | fires Lync's remotes, or edits packets below the encoder | tag, replay window, the server's shape and budget checks |
| replayer | resends captured frames | tag (reliable), replay window (unreliable) |
| static forger | builds frames from the published format | tag, permutation, rotation |
| extractor | reads key, count and permutation from memory, encodes itself | count lockstep (slips are `tagMismatch`/`frameGap`), permutation per session, rotation per build |
| API driver | calls `Net.x:fire()` from executor code | traps and reachability, caller probe |
| injector of inbound frames | fires Lync's client listener with fake frames | refused-frame report |
| raw-state reader | reads replicated state from memory (ESP, radar, bots) | decoys, canaries |
| timing tools | accelerates the client clock; pre-answers server asks | clock beacon, early answers |

Tamper cost of the milestone 2 measures: the tag makes a forger read the key every session and keep the count in
lockstep with Lync's own sends; the permutation makes a byte tool read this server's seed or table every session
`[review-2 m5]`.

## 2. Per-build rotation (kept: author decision)

- **Mechanism.** A nonzero build seed rotates two things on the generated path:
  - each record's field order: Fisher–Yates over the fields in name order, exactly as `v5.md` §4.5's permutation,
    with xorshift32 seeded by the build seed XOR the low 32 bits of HalfSipHash-2-4 (zero key, 64-bit output) of the
    record's path (`arena.fighters.data`, UTF-8), a zero seed replaced as there;
  - the upstream tag's HalfSipHash initialisation constants (`0x6c796765`, `0x74656462`), replaced by the first two
    outputs of xorshift32 seeded with the build seed.

  Union variant order and ids don't rotate `[review-2 m1]`. On the generated path the tag function, key and count
  live in the client shard. The runtime path always runs at seed 0.
- **Prices** static encoders and decoders, and tag reimplementations, built against an earlier build: they are
  rebuilt per release, or written to re-derive layout and constants from each shard.
- **Option** (`lync.toml`):

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `build.seed` | integer, or the string `"release"` | — | 0–2^32 − 1 | `"release"` | below |

  - **`"release"`**: each `lync build` or `lync watch` rebuild draws one seed, uniform on 1–2^32 − 1, from the
    host's random generator seeded from the clock, and uses it for every namespace and both sides of that run; the
    seed is written to `manifest.json` and every shard header. It need not be secret, since every shard header and
    `HELLO` carries it; it only has to differ between builds. A client shard and a server shard from different runs
    have different seeds, and the server answers that client's `HELLO` with `MISMATCH` (`schemaMismatch`,
    `seedDiffers` 1). The Studio plugin's "Prepare release" writes a drawn integer the same way.
  - **An integer** fixes the seed; 0 is the identity (no rotation), as on the runtime path and in tests.
  - **Cost.** Zero at run time: seeded shards compile to the same opcode sequences, differing only in constants and
    the order of field writes `[client-security-build §2.3]`; zero bytes. Developer: with `"release"`, every build
    changes every shard's bytes (version-control diffs, if shards are committed), and client and server shards must
    come from one run; offline decoding needs the seed, which the shard header, the manifest and every `HELLO`
    carry. Draft 3's `rotate.fields` and `rotate.tag` are gone: the seed is the one switch `[review-redundancy-2 7]`.

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
