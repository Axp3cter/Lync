# Refusals re-judged, part 3: R1, R2, R21, R28, R39

Researcher findings, 2026-10-15. **Decision it feeds:** whether each of five refused items, which have measured
costs (`probes/security-costs/RESULTS.md`) but no verdict on protection, enters the v5 design and in what form.
The author's direction: earlier refusals leaned on runtime-path limits and on costs that were exaggerated or never
worked through; generation (per build, per server, per session, per player; `research/generation-methods.md` §0.5)
is available. Each item is judged on what it protects and what it costs; where no form holds, the reason is
stated with evidence and is never cost alone. This file is written from the sources; an earlier fallback draft
was used only as a list of claims to re-check (corrections are in each item's last paragraph).

**Read for this unit:** each item's entry in `research/security-refusals.md` (SR) and what it cites: CS =
`research/client-security.md` §1.2–1.4, §3.1–3.3, §3.7; CH = `design/v5-changes.md` (M11 row, R7/R8 rows, the
3.5 re-judged and cost tables); `design/v5.md` §1, §4.1–4.10, §5.4, §6, §7.3–7.5, §8, §10; `design/v5-integrity.md`;
`design/m2-plan.md` §2 (the `Transport` seam); `reviews/v5-design-1.md` M11; `research/landscape.md` implication 14;
`research/refusals-rejudged-1.md` R34 (RR1); `research/client-self-checks.md` U2, U7 (CSC);
`research/generation-methods.md` §0, M8, M13 (GM); `design/v5-3.6-inputs.md` (where 3.6 already lists a change).

**Capability classes** are CS §1.2's, grouped as in GM: **code**, **mem**, **api**, **hook**, **signal**,
**packet**, **identity**, **naming**, **clock**, **state**, **share**. Routes A0–A8 are CS §1.4's. "Modified
client" and "unmodified client" are `v5.md` §1's terms.

**Labels.** **verified**: I ran it or read the source. **documented**: official docs (Roblox, or the design for
what the design says). **reported**: third party. **unverified**: inference, or not checkable here. **Cost
provenance:** **measured** (a `.out` file named), **derived** (arithmetic, inputs shown), **asserted** (neither).

**New probes** (`.data/docs/probes/refusals-rejudged/`, run by `sh r3_run.sh <luau>` with Luau 0.742 built from
`.data/projects/luau`; `-O2` interpreted is the Roblox client case, `-O2 --codegen` native the Roblox server case
when its scripts are native; Intel Xeon 2.1 GHz, shared machine; CLI timings show scale, not device figures):
- `r3_limit.luau` → `r3_limit.out`: three `limit` counting rules under honest stalls and modified-client patterns
  (deterministic, one run);
- `r3_origin.luau` → `r3_origin.out`: what a listener sees below itself on its thread, and the cost of looking
  (3 runs interpreted, 3 native);
- `r3_tagwidth.luau` → `r3_tagwidth.out`: keyless acceptance against tag width, frame budgets and tag-input
  variants; M13's chance `tagVariant` rate; upstream framing bytes (deterministic arithmetic).

**Fixed for every item** (the lead's constraints, checked against `v5.md` §4.2, §4.7, §4.10 and GM §0.4): the
seed-0 golden frames (G1–G11, PERM), the schema hash, generated Luau and `.d.ts` types, encode-once downstream and
`FireAllClients`. A form that would move one of them is excluded and the item says which.

**Rule applied.** Lync drops only malformed input (and over-budget input, as the design already does) and reports
facts with exact triggers and evidence; it never acts on a fact. No presets, tiers, merged modes or one option for
several triggers; every default derived or marked chosen.

## Checklist

- [x] R1. Downstream tags and a client-side replay window
- [x] R2. Masking or whitening frames
- [x] R21. Counting `limit` by client send time
- [x] R28. A 64-bit tag, and the 32-bit default
- [x] R39. A per-frame transform hook
- [x] Implications

---

## R1. Downstream tags and a client-side replay window

**Earlier reason and what it assumed.** Three statements. CS §3.1: "the only consumer of that verdict is client
code the attacker controls". CH (draft 2): "a PRF per recipient per frame (0.48–5.5 µs native each), which at 100
players × 60 Hz is up to about 3% of a core, and the end of `FireAllClients`". CH 3.5: "Cost is not the reason: no
third party can write a client's downstream (the engine's transport carries it), so they protect only a modified
client's view from itself; the refused-frame report covers non-canonical injection." Assumed, and not checked:
(a) that the engine's transport is authenticated, so no third party can write a client's downstream (stated
without a source); (b) that the measure is a *protector* of the client's view. (b) contradicts the design's own
`refusedFrames` and caller probe, which are *detectors* whose counts reach the server in `REPORT`
(`v5-integrity.md` §4–5): the consumer of such a count is the game's observer on the server, not client code.

**Who can write a client's downstream.** (a) is reported, not documented: a third-party analysis of Roblox's
transport (2026-08-23/24) reports AES-256-GCM in live captures in both directions, ChaCha20-Poly1305 as the other
format, and keys "resident in RAM … they never go over the wire", derived from an X25519 exchange
([topologyorgboi/Roblox-RakNet-Decompilation-Project#1](https://github.com/topologyorgboi/Roblox-RakNet-Decompilation-Project/issues/1),
**reported**; Roblox documents nothing on transport encryption, searched: Roblox docs, DevForum, the web). Both
ciphers are AEADs, so a network party cannot inject frames that the engine accepts (**unverified** beyond that
report). Game code cannot fire `OnClientEvent`: it fires for the server's `FireClient`/`FireAllClients`, and
"Clients cannot communicate directly with other clients" ([Roblox docs, remote events](https://create.roblox.com/docs/scripting/events/remote),
**documented**). What remains is the client's own process: **signal** (`getconnections` → `Fire`/`Defer`,
`firesignal`: "Fires all Lua connections of `signal`"; Potassium v2.3.5 reference, **documented** by the vendor),
**packet** (`raknet` receive hooks: read, modify, drop or inject below Luau, CS §1.2), **hook** and **mem**
(rewrite Lync's handler or state).

**What it would protect, and what the server already sees.** Nothing a modified client lacks: an injected frame
changes only that client's view, which **mem** changes directly, and any upstream message it provokes is one the
**api** class sends directly, checked by the server like every upstream message. The upstream effects of
injection that a server can check are already server-verified facts: an ack for a state-frame seq never sent is
`impossibleAck`; an answer for a free or reused slot is `slotConflict` (`v5.md` §7.3). Non-canonical injected
frames are refused and counted (`refusedFrames`, `v5-integrity.md` §5). What a detector would add is a
**client-stated count of canonical injection** (replays of captured frames, frames built with Lync's own encoder)
seen by an unmodified Lync: the evidence class of `reportedIdentity`, which the design adopts. So the item is
judged as a detector, priced against the cost of the forms that could produce that count.

**Forms considered.**

| Form | What it detects | Wire and fixed-artefact effect | Cost | Verdict |
|---|---|---|---|---|
| (a) per-recipient tag over an implicit downstream count | **signal** and **packet** injection and replay by tools without the key | +4 B per downstream frame; recipients' bytes differ, so encode-once and `FireAllClients` end | per-recipient HalfSipHash: 0.24–3.3% of a core native at 64 B–1 KB, 13.3% at 4 KB, 8.3–34% interpreted at 256 B–1 KB, 100 players × 80 frames/s; hash once plus a 2-word per-recipient PRF: 0.06–0.19% native, 0.7–2.0% interpreted (**measured**, `security-costs/downstream_tag.out`, RESULTS claim 3) | excluded: moves `FireAllClients`, a fixed constraint |
| (b) tag under a per-server, per-tick key | crafted frames from tools that never read the key | +4 B per downstream frame; G2, G2b, G3, G10, G11 change | hash once per frame | refused: every recipient holds the key (it must, to verify), and a replay carries a valid tag, so it detects only tools that build canonical frames without Lync's encoder, which already need the layout and permutation that **mem** reads with the key |
| (c) a server-wide downstream frame number F, checked by a client window | replays of captured frames (F not newer) | absolute u32 F on every downstream frame: 4 B × 80 frames/s = 320 B/s per player at the busy model (derived); G2, G2b, G3, G10, G11 change | one compare per frame | excluded: changes seed-0 golden frames; the only reader it adds is a replaying tool |
| (d) listener origin check (below) | **signal** injection that runs Lync's listener synchronously from the firing code | none; one `REPORT` field (milestone 5 control, not in the golden set) | 30.0–38.2 ns per frame interpreted, 21.1–24.3 native (**measured**, below) | adopted |

A replay window on state frames needs no bytes, but the client already applies a row only when its frame's seq is
newer than the stored one (`v5-collections.md` §6), so a replayed state frame changes no row; counting duplicate
seqs would report engine duplication, which is unmeasured (`v5.md` §10), as injection. Not adopted.

**Form (d), in Lync's terms.** The function Lync passes to `Reliable.OnClientEvent:Connect` and
`Unreliable.OnClientEvent:Connect` reads `debug.info(2, "f")` as its first statement. Engine delivery resumes the
listener as the first function of its thread, so nothing is below it; a synchronous call from other code leaves a
frame below it. Measured in the CLI (`r3_origin.out`, every run identical):

| How the listener is entered | `debug.info(2, "s")` | `debug.info(2, "f")` |
|---|---|---|
| first function of a fresh coroutine (`coroutine.resume`, `coroutine.wrap`) | nil | nil |
| called by a C function (`pcall`, standing in for any synchronous C-side fire) | `[C]` | a function |
| called by a Lua function | the caller's source | a function |

A frame whose check finds a function below is decoded and delivered as usual (Lync does not act on it) and counted
in a new client counter `injectedFrames`. `REPORT` gains `injectedFrames:EG0` after `refusedFrames`, and a non-zero
`injectedFrames` makes `REPORT` due exactly as a non-zero `refusedFrames` does (today: in the next frame the
client sends, `v5-integrity.md` §4; under RR2 R26's change listed in `design/v5-3.6-inputs.md` §1, pending
reliable data). The probe also
shows the hazard the check must avoid: a Lua caller read as nil at `-O2` until the callee was made opaque to the
compiler, because `-O2` inlined it (`r3_origin.luau` comment); the connected function escapes through `Connect`
and is never inlined, so the check sits in that function itself, never in a helper.

**Cost** (**measured**, `r3_origin.out`, medians of 3 runs): a call plus the check 47.8–57.3 ns interpreted,
36.5–39.6 ns native, against 17.8–19.1 and 15.0–15.4 ns for the call alone, so 30.0–38.2 ns interpreted per frame
(derived). At the busy model's 80 downstream frames/s: at most 3.1 µs of client CPU per second (derived: 38.2 ns ×
80). Wire: 1 bit in each `REPORT` while the count is 0 (EG0 of 0), and `REPORT` is sent only when a count is
non-zero. No server CPU beyond one more `REPORT` field.

**What it does not detect.** **signal** fired from a thread of its own (the vendor documents a `Defer` form beside
`Fire`), whose listener starts like an engine delivery; **packet** receive injection, which the engine then
delivers normally (non-canonical frames still reach `refusedFrames`); **hook** and **mem**, which rewrite the check
or zero the count; **naming** (`setstackhidden` hides frames "from `debug.traceback` and stack walks", CS §1.2;
whether it hides them from `debug.info` levels is **unverified**). What any given tool's synchronous `Fire` or
`firesignal` does is **unverified** and cannot be checked by Lync's team without running executor software.

**Fact.**

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `reportedInjectedFrames` | a `REPORT` with `injectedFrames` > 0 | none | `reported` (client-stated count) | none, provided the Studio check below holds; queued events delivered at `Connect` (Roblox "queues it and delivers it, in order, as soon as a handler connects", remote-events page above) are a candidate cause until that check shows how they are delivered |

**Unverified, checked in Studio before release** (the unmodified side only): inside the connected listener,
`debug.info(2, "f")` is nil for every delivery under both `Workspace.SignalBehavior` values, including events fired
before the listener connected and delivered from the queue. If any case finds a function below, the check is
removed, as `v5-integrity.md` §4 removes the source check when its clone mapping fails.

**Options.** None: the check costs at most 3.1 µs/s on a client (derived above) and has no false fact once the
Studio check passes, so no game has a cost to trade (`v5.md` principle 2 asks for an option only where cost
matters).

**Draft claims corrected.** The draft kept R1 wholly refused on "the only consumer … is client code the attacker
controls" and "a count the server cannot use"; the design already uses client-stated counts as facts (`reported*`,
`v5-integrity.md` §10), so that is not a reason. Its claim that the transport is per-connection and unwritable
by third parties cited `RemoteEvent` docs; no Roblox page states it (it is reported only). Its "+4 B … 160 → ~480 B/s
down" for a shared-key tag is right as arithmetic (80 frames/s × 4 B).

**Outcome: adopt narrowed.** Downstream tags and a replay window stay refused: (a) ends `FireAllClients`, (b) is
verified with a key every injecting client holds, (c) changes seed-0 golden frames to catch replays only. Adopt
form (d), the zero-byte listener origin check, reported as client-stated `reportedInjectedFrames`, gated by the
Studio check above.

---

## R2. Masking or whitening frames

**Earlier reason and what it assumed.** CS §3.7: masking "forfeits engine buffer compression" (+62% to +272%
after zstd) and "adds nothing against A3/A4, since the mask lives in the same client". CH (draft 2): masking only
the bit section costs about 0 B and a per-session key makes passive reading per-session work, "but everything it
hides is readable through the typed API … every forge it blocks the tag blocks; CPU per byte at the tag's rate;
per-connection keys end `FireAllClients`". CH 3.5: "everything it would hide, a reader gets with less work by
requiring the client shard and connecting to its signals". Assumed: the +62–272% applies to v5 frames (it was
measured on draft-wire byte-aligned frames masked whole); the CPU figure (asserted); and that the key is
per connection.

**Measured cost** (RESULTS claim 2). *Bytes* (`security-costs/mask_bytes.out`, v5-shaped frames, zstd level 1 and
3, with and without raw fallback, 597 frames per model): masking the bit section, the tail or both changes the
compressed size by 0% in all four traffic models (95.5–196.0 B plain; the largest move is tycoon at level 1,
204.6 → 205.2 B masking the tail). Large compressible tails behind an 80 B bit section: 600 B of names, 508 → 506 B
masking bits and 508 → 680 B (+34%) masking the tail; 3,240 B of names, 398 → 402 B (+1.0%) and 398 → 3,320 B
(+734%). The draft-wire figures reproduce (+36–67% input-like, +91–267% chat-like): the +62–272% is the price of
masking compressible bytes, which v5 puts only in large tails. *CPU* (`security-costs/mask_cpu.out`, bit section
in place, ratio to the tag over the same bytes): a counter-mode HalfSipHash keystream 2.88–7.09x the tag
(206.7–213.7 ns/B interpreted); a xorshift-plus-Weyl stream seeded by one PRF per frame 0.54–0.83x; a 16 KB
session pad 0.19–0.36x. A key per server and per tick keeps every recipient's bytes identical, so it need not end
`FireAllClients`.

**What it would protect.** Readers of frame bytes that do not decode through Lync: **packet** (`raknet` hooks),
**hook** on `FireServer` or the remotes' signals (a spy showing buffers), and **share** (captures carried to
another machine). It conceals values; the tag authenticates and conceals nothing.

**What such a reader already needs, and what a mask adds to it.** To turn a v5 frame into values a byte reader
needs the schema (the shared module, public), the build's layout and the per-server id permutation. Today the
layout follows from the public build seed in `HELLO` and the permutation from the seed in `WELCOME` (GM §0.1).
Under the changes 3.6 lists, the layout needs the shard's code (a private `rotationSeed`, `design/v5-3.6-inputs.md`
§1, GM M1) and the key and permutation seed are derived from a `WELCOME` nonce under a per-build secret S held in
both shards (GM M8). A mask key that every recipient can use must reach the client the same way: in `WELCOME`, or
derived from the same nonce and S. So a reader equipped to decode obtains the mask key in the same pass that
obtains the permutation seed and tag key; the mask adds no recurring work at any grain (per build, per server, per
session; per player is excluded, since per-recipient keys end `FireAllClients`). A reader not so equipped cannot
use the plaintext bit section either, except by the routes it would also use against a masked one. Through
**api**, a reader requires the shard and connects to its signals and views, and reads decoded values with none of
this work (CH 3.5, unchanged). Upstream bytes are read only by the sending client's own process and the server.

**Consistency with R34 (sealed delivery, RR1).** A value the client must not read before a moment needs its key
off the client until that moment; RR1 R34 adopts exactly that (one key per seal from a server-held secret,
revealed later; 210.2–230.9 ns/B interpreted, 22.3–27.9 ns/B native, `refusals-rejudged/r34_seal.out`), and 3.6
lists it (`design/v5-3.6-inputs.md` §1, the `sealed` option). Masking gives every recipient the key at receipt, so
it hides nothing from the recipient; every case where plaintext must be kept from the client is R34's or
withholding's. The two do not overlap and masking adds no case to R34.

**Forms considered** (none adopted).

| Form | Bytes | CPU | `FireAllClients`, golden frames | What it prices beyond today |
|---|---|---|---|---|
| bit section, downstream, key per server per tick, keystream from one PRF per frame | 0% (measured) | 0.54–0.83x the tag on the client per downstream frame (measured) | kept; golden frames unchanged only if seed 0 means no mask | none: the key comes with the permutation seed |
| as above, key per connection | 0% | as above | ends `FireAllClients` (excluded) | none for the recipient, who holds its key |
| tail as well | +34% to +734% on large tails (measured) | as above | as above | none |
| upstream, any key | 0% for the bit section | client and server, per frame | n/a | none: only the sender reads its upstream bytes |

**Facts, options.** None: no form is adopted.

**Draft claims corrected.** "A capture that misses `WELCOME` cannot decode even unmasked frames (it lacks the
permutation)": the permutation seed is a u32 (`v5.md` §4.5), so a capture can be searched offline against
canonical decode, 2^32 candidates at 26 ns per id to build a permutation (RESULTS claim 11h): 2^32 × 200 ids ×
26 ns = 6.2 h of one core for 200 ids (derived); and wire ids can be learned from one's own sends (GM M4). "A
capture that includes `WELCOME` includes the key, so it unmasks": true today, not under GM M8, where the capture
also needs S from the shard. "A HalfSipHash counter-mode keystream (the construction R34's sealed delivery uses)":
RESULTS' counter mode hashes 2 words per 4 B of keystream, R34 uses HalfSipHash-2-4/64 per 8 B block; they are
different constructions with per-byte rates in the same range (206.7–213.7 against 210.2–230.9 ns/B interpreted).

**Outcome: kept refused.** Reason, not cost (the bit-section form costs 0 B, measured): every byte reader that can
use the plaintext obtains a mask key in the same pass that gives it the permutation seed and tag key, so the mask
adds no recurring work at any grain, and the **api** route needs none; plaintext that must be kept from the
client is R34's sealed delivery, which keeps its key off the client.

---

## R21. Counting `limit` by client send time

**Earlier reason and what it assumed.** Review M11 (`reviews/v5-design-1.md`) asked the server to "measure against
*send* time: count by the client's frame tick rather than arrival time, which the tag counter already orders",
because retransmission after loss releases queued frames together and drops honest messages. CH (M11 row) and
`v5.md` §5.4 rejected it: "upstream frames carry no time, and a client-stated time can't be trusted"; the server
bucket has capacity `burst + 2 s × perSecond` instead. Assumed and not tested: that a stated time, clamped to what
the server can check, would let a modified client raise its ceiling; and that send-time counting would serve
honest clients better than the slack. It prices honest bunching (false `overLimit`), not a capability class.

**Three rules, made precise.** Each is a token bucket of rate `perSecond` (p) that starts full and refills
continuously (`v5.md` §5.4); W = 2 s is the slack.
- **A, the design:** clock = arrival time; capacity b + W·p.
- **B, stated send time:** the frame carries the client's send time; the server clamps it to
  [max(previous clamped value, arrival − W), arrival] (a time may not run backwards, lie in the future, or claim
  more than W of age, the slack the design already grants) and runs a bucket of capacity b on that clock.
- **C, M11's frame tick:** clock = upstream reliable frame count / 60 (the count the tag already orders);
  capacity b.

**Derivation.** Under B, the clamped times of messages arriving in [x, y] lie in [x − W, y], so B accepts at most
b + p·(y − x + W) of them, which is A's bound for the same interval (capacity b + W·p plus refill p·(y − x)).
Conversely a client stating times spaced 1/p apart from the earliest allowed reaches it. So B gives a modified
client exactly A's ceiling, and needs W = 2 s to accept the same honest stalls A accepts: an honest client at its
own limit releases d·p messages after a stall of d seconds, which both rules accept while d·p ≤ b + W·p, i.e.
d ≤ W + b/p. Under C the clock advances only when the client sends a frame: an honest client that fires slower
than its flush rate advances it 1/60 s per message, and a modified client that sends more frames than 60 a second
advances it faster than real time, up to `inbound.reliable.frames.perSecond` / 60 (2x at the default 120 frames/s,
16.7x at the range maximum 1000).

**Simulated** (`r3_limit.out`, deterministic). Honest client throttled to (p, b) with its FIFO, 60 Hz flushes, a
stall of d seconds starting at 5 s, 20 s of traffic; messages dropped by the server:

| Limit, fire rate | d = 0 to 2.5 s: A / B / C | d = 4 s: A / B / C |
|---|---|---|
| p 10, b 20, firing 10/s (200 sent) | 0 / 0 / 147 | 1 / 2 / 147 |
| p 10, b 20, firing 5/s (100 sent) | 0 / 0 / 64 | 0 / 0 / 64 |
| p 1, b 2, firing 1/s (20 sent) | 0 / 0 / 18 | 1 / 2 / 18 |
| p 60, b 60, firing 60/s (1200 sent) | 0 / 0 / 0 | 60 / 64 / 0 |

Modified client (p 10, b 20), messages accepted; B is the best of four stated-time strategies (earliest allowed,
arrival, random in the window, paced 1/p apart):

| Arrival pattern | A | B | C | b + p·(W + span) |
|---|---|---|---|---|
| 1000 at one instant after 10 s idle | 40 | 39 | 186 | 40 |
| 100/s for 10 s | 139 | 139 | 186 | 140 |
| 120 frames/s for 10 s, one message each | 139 | 139 | 219 | 140 |
| 100 every 3 s, 10 times | 310 | 226 | 186 | 310 |
| 60/s for 10 s, one frame each | 139 | 139 | 119 | 140 |

So B never accepts more than A from a modified client, and never fewer drops than A for an honest one (B drops 2
where A drops 1 at d = 4 s, because its clamp is the same W with a smaller capacity). C drops 64–90% of an honest
client's messages whenever it fires slower than 60 messages a second, stall or not, and accepts 1.3–1.6x A from a
modified client sending more than 60 frames a second (186–219 against 139; at 60 frames/s it accepts 119); in the one-instant case the count runs
ahead of time only because this simulation does not apply the frame budget, which would cap it.

**What generation changes.** Nothing: B's stated time is whatever the client's code writes, at any grain, and the
tag binds it to the key holder, not to the clock. The clock beacon (`v5-integrity.md` §6) measures the client's
clock rate over windows, not per-frame send times.

**Cost of B, had it held** (derived): a 16-bit millisecond stamp like `BEACON`'s on every upstream reliable frame,
2 B × 60 frames/s = 120 B/s per player at the busy model, and two more bytes in G4 (a seed-0 golden frame, excluded
by the fixed constraints).

**Facts, options.** No new fact. The derivation gives `overLimit`'s known cause a stall length:
"`burst` + 2 s × `perSecond`" messages queued is, for a client firing at its limit, a stall longer than
2 s + `burst` / `perSecond` (derived above; `v5.md` §7.3 states the count only).

**Draft claims corrected.** The draft wrote that counting by stated time "hands an attacker a free raise of the
rate ceiling"; with the clamp above it raises nothing (derivation and `r3_limit.out`). The reason is equivalence,
not trust.

**Outcome: kept refused.** Reason, not cost: a stated send time clamped to what the server can check gives a
modified client exactly the arrival bucket's ceiling and an honest client no fewer drops (derived; `r3_limit.out`),
so it changes nothing the `2 s × perSecond` slack does not already do, and M11's frame-tick clock drops 64–90% of
honest messages at low fire rates and lets a modified client run its clock ahead by sending more frames.

---

## R28. A 64-bit tag, and the 32-bit default

**Earlier reason and what it assumed.** CS §3.1 chose 16 bits: "32 bits only matters if acceptance were treated as
authentication". `v5.md` §4.5 chose 32: "Lync only reports them, so the width alone has to bound acceptance";
at the default budgets 1320 candidate tags/s, "one acceptance per about 38 days". The 64-bit output was listed
as "8 B and a longer finalization per frame" (asserted). Assumed: that the bound at the defaults is the bound
(the budgets range up to 1000 frames/s per lane, `v5.md` §7.5), and that the number of tag inputs tried per count
is one (U7 adds a second, and a third with the identity bit, CSC U7, listed in `design/v5-3.6-inputs.md` §1).

**Who the width prices.** A sender without the key. Only the client's own process writes its upstream (the
transport is reported to be an AEAD, R1 above), so the keyless sender is a tool inside a modified client that has
not read the key: a raw sender (A0), a **packet** edit below the encoder or a spy's edit-and-resend (A7, A1). An
accepted frame delivers one frame of that tool's choosing: what the **api** class delivers with no guessing, and
**mem** with one key read per session. So the width is not what stops capabilities; it sets how often a keyless
tool's frame is accepted, and every rejected candidate frame is a server-verified `tagMismatch`.

**The bound over the configured range** (`r3_tagwidth.out`; candidates/s = v × (R × 5 + U × 3), v the tag inputs
tried per count, acceptance a Poisson process at candidates × 2^−w):

| Width | Budgets R, U (frames/s) | v = 1 | v = 2 (U7 bit) | v = 4 (U7 and identity bits) | P(at least one acceptance in 24 h), v = 1 / 4 |
|---|---|---|---|---|---|
| 16 | 120, 240 (defaults) | 49.6 s | 24.8 s | 12.4 s | 1 / 1 |
| 32 | 120, 240 (defaults) | 37.7 days | 18.8 days | 9.4 days | 0.0262 / 0.101 |
| 32 | 1000, 1000 (range maxima) | 6.2 days | 3.1 days | 37.3 h | 0.149 / 0.475 |
| 64 | 1000, 1000 (range maxima) | 7.31e7 years | 3.65e7 years | 1.83e7 years | 3.75e−11 / 1.5e−10 |

At 32 bits and the defaults each acceptance comes after 1.17e9 `tagMismatch` occurrences (2^32 / (1320 / 360)
frames, `r3_tagwidth.out`). With per-player variants (GM M13), a failing frame also matches another variant's mask
by chance and is reported as `tagVariant` (dropped, not accepted): at 32 bits and the default budgets one per 37.7
days at N = 2, 14.3 h at N = 64, 3.5 h at N = 256 (`r3_tagwidth.out`, matching GM M13's figures); at 64 bits one
per 1.74e6 years at N = 256. Each such chance fact arrives beside 360 failing frames/s × 3.5 h = 4.5e6
`tagMismatch` occurrences from the same player (derived), while a carried mask matches on every frame (GM M13), so
the evidence already separates the two.

**Cost of 64 bits** (**measured**, `security-costs/tag_cover.out`, RESULTS claims 8 and 11c): HalfSipHash-1-3 with
a 64-bit output costs +3–10% at ≥ 1 KB and +16–39% at ≤ 64 B (fixed +25–40 ns native, +0.3–0.4 µs interpreted),
on every upstream frame and each of up to 5 retries of a failing one (10 with U7's bit). Wire (derived,
`r3_tagwidth.out`): 4 B more per upstream frame, 514 → 794 B/s at the busy model's 70 frames/s. G4, G5 and G8
gain 4 B each, a change to seed-0 golden frames that the fixed constraints exclude; the outcome below does not
rest on that.

**Forms considered.**

| Width rule | Keyless acceptance (worst configured, v = 4) | Chance `tagVariant`, N = 256 | Bytes, busy model | Verdict |
|---|---|---|---|---|
| 32 bits always (today) | one per 37.3 h | one per 3.5 h, beside 4.5e6 `tagMismatch` | 514 B/s | kept |
| 64 bits always | one per 1.83e7 years | one per 1.74e6 years | 794 B/s | refused |
| 64 bits when `build.playerVariants` ≥ 2, else 32 | as 32 or 64 | removed | 794 B/s with variants | refused |

U2 (CSC) does not bear on width: rotation amounts and `build.tagRounds` (a 3.6 input, `design/v5-3.6-inputs.md`
§1; not in `v5.md`, whose §4.9 keeps rounds a constant per R30) change the cost per byte and who must re-derive
the function, not the keyless rate (CSC U2, "Keyless guessing … unchanged").

**Facts, options.** No new fact and no option (a width option would be one knob trading two triggers' rates,
acceptance and chance `tagVariant`, which the rules forbid). The 32-bit decision text in `v5.md` §4.5 should
state the bound as the formula above with its figures at the defaults and at the range maxima, for v = 1, 2 and 4.

**Draft claims corrected.** "About 18,000 `tagMismatch` facts/s": `v5.md` gives 18,000 per acceptance at 16 bits
(50 s × 360 frames/s), not per second; at 32 bits it is 1.17e9 per acceptance. "+4 B per upstream frame (busy
model: ~514 → ~654 B/s)": 4 B × 70 frames/s gives 794 B/s; 654 is a 2 B step. "`build.tagRounds` … remain the two
knobs": it is a research proposal, not a design option.

**Outcome: kept refused** (64 bits, in any rule); **the 32-bit default stands**, with its bound restated over
the configured range. Reason, not cost: an accepted keyless frame gives its tool nothing the **api** and **mem**
classes do not give the same client without guessing, 32 bits already keeps acceptance at one per 37.3 h or rarer
in the worst configuration with every failure reported, and the one chance fact 64 bits would remove arrives beside
millions of `tagMismatch` occurrences that identify it.

---

## R39. A per-frame transform hook

**Earlier reason and what it assumed.** `research/landscape.md` implication 14 asked for hooks at three points,
"per-frame transforms (compression or encryption experiments)" among them, compiled out when unused. The design
deleted per-message middleware with every hook but `validate` (CH R8 row: "Middleware deleted entirely rather than
restricted"), and `v5.md` §8 says "There is no middleware: rejection is `validate`, observation the observer,
transformation game code." No reason is recorded for the per-frame part (SR R39). The landscape assumed an unused
hook must cost nothing; nothing assumed what a used one would need.

**Measured cost of the slot** (RESULTS claim 12, `security-costs/frame_hook.out`, end of a flush per frame,
medians of 3 runs): none 29.2 ns interpreted / 11.6 ns native; a nil-checked table field, a nil-checked upvalue, or
a slot bound to an identity function and always called, all within ±2% of none (28.7–29.4 ns, 11.5–11.6 ns);
tagging the same 100 B frame 3.97 µs / 436 ns. A generated shard can also omit the slot. Cost is not a reason.

**What a frame transform would carry, use by use.**
- *Compression.* The engine compresses remote payloads (CS §3.7; threshold and level unmeasured, `v5.md` §4.3,
  §10). v5's bit section has nothing left for zstd: replacing it with a keystream changes compressed sizes by 0% in
  every traffic model (`security-costs/mask_bytes.out`, R2 above). What compresses is large strings in the tail
  (600 B and 3,240 B of names: 508 B and 398 B after zstd, same file), and a game that knows such a field's content
  compresses it per field with `t.custom` or `t.convert` (`v5.md` §8), where the planner still bounds its size.
- *Encryption or masking.* R2 above: it hides nothing from the recipient and adds no work for a byte reader;
  keeping a value from the client is R34's sealed delivery.
- *Experiments.* The `transport` seam already passes every frame through replaceable code. Its interface
  (`design/m2-plan.md` §2): `send(player, lane, frame, instances)`, `broadcast(lane, frame, instances)` (the
  `FireAllClients` call) and `onReceive(handler)` with "raw remote arguments"; `v5.md` §8 lists it among the
  runtime seams, bound to Lync's default when nothing is registered. A game that wraps it transforms whole frames
  today: the tag is computed over Lync's frame before `send`, one `broadcast` stays one call, and Lync's frames,
  golden vectors, schema hash and types are unchanged.

**What a Lync-owned hook would add over a wrapped transport, and why that does not justify it.** Two orderings:
(1) the server could charge the frame budgets on the received bytes before calling the inverse and refuse an
inverse whose output passes the frame limits (rule 8), whereas a wrapped `onReceive` runs game code on raw remote
arguments before Lync's shape and budget checks (`v5.md` §6.1 steps 1–2); (2) the pair could be named in `HELLO` so
that a client and server with different transforms got `MISMATCH`. Both serve only a transform someone needs, and
no use above needs one: compression is the engine's and `t.custom`'s, concealment is R34's, and experiments have
the seam. A second per-frame path beside the transport seam is a second way to do one thing (`v5.md` principle 4).

**Facts, options.** No new code or option. Two statements of fact belong in the `transport` seam's documentation,
because a wrapped transport is game code reaching Lync through its API, so its effects are causes on an unmodified
client (`v5.md` §1): a registered `onReceive` runs before shape and budget checks, so its own cost on raw input is
unbounded by Lync; and a client and server whose wrappers disagree produce `tagMismatch` (reliable) and `malformed`
or `tagMismatch` (unreliable) on every frame, which belongs in those facts' known causes beside "a Lync bug".

**Draft claims corrected.** The draft called R34 "already adopted as a milestone-7 extension"; RR1 recommends it
and 3.6 lists it (`design/v5-3.6-inputs.md` §1), and the author asked that nothing be deferred to a milestone. It
said a used transform "reopens … the 16,384 B / 1000 B split logic" and "breaks encode-once when per-player"; a
transform applied at the transport boundary sits after splitting and tagging, and per-player keys are excluded by
R2, so neither holds for the only placement the design offers.

**Outcome: kept refused.** Reason, not cost (an unused slot is within noise, measured): no use needs it, since
compression is done by the engine and per field by `t.custom`, concealment from the recipient is R34's, and whole-
frame experiments already have the `transport` seam, whose ordering and mismatch effects are to be stated in its
documentation and in `tagMismatch`'s and `malformed`'s known causes.

---

## Implications

1. Keep downstream tags refused in every form: per-recipient tags end `FireAllClients`, a shared key is held by
   every injecting client, and a frame number changes seed-0 golden frames (R1, forms table).
2. Replace R1's recorded reason: the transport's integrity is reported (AEAD, third-party analysis), not
   documented, and the design already treats client-stated counts as facts (R1, "Who can write").
3. Add the listener origin check: `debug.info(2, "f")` first in the function passed to `OnClientEvent:Connect`,
   counter `injectedFrames`, `REPORT` field `injectedFrames:EG0`, fact `reportedInjectedFrames` (R1, form (d)).
4. Before release, check in Studio that every engine delivery, queued ones included, under both
   `SignalBehavior` values, finds nothing below the listener; remove the check if one does (R1, "Unverified").
5. Record that the queue before `Connect` is documented ("Roblox queues it and delivers it, in order, as soon as
   a handler connects"), which answers one `v5.md` §10 pending item for `RemoteEvent` (R1, fact table).
6. Keep masking refused on protection, and replace CH 3.5's cost line with 0 B for v5 bit sections and typical
   tails, +34% to +734% only for large compressible tails (R2, `mask_bytes.out`).
7. State the CPU figures for any keystream as measured: 2.88–7.09x the tag in counter mode, 0.54–0.83x seeded once
   per frame (R2, `mask_cpu.out`).
8. Keep masking and sealed delivery separate in the design: concealment from the recipient is only R34's (R2,
   "Consistency with R34").
9. Keep R21 refused with the equivalence as its reason, replacing "a client-stated time can't be trusted" in
   `v5.md` §5.4 (R21, derivation, `r3_limit.out`).
10. Add the stall length to `overLimit`'s known cause: a client firing at its limit trips it after a stall longer
    than 2 s + `burst` / `perSecond` (R21, "Facts").
11. Keep the 32-bit tag; refuse 64 bits always and 64 bits with variants (R28, forms table).
12. Restate `v5.md` §4.5's width decision as the formula v × (R × 5 + U × 3) × 2^−32 with figures at the defaults
    and range maxima for v = 1, 2, 4: 37.7 days down to 37.3 h (R28, bound table, `r3_tagwidth.out`).
13. Correct the busy-model framing for any wider tag to 794 B/s at 64 bits, and the "18,000 facts" to per
    acceptance at 16 bits (R28, "Draft claims corrected").
14. Keep R39 refused; name the `transport` seam as the place for whole-frame transforms (R39, "Experiments").
15. Document that a registered `onReceive` runs before shape and budget checks, and add mismatched transport
    wrappers to `tagMismatch`'s and `malformed`'s known causes (R39, "Facts, options").
16. Record for all five that cost was not the reason: the adopted check costs at most 3.1 µs/s on a client, and
    each refusal rests on protection or equivalence (R1, R2, R21, R28, R39 outcomes).
