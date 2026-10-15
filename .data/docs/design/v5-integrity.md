# Lync v5: client-side integrity (milestone 5)

Draft 3, 2026-10-15. Part of the v5 design (`v5.md`). The tag, the replay window and the id permutation are part of
the frame format and are specified in `v5.md` §4.5 (milestone 2). This file specifies the rest, and gives the case
for each measure. Refused measures, re-judged, are in `v5-changes.md`.

## 1. How measures are judged

An executor reads and rewrites every Lync table, upvalue and constant on its client and can call Lync's own API
`[client-security §1.2]`. Client-side measures cannot make a forged message impossible. Each is judged by the cost
it imposes on tampering against its runtime, wire, size and developer cost. "An attacker with full memory access
can defeat it" and "a universal counter exists" are not reasons on their own: Lync varies what a counter depends
on per build (rotation), per server (permutation) and per session (the key), so a counter written against one has
to be rebuilt or re-run against the next.

| Route `[client-security §1.4]` | What the attacker does | Measures that price it |
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

- **Mechanism.** A nonzero `build.seed` (`lync.toml`) rotates two things on the generated path:
  - each record's field order: Fisher–Yates over the fields in name order, exactly as `v5.md` §4.5's permutation,
    with xorshift32 seeded by the build seed XOR the low 32 bits of HalfSipHash-2-4 (zero key, 64-bit output) of the
    record's path (`arena.fighters.data`, UTF-8), a zero seed replaced as there;
  - the upstream tag's HalfSipHash initialisation constants (`0x6c796765`, `0x74656462`), replaced by the first two
    outputs of xorshift32 seeded with the build seed.

  Union variant order and ids don't rotate `[review-2 m1]`. On the generated path the tag function, key and count
  live in the client shard. The runtime path always runs at seed 0.
- **Prices** static encoders and decoders, and tag reimplementations, built against an earlier build: they are
  rebuilt per release, or written to re-derive layout and constants from each shard.
- **Cost.** Zero at run time: seeded shards compile to the same opcode sequences, differing only in constants and
  the order of field writes `[client-security-build §2.3]`; zero bytes. Developer: a fresh seed per release
  (`seed = "release"` in CI, or the plugin's "Prepare release"); offline decoding needs the seed, which the shard
  header, the manifest and every `HELLO` carry.
- **Option** (`lync.toml`): `build.seed`, integer 0–2^32 − 1 or `"release"` (a fresh seed per CI release), default
  0. The seed is the one switch: draft 3's `rotate.fields` and `rotate.tag` are gone, since a nonzero seed with both
  off changed nothing at run time yet still refused runtime-path clients `[review-redundancy-2 7]`.

## 3. Traps and reachability

- **One fact, `unreachable`, evidence `declared` (0 or 1)** `[review-redundancy-2 5]`: a message of a client-sent
  definition that client code doesn't fire.
  - **Declared:** `Net.x:trap()` on the server view of an ordinary client-sent definition. The shared schema shows
    nothing special. Any arrival is dropped (a trap has no handler; `connect` or `handle` on it is a caller error;
    an ask is answered `rejected`) and reported with `declared = 1`. Works on both paths.
  - **Inferred** (generated path, `check.reachability = true`): the build marks a client-sent definition reachable
    when its name appears after `.` or `:` as a field access, or as a string literal, anywhere in client-reachable
    code (scripts that replicate, and `Packages/`; for roblox-ts, the compiled Luau). A namespace is incomplete,
    and nothing is inferred for it, only when its shard value is indexed with a non-literal expression. Aliases,
    `return Net`, `self.Net = Net` and passing the namespace around are not escapes `[review-2 m7]`. A message of
    an unreachable definition is delivered and reported with `declared = 0`. The rule over-approximates (any `.chat`
    counts), so it never reports an honest call.
- **Prices** API drivers firing tempting names: they must learn, per game, what honest client code fires.
- **Cost.** One flag check and one table index per message; a trap takes one id. No bytes. The build scans text.

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
  client sends anyway; it never forces a frame `[review-redundancy-2 8]`. The server reports one fact, `clientReport`,
  with the four counts as evidence `[review-redundancy-2 6]`.
- **Prices** naive API drivers: a script that neither lowers its identity nor loads under a listed chunk name reports
  itself with probability 1 − (1 − 1/oneIn)^calls (64% after 20 calls, 99.4% after 100 at the default). A patched
  Lync stops sending counts, which the server can't tell from an honest client.
- **Cost.** A random draw per fire, 24–32 ns; at most `maxPerSecond` failing `pcall`s of 2.2–3.3 µs and source reads
  of 57–72 ns `[probes review-redundancy-2 inbound_hotpath]` `[client-security §2.2]`. Honest causes: the Studio
  command bar and plugins; scripts the game clones outside the starter containers.
- **Unverified, checked in Studio before release:** a suitable member and its cost on devices; whether a capability
  failure caught by `pcall` is logged; whether honest sources follow the clone mapping. If the last fails, the
  source check is removed.

| Option | Type, unit | Range | Default | Cost |
|---|---|---|---|---|
| `callerProbe.oneIn` | integer, calls | 0 (off) or 1–255 | 20 | one draw per call; travels in `WELCOME` as u8 |
| `callerProbe.maxPerSecond` | integer, probes/s | 1–60 | 10 | ≤ 3.3 µs per probe; u6 in `WELCOME` |

## 5. Refused-frame report

The client decoder is as strict as the server's (`v5.md` §4.8). Each downstream frame it refuses is counted in
`REPORT` as `refusedFrames`. It prices injectors of non-canonical frames into a client's own view, who must build
canonical frames for this build and server or patch Lync. Cost: none beyond decode. Honest cause: a Lync bug, in
which case the client also lost a server frame.

## 6. Clock beacon

- **Mechanism.** The client sends `BEACON` (control type 6, up: ⌊`GetServerTimeNow()` × 1000⌋ mod 2^16 as u16) at
  most once per `clock.beacon` seconds. Per player, the server keeps, per 5 s window, the minimum of arrival time −
  stamp, and every 5 s fits a Theil–Sen slope over the last 12 windows (66 pairwise slopes). It reports `clockRate`
  (evidence `slope`, `fits`) when the slope exceeds 0.006, the documented bound between `GetServerTimeNow` and the
  local clock, in 3 consecutive fits; what threshold matters is the game's choice `[client-security §4 T1]`
  `[review-redundancy-2 7]`. The first 30 s after join are ignored, and an arrival gap over 3 × `clock.beacon`
  restarts the estimate `[review-2 M7]`.
- **Prices** tools that accelerate the client's clock; they must keep Lync's stamps on unaccelerated time.
- **Cost.** About 4 B per beacon; one 66-slope fit per 5 s per player. Off by default until mobile jitter is measured.

| Option | Type, unit | Range | Default | Cost |
|---|---|---|---|---|
| `clock.beacon` | number, s | 0 (off) or 0.5–1.5 | 0 | about 4 B per beacon; u4 tenths in `WELCOME` |

## 7. Early answers

- **Mechanism.** For each server `invoke`, Lync records the send time and samples `Player:GetNetworkPing()`. An
  answer arriving sooner than `earlyAnswer.factor` × the smallest ping sampled for that player in the last 10 s is
  delivered and reported as `earlyAnswer` (evidence `roundTrip`, `minPing` in seconds).
- **Prices** answers sent before the ask could arrive (a bot predicting a timed prompt gains up to one round trip).
- **Cost.** One clock and one ping read per server ask; no bytes. Honest cause: `GetNetworkPing` is smoothed and
  can lag a sudden improvement.

| Option | Type, unit | Range | Default |
|---|---|---|---|
| `earlyAnswer.factor` | fraction of the minimum ping | 0 (off) to 1 | 0.5 |

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
    key is a decoy sent to that player is reported as `decoyReferenced` (evidence `sentAgo`, seconds).
- **Prices** raw-state readers: a cheat must reproduce the game's notion of visibility, per game and per behaviour.
  Remaining tell: two colluding accounts comparing key sets can spot a decoy where every viewer sees every record.
- **Cost.** Per viewer with decoys: one re-encode of each changed partition chunk per flush, and the decoys' bytes;
  one behaviour call and diff per viewer per state tick, 236 ns native `[probes review-redundancy-2
  integrity_state]`; such viewers leave `FireAllClients` for those flushes. Developer: the behaviour must place
  decoys where honest rendering and logic never use them; honest aim assist or "target everything" code produces
  honest `decoyReferenced` facts.

| Option | Type, unit | Range | Default |
|---|---|---|---|
| `maxPerViewer` | integer, records | 1–16 | 1 |

## 9. Canaries

- **Mechanism.** `Net.inventory:canary("promoCode")` on the server view marks a top-level `t.string` or `t.buffer`
  field of a collection with `maxBytes` ≥ 12 (an unknown field throws `unknownField` at the caller, a shorter one
  `valueRefused`). On each add Lync
  fills it with 12 random characters from `[A-Za-z0-9]` (strings) or 12 random bytes (buffers), unique per record
  per server; `set` or `patch` of it is `canaryWrite`. The server keeps one server-wide map from value to slot and,
  per viewer, a bitset of slots whose add it sent. Every inbound string or buffer value of length exactly 12 is
  looked up (a buffer is converted only after the length test); a hit for a slot sent to that player is delivered and
  reported as `canaryEchoed` (evidence `sentAgo`) `[review-redundancy-2 9]`. Matching is exact; a canary inside a
  longer string is not found `[review-2 m3]`.
- **Prices** raw-state readers that send hidden values back, and attributes leaks (a canary found outside the game
  names its record and server).
- **Cost.** 12 B per add; 13 ns per inbound string, no allocation for buffers of other lengths; 47 KB for 100
  players × 1024 records against 3.2 MB for per-player sets. Developer: the UI must never show or send the field.
