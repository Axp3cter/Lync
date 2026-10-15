# Five refused or kept items, re-judged on protection and measured cost (R26, R27, R32, R37, R38)

Researcher findings, 2026-10-15. Item numbers and recorded reasons are from `research/security-refusals.md`. Each
item gives the earlier reason and what it assumed, what the measure protects (capability classes of
`research/client-security.md` §1.2, routes of `design/v5-integrity.md` §1) and what it does not, a form in Lync's
terms, its measured cost, facts or counters it adds, options, and an outcome.

**Labels.** **verified**: I ran it or read the source. **documented**: official docs. **reported**: third party.
**unverified**: not checked. Design text is cited by file and section; it is the design's own statement, not a
platform fact.

**Probe.** `probes/refusals-rejudged/r2_costs.luau`, run by `probes/refusals-rejudged/r2_run.sh` with Luau 0.742
built from `.data/projects/luau` (`-O2` interpreted, the Roblox client case; `-O2 --codegen` native, the Roblox
server case when its scripts are native), 3 runs each, output `probes/refusals-rejudged/r2_costs.out`. It uses
the harness and generated-form HalfSipHash of `probes/security-costs/` (`harness.luau`, `hsip.luau`). The frame
builder reproduces golden vectors G4 (`a4 15 00 67 67 9e 09 c7 aa`) and G11 (`ea 0a`) before it builds anything
else, so the frame sizes below follow `design/v5.md` §4.1 and §4.6 exactly (**verified**). CLI timings are a
desktop Xeon at 2.1 GHz on a shared machine; they don't transfer exactly to Roblox clients or servers
(`probes/security-costs/RESULTS.md`, "Host and tools"). Engine costs (bytes and CPU per `FireServer` call) are
unmeasured here and in the design (`design/v5.md` §10).

**Rules applied.** Lync reports facts with exact triggers and evidence; it acts on nothing beyond dropping
malformed input. No thresholds below a drop budget, no tiers, no option covering several triggers; every default
derived or marked chosen.

**Assumed from other briefs.** U7 (`research/client-self-checks.md`, implication 7): the caller probe's source
result travels as a bit in the tag's lane byte, and `sourceUnlisted` leaves `REPORT`, which then holds `probes`,
`identitySucceeded`, `refusedFrames`. Where an item depends on this, it says so.

## Checklist

- [x] R26 `REPORT` forcing a frame
- [x] R27 `REKEY` more often than once per 60 s
- [x] R32 clients enforcing the element bucket
- [x] R37 a per-fit clock-rate counter
- [x] R38 a signal for calls per second above any plausible frame rate

## R26. `REPORT` forcing a frame

**Earlier reason** (`design/v5-changes.md` 3.5 table, "kept"; origin `reviews/v5-design-2-redundancy.md` #8):
"Forcing adds no protection: a patched Lync suppresses `REPORT` either way, and counts ride the next frame the
client sends." The cost cited was "about 5 B plus a call when forced", asserted. Review #8 was about something
else: `REPORT` sent for `probes` alone, up to 10 a second per unmodified client, carrying no fact. Its fix (send
only with a non-zero fact count) was adopted and is not in question here.

**What the reason assumed.** That `REPORT`'s value is judged against a client that patches Lync. It isn't: a
patched Lync zeroes every count, riding or forced, so that argument removes `REPORT` altogether, not only forcing.
The probe and the refused-frame count exist for tools that leave Lync unpatched: executor code calling Lync's API
(`require` of client modules, the API-driver route) and injectors of inbound frames (`getconnections`/`firesignal`).
Against those, whether the counts arrive depends on whether a later reliable frame is sent, which is what forcing
changes. **verified** (read `design/v5-integrity.md` §4, §5; `design/v5.md` §4.6, §5.1).

**The gap today** (each from the design text; **verified** by reading):
- Control messages travel only on the reliable lane (`design/v5.md` §4.6), and the client flushes only when data
  is pending (§5.1: "Nothing is done when nothing is pending"). A pending `REPORT` is not pending data
  (`design/v5-integrity.md` §4: "it never forces a frame").
- So `identitySucceeded` from a probed call to an unreliable definition waits for the game's next reliable send. A
  game whose client sends only unreliable messages (an input stream) never sends it.
- `refusedFrames` counts downstream frames; it is unrelated to upstream traffic and waits the same way.
- Counts pending when the player leaves are lost.
- With U7's bit, the source result rides the frame that holds the probed message on either lane, so the gap is
  left for `identitySucceeded` and `refusedFrames` only.

**What forcing protects.** Delivery of counts an unmodified Lync has already produced, against callers that don't
patch Lync: API drivers at identity 8 (every probe of a call they make), and inbound-frame injectors (each refused
frame). It changes when counts arrive, never what a client can state.

**What it does not protect.**
- *Reading and writing upvalues, stack and GC objects* and *hooking Lync*: counts zeroed before encode, as today.
- *Hooking `FireServer` or blocking at packet level*: a REPORT-only frame is distinctive (6–9 B, control type 5)
  and can be blocked whole. Blocking leaves a count gap, so the next reliable frame arrives as `frameGap`
  (`skipped` 1) with an exact trigger; if no reliable frame follows, nothing is observed. A riding `REPORT` can't
  be removed without the key (the tag covers it while it lies inside `tag.cover`), so riding is the stronger form
  where a frame is going anyway; forcing adds coverage where none is.
- *Dropping identity to 2* (`setthreadidentity`): the identity probe reads nothing, forced or not.

**Form.** Client behaviour only; no wire, hash, protocol-version or golden-vector change: a forced frame is an
ordinary tagged reliable frame holding one control chunk, which the server already decodes.
- After the connection's first `WELCOME`, a `REPORT` with a non-zero `identitySucceeded` or `refusedFrames` is
  pending reliable data for the flush rule of `design/v5.md` §5.1. The next flush (automatic, or `Lync.flush()`
  under either scheduler) sends a reliable frame holding it, with or without other data. `probes` alone still
  makes nothing pending.
- At most one `REPORT` per reliable frame, as now. When other reliable data is pending, `REPORT` rides that frame
  exactly as today, so a probed reliable call and its count still arrive in the same frame.
- A pending `REPORT` does not count toward `missedFlush` (its cause would be Lync's own control message, not game
  data waiting), and never enters the join hold (it exists only after the first `WELCOME`, because it is tagged).

**Bound, derived.** One reliable frame per flush already (§4.1), and the client flushes automatically at most 60
times a second (§4.9 runtime constant), so forcing adds at most 60 reliable frames a second, and only in flushes
where a count changed since the last `REPORT` and no other reliable data was pending. That stays under the default
`inbound.reliable.frames` of 120/s, burst 240 (§7.5). On an unmodified client on a live server, the documented
known causes are none for `reportedIdentity` (Studio command bar or plugin only) and a Lync bug for
`reportedRefusedFrames` (`design/v5-integrity.md` §10), so forced frames occur there only through those causes.

**Cost** (`r2_costs.out`; frame bytes **verified** against G4/G11, timings **verified** on the CLI):

| | REPORT fields 3 (U7) | REPORT fields 4 (today) |
|---|---|---|
| forced frame, tag included | 7 B (probes 1, identity 1); 6 B (refused 1); 8 B (refused 80); 9 B (probes 60, identity 60) | 10 B (probes, identity, sourceUnlisted 60 each) |
| client CPU, interpreted | tag over the frame 1.15–1.16 µs; encode 1.02–1.21 µs with the probe's general bit writer (an upper bound: it allocates a writer per frame and loops per EG0 bit count) | same order |
| server CPU, native | tag 68–73 ns, plus shape, budget and decode of one control row | same |
| engine | one `FireServer` call: CPU and bytes per call unmeasured (`design/v5.md` §10) | same |

Worst case at the bound: 60 frames/s × 9 B = 540 B/s up plus 60 engine calls a second, client CPU about 2.4 µs ×
60 = 0.14 ms/s interpreted on the CLI (excluding the engine call), and only while a count changes every flush (a
probed identity-8 caller firing every flush at `callerProbe.maxPerSecond` 60, or every downstream frame refused).
The review's "about 5 B" is close for a riding chunk; a forced frame is 6–9 B.

**Alternative for the identity count.** U7 notes the identity result could fold into the tag as a second bit, as
the source bit does. That covers unreliable frames with per-frame evidence and zero bytes, but multiplies keyless
acceptance by 4 over today (one acceptance per about 9.5 days at full budgets, from 38) and failing frames cost up
to 4 PRFs per candidate count. It can't carry `refusedFrames`, which has no upstream frame of its own, so forcing
is needed for that count either way. The choice of a second bit belongs to U7's decision.

**Facts.** None added or changed. `reportedIdentity` and `reportedRefusedFrames` keep their triggers, evidence and
known causes; they arrive within one flush of the count changing, instead of at the next reliable send.

**Options.** None. The bound is a function of existing constants (one reliable frame per flush, 60 automatic
flushes a second); no game has a reason to delay its own counts.

**Outcome: adopt,** as client behaviour (`REPORT` with a non-zero fact count is pending reliable data). The kept
reason fails on its own terms: it would equally remove `REPORT`, and the measure's audience is tools that don't
patch Lync.

## R27. `REKEY` more often than once per 60 s

**Earlier reason** (`design/v5-changes.md` 3.5 table, "kept"; `design/v5.md` §4.5, §4.9 "rekey interval … chosen,
unmeasured: bounds `REKEY` traffic to a client whose frames keep failing"; `research/client-security.md` §3.1,
knob `rekeyInterval` 10–600 s, default 60): "A rekey restores a desynced client; more frequent rekeys add no
protection, since the key is already per session."

**What the reason assumed.** That the interval is a protection setting. Two different things were folded into it:
- **Recovery spacing** (what §4.5 specifies): after `desync`, `REKEY` is sent unless one went to this player in the
  last 60 s. That is an availability rule for an unmodified client, and its cost falls on that client.
- **Scheduled rekeying** (rekeys with no desync, to make a key holder re-read the key): a protection question.

**Recovery spacing: what 60 s costs an unmodified client.** The documented cause of `desync` on an unmodified
client is `FireServer` raising on 5 or more consecutive frames, "after which every later frame fails until
`REKEY`" (`design/v5.md` §7.3, `tagMismatch` row). If that cause recurs within 60 s of a `REKEY`, every reliable
frame of that client is dropped (`tagMismatch`) until 60 s have passed since the previous `REKEY`: events lost and
requests timing out for up to 60 s. Whether `FireServer` raises on Lync's arguments is unmeasured (§10), so how
often this happens is unknown; the rule's cost when it does is up to 60 s of reliable-lane loss. **verified** by
reading.

**Recovery spacing: what a shorter rule costs.** Only the player whose own frames fail can cause a `desync` for
its connection, so every `REKEY` goes to the player that triggered it. Per `REKEY`: one control row of 68 bits;
a `REKEY`-only downstream frame is 10 B (`ea 0b 10 20 30 40 50 60 70 00` for the golden key, `r2_costs.out`,
**verified**), and 9 B when it rides a frame already going; two draws from the server's `Random`
(engine CPU unmeasured); one more key held while pending. While a `REKEY` is pending, each failing reliable frame
costs up to 10 PRFs instead of 5 (`design/v5.md` §4.5); a modified client that never sends `REKEY-ACK` keeps that
state under the 60 s rule too, so this cost doesn't depend on the spacing.

**Form: one pending `REKEY` instead of a 60 s spacing.**
- A `desync` sends `REKEY` when no `REKEY` to this player is pending; while one is pending it sends none. A
  `REKEY` is pending from its send until the first frame that matches its key (which carries `REKEY-ACK`, §4.5).
  The runtime constant "at most one `REKEY` per 60 s" is removed.
- **Bound, derived.** Each `REKEY` after the first needs a `REKEY-ACK` frame and then 8 consecutive failing
  frames: at least 9 reliable frames per cycle. At the default `inbound.reliable.frames` (120/s, burst 240) that is
  at most 120 / 9 = 13.3 `REKEY` a second sustained and 26 from the burst, about 120 B/s downstream to that one
  player. Under the 60 s rule the same player gets 0.15 B/s. Every byte goes to the player whose frames failed.
- **Recovery, derived.** An unmodified client is rekeyed one `desync` after each episode: 8 failing frames (0.13 s
  when the client sends 60 reliable frames a second), plus one round trip, against up to 60 s today.
- `desync` evidence: `rekeySent` 1 when this occurrence sent `REKEY`, 0 when one was pending; `sinceRekey`
  unchanged. Trigger and known causes unchanged. A new evidence field `pendingFor` (seconds since the pending
  `REKEY` was sent, read before this occurrence's action; −1 if none was pending) states what `rekeySent` 0 now means.
- No wire, hash or golden-vector change; `REKEY` and `REKEY-ACK` keep their rows.

**A defect this depends on (found here, not in the design).** The client "puts `REKEY-ACK` in its next reliable
frame" (§4.5). If that frame's `FireServer` raises, which is the documented cause of the `desync` being repaired,
the acknowledgement is lost; the client's following frames match the new key without `REKEY-ACK`, which is rule 7
(`malformed`), so every later reliable frame is dropped. Under the 60 s rule the server can't send another
`REKEY` while that state lasts either, since the frames are malformed, not tag failures, and no `desync` follows.
Fix: the client puts `REKEY-ACK` in each reliable frame until one carrying it is passed to `FireServer` without
raising. This assumes a raising `FireServer` sent nothing, the same engine fact §4.5's count rule leans on
(unverified, §10). If a raising call can still deliver, a second `REKEY-ACK` arrives with none pending (rule 7,
one frame dropped); the design would then need the server to ignore a `REKEY-ACK` that repeats the last one.

**Scheduled rekeying (no desync).** What it would price: tools that read the key once and then forge, without
following Lync's key switch. Every capability that produces a valid tag either calls Lync (API drivers, hooks
above the encoder, which tag with whatever key Lync holds) or reads the key from Lync's state (*reading upvalues,
stack and GC objects*). A `REKEY` writes the new key into that same state, so a reader that reads at each send,
or hooks the switch, does no extra work; the change to such a tool is written once and works in every Lync game.
Packet-level senders (`raknet.send`) run inside an executor that also has those reads. External memory tools have
no send path of their own in `client-security.md` §1.4 (A8). So scheduled rekeying prices no capability class.
Its cost (10 B, two draws and a `REKEY-ACK` per rekey, per player) is not the reason. If a per-`REKEY` layout
re-pick is adopted (`research/generation-methods.md`, the nonce in `REKEY`), scheduled rekeying becomes a way to
vary layout within a session; that is a separate measure and is judged there.

**Facts.** `desync`, with the changed action and evidence:

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `desync` | 8 consecutive tag failures with no accepted frame between them (unchanged) | `REKEY` unless one to this player is pending | `sinceRekey` (s since the last `REKEY` to this player, −1 if none), `rekeySent` (1 sent, 0 one was pending), `pendingFor` (s since the pending `REKEY` was sent, read before this occurrence's action; −1 if none was pending) | the `tagMismatch` causes, 8 frames in a row (unchanged) |

**Options.** None: the bound follows from `inbound.reliable.frames`, which the game already sets.

**Outcome: adopt narrowed.** Replace the 60 s spacing with "one pending `REKEY` per player", plus the
`REKEY-ACK` repeat fix. Scheduled rekeying stays refused because no capability that holds the key loses it at a
switch, not because of cost.

## R32. Clients enforcing the element bucket

**Earlier reason** (`design/v5-changes.md` B1 of the milestone-1 code review; `design/v5.md` §4.8): "Clients don't
enforce the bucket, because they trust the server and its column compression must not be refused." Clients keep
a fixed per-frame allowance of 2^22 (4,194,304) elements, and the server splits a downstream frame before that
count (§4.1), so an unmodified server never writes a frame a client refuses by rule 10.

**What the reason assumed.** "Trust the server" reads as a policy choice; the underlying facts are two, and both
hold:
- **Who can write a client's downstream.** The game's own server, through the engine's transport. The other
  route is local: an executor on that client firing Lync's listener (`getconnections`/`firesignal`,
  `client-security.md` §1.2), which affects only its own view and is already counted as `refusedFrames` when
  non-canonical (`design/v5-integrity.md` §5). The 3.5 re-judgment of downstream tags rests on the same fact
  (`design/v5-changes.md`, R1 row). No player can address another client's decoder.
- **What a refusal does downstream.** Refusing a reliable frame loses its events, answers and collection writes;
  there is no resend request, so the client diverges from the server for the rest of the session. On the server,
  refusing a frame drops one player's input; on the client it breaks state.

**What enforcement would protect, by producer.**
- *The game's own server* sending heavy but canonical frames, including relays: the server rebroadcasting what
  players send, where each sender is held to `inbound.elements` (20,000/s, burst 65,536) but the rebroadcast
  reaches every client. A client bucket would turn that load into refused reliable frames and divergence, which
  is worse for the client than the decode time.
- *An executor injecting frames into its own client*: protects a modified client from itself.
- No capability class reaches another player's client decoder, so enforcement prices no tampering.

**What the allowance does bound, measured.** The per-frame allowance bounds counts, not time. Client decode per
element, interpreted (`r2_costs.out`, section D; CLI, so devices are slower by an unmeasured factor):

| Element kind (cheapest forms) | per element, interpreted | per element, native | one frame at 2^22 elements, interpreted |
|---|---|---|---|
| `false` in a bool column | 13.7–15.6 ns | 5.8–7.9 ns | 57–65 ms |
| an empty record (one table each), memory reclaimed between rounds | 41.7–45.2 ns | 33.9–34.9 ns | 175–190 ms |
| nested empty tables kept live, 4,194,240 of them (`reviews/m1-code.md` B1, `probes/review-m1/p2_amplification.luau`) | — | — | 2.1–2.7 s, 384 MB heap (mode not stated there) |

So one canonical frame from the game's own server can hold a client for tenths of a second to seconds;
`design/v5.md` §4.8's "can't hang a client" holds for counts near 2^53, not for 2^22. The charge itself (a
subtraction and a comparison per count) is 3.1–3.4 ns native and about 13 ns interpreted per count in the probe's
loop; cost is not the reason either way.

**A form for the real concern.** The concern behind the item is decode work the game's own server imposes on its
clients. That is the game's output, so the useful fact is how much it sends, counted where it is exact:
- **Counter `elementsSent`**, per definition, server side (with `player`: that player's total), beside
  `messagesSent` and `bytesSent` (`design/v5.md` §7.4). It counts elements by §4.8's definition (one per message of
  a run, array element or map pair) in frames sent. The encoder already counts elements per frame to split before
  2^22 (§4.1), so the count exists; it is added per message to the definition's counter, and to each recipient's
  per-player total as `messagesSent` is. Measured cost of one counter increment in the probe's form: 8.1–8.7 ns
  native over the loop baseline (section C, `framesReceived` row, the same operation).
- No fact: there is no trigger an unmodified server's output can be compared with, other than the 2^22 split that
  already exists.
- The inbound counterpart (`elementsReceived`, from the server's bucket charges) is the same counter on the other
  direction; whether to add it is a counters decision outside this item.

**Facts.** None. **Options.** None.

**Outcome: kept refused** (client enforcement), on protection and correctness, not cost: no party but the game's
own server writes a client's downstream, and a client-side refusal of a reliable frame loses state with no
recovery. Proposed in its place: the `elementsSent` counter, and correcting §4.8's "can't hang a client" to the
measured bound per frame.

## R38. A signal for calls per second above any plausible frame rate

R38 comes before R37 here because it doesn't depend on `research/clock-facts.md`.

**Earlier reason** (`design/v5-changes.md` draft-2 table, "covered"; origin `research/client-security.md` §4 T2):
"The inbound frame budget reports the same fact as `overBudget` with an exact trigger." The research's signal was
"> 250 `r` calls/s sustained 10 s: reported with weight 0 (information), because fps unlockers and manual flushes
are honest", on the premise that "an honest Lync client flushes once per client frame" at up to 240 Hz.

**What the reason assumed, checked.**
- *The premise is gone.* v5 caps automatic flushes at one per 1/60 s of accumulated time whatever the frame rate
  (`design/v5.md` §5.1, review-2 M1: "a 240 FPS client sends at 60 Hz"). A client's frame rate no longer follows
  its render rate, so "any plausible frame rate" names nothing in v5.
- *What an unmodified client sends, per lane* (derived from §4.1, §5.1): reliable, at most one frame per flush, so
  at most 60 a second from automatic flushes plus one per `Lync.flush()` call, which game code makes as often as it
  chooses; unreliable, one frame per 960 B of unreliable chunk data per flush, plus ack-only frames (at most one
  per flush). Only the 60 automatic flushes are Lync's own; everything above them is game code's choice.
- *"The same fact".* `overFrameBudget` fires when a lane's bucket (`inbound.<lane>.frames`, default 120/s burst 240
  reliable, 240/s burst 480 unreliable) is below 1 token, and drops the frame. It reports rates above the budget
  only. Below the budget, nothing reports the rate, and no counter holds it: `Lync.counters` has messages and bytes
  per definition, facts per reason, and no frame counts (§7.4). **verified** by reading.

**What a rate readout protects.** Frames sent outside Lync's flush cadence that stay under the budget: a forger
holding the key (the extractor route) sending its own frames between Lync's, a replayer of reliable frames that
fail the tag (already `tagMismatch`), and a client whose automatic flush runs on an accelerated clock, which sends
up to 60 × r frames a second at clock rate r while it has data every flush. Whether the 1/60 s accumulation is
measured on a clock that speed tools accelerate is unverified; the beacon (`clockRate`) is the direct measure of
that route. Of these, Lync can't separate any from game code calling `Lync.flush()`; the game can, because it
knows how often its own client code flushes.

**What it does not protect.** API drivers and hooks above the encoder: their messages ride Lync's own flushes, so
the frame rate doesn't change. Raw senders without the key: every frame fails the tag, already reported.

**Why no fact.** A fact needs a trigger an unmodified client meets only through listed causes. The only rate Lync
derives is 60 automatic reliable flushes a second; `Lync.flush()` adds an unbounded game-chosen rate on top, which
is why `inbound.reliable.frames` is an option rather than a constant (`design/v5-changes.md` S7, "since
`Lync.flush()` makes a client's frame rate the game's choice"). A second, report-only threshold under the drop
budget would be a second trigger on the quantity the budget already triggers on, set by a second option: a tier.

**Form: a per-lane frame counter.**
- **`framesReceived.reliable`, `framesReceived.unreliable`** (server; with `player`, that player's; without, the
  server's total): frames that passed §6.1 step 1 (shape), counted before the budgets, so it counts arrivals
  including frames later dropped. With `facts.overFrameBudget`, `facts.tagMismatch` and the others it gives the
  game every quantity it needs for its own rate test, against its own knowledge of its `Lync.flush()` use.
- The counter-naming rule of §7.4 (a field and a qualifier after the first dot) already covers the form.
  `framesSent` per lane, the same pair as `messagesSent`/`messagesReceived`, would complete the set on both
  sides; it isn't needed for this item.
- Cost (`r2_costs.out`, section C): one increment per arriving frame, 8.1–8.7 ns native over the loop baseline
  (26–43 ns interpreted, irrelevant on the server); two numbers per player; a per-player snapshot carrying this and
  R37's two fields measured 0.89–1.25 µs native against 0.71–0.83 µs without (the probe puts the lane pair in a
  frozen subtable, one allocation per snapshot).
- At 100 players and the busy model's 70 upstream frames a second each (`design/v5.md` §4.1), 7,000 increments a
  second: about 60 µs/s native.

**Facts.** None. **Options.** None.

**Outcome: adopt narrowed:** the per-lane `framesReceived` counter, no fact. The fact stays refused because its
premise (frame rate tied to render rate) doesn't hold in v5 and any threshold under the drop budget is a tier, not
because of cost.

## R37. A per-fit clock-rate counter

**State of U3/U4.** `research/clock-facts.md` does not exist: its agent was stopped by the author with partial
files kept (`agents.md`, unit 9). Only its probes exist (`probes/clock-facts/common_mode_sim.luau`, `cost.luau`,
`roundtrip_sim.luau` and outputs), unreviewed. This item uses the estimator as `design/v5-integrity.md` §6 defines
it and defines nothing about windows, epochs or a server-wide correction; where U3's outcome changes the form, it
says how.

**Earlier reason** (`design/v5-changes.md` draft-3 #12; origin `reviews/simplifications.md` #12, option a): "Option
(a)'s per-fit counter is not added: the option at 0.001 already gives the game nearly every fit, and two ways to
read slopes would break principle 4."

**What the reason assumed, checked against the design text** (**verified** by reading `design/v5.md` §7.3 and
`design/v5-integrity.md` §6, §10):
- *"Nearly every fit".* At `clock.reportSlope` 0.001 (its minimum) and `clock.reportFits` 1, the fact fires for
  fits with slope above 0.001 only. Fits at or below 0.001, and every negative slope (a slow client clock), are
  never visible. The design's own noise estimate for an unmodified client is 0.0003–0.0008 (0.03–0.08% at
  σ = 20–50 ms), so the unmodified population sits mostly below the minimum, and the game can't see the
  distribution it would need to set `reportSlope` from its own players; noise and slew on devices are unmeasured
  (`design/v5.md` §10). U3's partial simulation agrees in kind: the median slope across 100 simulated unmodified
  players stays within ±0.0004 in its jitter scenarios (`probes/clock-facts/common_mode_sim.out`, unreviewed).
- *Coalescing.* Facts coalesce per (player, reason) over `observe.window` (default 30 s): the first occurrence is
  delivered at once, then one fact at close with the count and the last occurrence's evidence. Fits run every 5 s,
  so the game receives the slopes of 2 of each window's 6 fits. Each also takes one of the player's
  `observe.perPlayerEvents` (16) keys and prints console lines (up to 2 per code per window).
- *Principle 4.* The design already reads every fact two ways by rule ("one record, three outputs": each
  occurrence also increments `facts.<reason>`, §7.3), and `Lync.counters` already holds a level, `heldBytes`,
  beside counts. A measurement (the last slope) and an event (a threshold crossed for a run of fits) are not one
  thing done two ways.

**What it protects.** Nothing new is detected: the fit is the same. It moves the threshold decision to the game
with the data to make it: the slope of every fit, both signs, below any threshold, uncoalesced. That serves timing
tools (clock-accelerating and clock-slowing tools, `design/v5-integrity.md` §1) only through the game's own policy.

**What it does not protect.** Clients that keep Lync's stamps on unaccelerated time (the measure's documented
limit, §6), patched stamps, and clients that send no reliable frames (no beacons, so no fits; beacons never force
a frame, §6, the same delivery gap R26 closes for `REPORT`, which this item does not decide).

**Form: three per-player counters, server only, from values the fit already computes.**

| Counter | Kind | Meaning |
|---|---|---|
| `clockFits` | count | fits computed for the player since join |
| `clockRestarts` | count | estimator restarts (an arrival gap over 3 × `clock.beacon`, §6) since join |
| `clockSlope` | level, number | the slope of the player's most recent fit since the last restart, the same quantity and sign as `clockRate`'s evidence `slope`; absent before the first fit and from a restart until the next fit |

- Without `player`, `clockFits` and `clockRestarts` are server totals and `clockSlope` is absent: a level has no
  server-wide sum.
- A game reading `Lync.counters(player)` at least once per fit interval (5 s) sees every fit; reading less often,
  it sees `clockFits` advance by k and the last slope, so a missed fit is counted, never hidden.
- If U3 adopts a server-wide correction (subtracting an epoch median from each fit before the test, as its probe
  simulates), `clockSlope` stays the uncorrected slope, and the correction term is exposed once per server beside
  it, so the game sees what the correction removed. U3's probe shows why that matters: with its guard rule, two of
  three players at +5% produce no fact (`common_mode_sim.out`, "3 players, two fast at +5%"), while their raw
  slopes are 0.05.
- `clock.reportSlope` and `clock.reportFits` stay; the fact keeps its trigger.

**Cost** (`r2_costs.out`, section C; the probe stores a count and a number per fit). Per fit, 7.4–8.1 ns native
over the loop baseline (32–45 ns interpreted). At one fit per 5 s per player and 100 players, 20 fits a second:
about 0.16 µs/s native. Memory: three numbers per player. A per-player snapshot carrying these and R38's pair
measured 0.89–1.25 µs native against 0.71–0.83 µs without; a game polling 100 players every 5 s spends about
25 µs/s native on snapshots. No bytes: server-only. The fit itself is unchanged (≤ 6 µs per fit,
`probes/security-costs/RESULTS.md` claim 9).

**Facts.** None added; `clockRate` unchanged.

**Options.** None.

**Outcome: adopt,** as `clockFits`, `clockRestarts` and `clockSlope` per player. The refusal's first premise
doesn't hold at the option's minimum (sub-threshold and negative slopes never reach the game, and coalescing
delivers 2 of 6 fits per window), and its second treats a measurement and an event as one thing.

## Implications

1. **Make a `REPORT` with a non-zero `identitySucceeded` or `refusedFrames` pending reliable data** for §5.1's flush
   rule, excluded from `missedFlush`; no wire change, ≤ 60 frames/s of 6–9 B only while a count changes (R26, form
   and bound).
2. **Judge client-stated measures against the tools they target, not a patched Lync:** `REPORT` serves tools that
   leave Lync unpatched, so "a patched Lync suppresses it" is no reason about delivery (R26, what the reason
   assumed).
3. **Replace the 60 s `REKEY` spacing with "one pending `REKEY` per player"** and add `pendingFor` to `desync`;
   bound ≤ 13.3 `REKEY`/s, about 120 B/s, only to the player whose frames fail (R27, form).
4. **Fix the lost `REKEY-ACK`:** the client repeats `REKEY-ACK` until a frame carrying it passes `FireServer`
   without raising; today one raising call leaves every later reliable frame `malformed` (R27, defect).
5. **Keep scheduled rekeying refused** on protection: every key holder reads the key where a switch writes it
   (R27, scheduled rekeying).
6. **Keep client enforcement of the element bucket refused,** and record the reason as producer and correctness
   (only the game's server writes downstream; a refused reliable frame diverges state), not trust (R32).
7. **Add the server counter `elementsSent`** per definition and per player, from the element count the encoder
   already keeps for the 2^22 split (R32, form).
8. **Correct §4.8's "can't hang a client"** to the measured bound: one 2^22-element frame is 57–190 ms interpreted
   on the CLI for flat elements and 2.1–2.7 s for 4.2 M live tables (R32, measured table).
9. **Add `framesReceived.reliable` and `framesReceived.unreliable`** (server, counted at §6.1 step 1); keep the
   rate fact refused: its 240 Hz premise is gone in v5 and a threshold under the budget is a tier (R38).
10. **Add `clockFits`, `clockRestarts` and `clockSlope`** per player, server only, about 8 ns native per fit
    (R37, form and cost).
11. **If U3 adopts a server-wide slope correction, expose the uncorrected `clockSlope` and the correction term**
    so the game sees what the correction removed (R37, form; `common_mode_sim.out`).
12. **Decide whether `BEACON` should be pending data like `REPORT`:** beacons never force a frame either, so a
    client with no reliable sends gets no fit; this item's evidence (R26) applies, the decision belongs to U3's
    successor (R37, what it does not protect).
