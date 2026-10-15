# Clock and timing facts: beacon window rules (U3), the `BEACON` frame gap, request timing (U4)

Researcher findings, 2026-10-15. Item numbers are from `research/security-refusals.md` §4. Builds on
`research/refusals-rejudged-2.md` R26 (forced `REPORT`) and R37 (`clockFits`, `clockRestarts`, `clockSlope`), and
on `research/server-facts.md` U10 (the path bound shared with `earlyAnswer`); neither is redefined here.

**Labels.** **verified**: I ran it or read the source. **documented**: official docs. **reported**: third party.
**simulated**: a probe's model, whose engine timings are assumptions (marked in each probe header); nothing in a
simulation is measured on Roblox. Design text is cited by file and section.

**Probes** (`probes/clock-facts/`, run by `run.sh` with Luau 0.742 built from `.data/projects/luau`; cost probes
3 runs `-O2` interpreted, the Roblox client case, and 3 runs `-O2 --codegen` native, the server case; CLI timings
on a shared 2.1 GHz Xeon do not transfer exactly to Roblox, `probes/security-costs/RESULTS.md` "Host and tools"):
- `beacon_sim.luau` → `beacon_sim.out`: the §6 estimator per player, 100 players × 3 seeds × 600 s per scenario,
  on `v5.md` §9's default network and one chosen "mobile" model; forced and riding beacons; steps, ramps, modified
  clocks; facts by threshold T, run length F and the split-half rule below.
- `step_response.luau` → `.out`: exact Theil–Sen response to one level shift (no noise).
- `common_mode_sim.luau` → `.out` (the earlier agent's, re-run unchanged): guard, discard and literal window rules.
- `beacon_cost.luau` → `.out`: frame bytes (G4 reproduced first), client and server CPU; `cost.luau` → `.out`
  (re-run): epoch median, guard test, result fields.
- `roundtrip_sim.luau` → `.out`: `roundTrip` of unmodified clients, extended with a latency-drop case.
- `result_types.luau`, `result_types_ts.ts` → `result_types.out`: the result type under both Luau solvers
  (luau-analyze 0.740) and `tsc` 6.0.2 `--strict`.

**Platform facts used** (creator-docs, `main`, read 2026-10-15; **documented**):
- `Workspace:GetServerTimeNow()`: summary "Returns the server's Unix time in seconds"; on a client "the client's
  best approximation of the current time on the server", smoothed so that "It is monotonic" and "It moves at the
  same rate as the local clock to within 0.6%"
  ([Workspace.yaml](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/Workspace.yaml)).
- `os.clock()`: "elapsed time in seconds since an arbitrary baseline with sub-microsecond precision";
  "adjustments to the system clock (such as by the user or NTP) do not cause time to jump"
  ([os.yaml](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/libraries/os.yaml)).
- `Player:GetNetworkPing()`: "the round-trip, isolated network latency of the player in seconds … It doesn't
  involve data deserialization or processing"; on a client, callable only on `LocalPlayer`
  ([Player.yaml](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/Player.yaml)).
  The API dump types it `-> float` (32-bit), security None (**verified**, `api Player.GetNetworkPing`, Roblox
  0.741.19 dump).

## Checklist

- [x] U3. Clock beacon window rules, slow clocks
- [x] The `BEACON` frame gap
- [x] U4. `roundTrip` and `ping` on server request results
- [x] Implications

## U3. Clock beacon window rules, slow clocks

**The research's proposal** (`research/client-security.md` §4 T1, false-positive table): "Server hitch: all players
shift at once … if more than half the players' windows move the same way, discard that window for everyone";
"only *fast* clocks (positive slope) weigh; slow ones are reported weight 0". Weights are out (no verdicts); what
remains is a numeric rule for "together" and a report of both signs.

### U3.1 What the fit measures, and what moves it

Per beacon the server records o = arrival − stamp = one-way delay + client clock error + constant. The fit's slope
is therefore d(clock error)/dt **plus d(lower envelope of one-way delay)/dt** (**verified** by reading §6 and by
simulation). The design's known causes cover only the first term. Measured in `beacon_sim.out` (forced beacons,
`clock.beacon` 10 unless stated; |s| over every fit of 300 unmodified players):

| Source | Scenario | \|s\| p99 | \|s\| max |
|---|---|---|---|
| network and 1 ms stamp rounding only | A0 default network; A0m mobile, P 1.5 s | 0.00001; 0.00056 | 0.00035; 0.00146 |
| clock correction episodes at ≤ 0.6% | A1–A5 (P 0.5, 1.0, 1.5 s; both networks) | 0.00238–0.00253 | 0.00350–0.00400 |
| sustained 0.6% slew (the documented bound) | A6 default; A7 mobile | 0.00622; 0.00647 | 0.00636; 0.00691 |
| server hitch 2 s or 10 s | `common_mode_sim.out` | — | 0 facts with no rule at all |

- **A hitch is not a slope.** Window minima ignore beacons delayed by a hitch shorter than a window, and a hitch
  over 3 × `clock.beacon` restarts every estimator. The research's stated cause produces no fact (**simulated**).
- **A level shift is a slope, to Theil–Sen over 12 points** (`step_response.out`, **verified**). A shift of h
  seconds between windows k and k + 1 straddles k(12 − k) of the 66 pairs; for k = 5, 6, 7 (35, 36, 35 pairs) the
  33rd and 34th order statistics are straddling pairs, giving slope h/50, h/47.4, h/50. So one persistent step of
  0.50 s (0.34 s at T 0.0068) yields three consecutive fits above T 0.01: exactly the default run of 3. The
  research's "Theil–Sen ignores a single step" holds only for k ≤ 4 or ≥ 8. Simulated, per player at random
  times: a step of +0.5 s for 120 s gave a fact for 188 of 300 unmodified players, +1.0 s and +2.0 s for 300 of
  300 (S2–S4). Raising `reportFits` to 4 or 5 leaves 2–4 of 300 on the default network but 52 and 42 of 300 on
  the mobile model (S6): noise lengthens the run.
- **A ramp is a slope** under any estimator: a queue that builds (o rises, s < 0) or drains (s > 0) steadily.

### U3.2 Rules, exactly

Changes to `design/v5-integrity.md` §6 and the beacon-estimator row of `v5.md` §4.9 (runtime constants, no wire
change):
1. **Arrival clock: server `os.clock()`** read at the decode of the frame holding the `BEACON` (the read `earlyAnswer`
   and U10 already make per inbound frame). Derivation: the 0.6% bound relates a client's stamps to its local
   clock, and `os.clock` is not adjusted by NTP (documented). The server's `GetServerTimeNow()` is its Unix time;
   any adjustment of that clock would enter every player's o at once, a common-mode term Lync would have created
   itself. With `os.clock`, a server-side time adjustment reaches the slope only through clients re-syncing at
   ≤ 0.6%, inside the bound.
2. **Stamp extension.** The first stamp of a connection (and after a restart) is extended to the value nearest
   ⌊1000 × server `GetServerTimeNow()`⌋; each later one to the value within ±32,768 ms of the previous extended
   stamp. Between beacons less than 3 × 1.5 s passes, so the extension is exact for any client rate below ×7; a
   modified clock's offset can grow past 32 s without wrapping the fit (**verified** by arithmetic).
3. **Windows on one server grid:** window index ⌊t / 5⌋ with t the arrival `os.clock()`; a fit for every player
   with 12 consecutive windows at each epoch boundary (t a multiple of 5 s). Every player's fits then share epochs,
   which is what "together" needs. With forced beacons (next section) and P ≤ 1.5 s, no window is empty without a
   restart, since 3P ≤ 4.5 s < 5 s.
4. **Sign:** s = −(Theil–Sen slope of o), in seconds of client-clock gain per second of server `os.clock()`;
   positive is a fast client clock, negative a slow one.
5. **Split-half test** (new): for a fit with |s| > `clock.reportSlope`, Lync also fits windows 1–6 and 7–12
   (Theil–Sen, 15 pairs each, the 8th order statistic). The fit **counts** when s, `firstHalf` and `secondHalf`
   all exceed `clock.reportSlope` in magnitude with s's sign. Derivation: one level shift lies inside one half,
   so the other half is flat; a rate (a modified clock, or a ramp) shows in both.
6. **Run:** consecutive counting fits of one sign. A non-counting fit, a sign change or a restart ends it.

Effect (`beacon_sim.out`, defaults T 0.01, F 3, split on): every single step S1–S6, on both networks, 0 of 300;
all A scenarios 0 of 300; modified clocks still found (+1%: 30 of 30, first fact p50 170 s, max 475 s, against
105 s and 285 s without the split; +1.2% on the mobile model p50 100 s, max 135 s; +2% and −2%: 30 of 30 at
100 s; +2% with 60 of 100 players modified: 180 of 180).

### U3.3 "Together" as a measured quantity, and why it is not in the trigger

- **Quantity:** `othersSlope` = the median of s over the other players whose fit completed at the same epoch
  (leave-one-out), and `others` = their count. 0 and 0 when no other player has a fit. Computed once per epoch by
  sorting the epoch's slopes; per fact by rank lookup.
- **What it separates** (`beacon_sim.out`, |slope − othersSlope| at first fact): a server-side inbound delay that
  builds over 30 s and drains over 90 s for every player (C4, hypothetical, nothing measured): p50 0.0005, max
  0.0030; the same uplink ramp per player at random times (C1r): p50 0.0155, max 0.0177. A majority running the
  same tool (D6, 60 of 100 at +2%): p50 0.0006, the same signature as the server-side cause.
- **The rules considered as trigger modifiers, refused:**
  - *Literal window rule* ("more than half the windows moved the same way", `common_mode_sim.out`): drops 71.5% to
    91.5% of windows for populations with no modified client and no common cause, because each window minimum
    moves up or down by chance. Unusable.
  - *Discard* (freeze runs at an epoch where more than half of ≥ 3 fits exceed T one way) and *guard* (test
    s − max(M, 0) > T and s − min(M, 0) < −T, M the epoch median of ≥ 3 fits): both remove the hypothetical
    server-wide drain (500 of 500 players with a fact without the rule, 0 with it). Both hide any majority: 55 of 100 at +5% gave 0 of
    275 modified players a fact; 3 players of whom 2 at +5% gave 0 of 10. Defeat class: several clients of one server applying the same
    clock change, which needs no capability beyond the single-client one. The fact would also stop being a
    statement about one player's own data.
  - Cost is not the reason: the guard test is 3.0–3.5 ns native per fit (`cost.out`).
- **Outcome:** report `othersSlope` and `others` as evidence and a server counter; leave the trigger on the
  player's own fit. R37's rule then applies with no correction to expose: `clockSlope` is the player's s.

### U3.4 Slow clocks

The same fact, with the sign in `slope`: one quantity (the client clock's rate against server `os.clock()`), one
code, one threshold on its magnitude. One threshold is derived, not merged: the documented bound (0.6%) and every
simulated unmodified source are symmetric in sign (A0–A7 above; ramps give both signs, building and draining).
`clockRate` narrows its evidence on `reason` alone, so a game that ignores slow clocks tests `slope < 0`. What a
slow clock prices: tools that slow the client clock (the design's route table lists accelerating only); the
measure's limit is the same (stamps kept on unmodified time defeat it).

### U3.5 The fact, as it should read in `design/v5-integrity.md` §10

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `clockRate` | at the end of a fit, the player's last `clock.reportFits` fits each had \|`slope`\| > `clock.reportSlope` with `firstHalf` and `secondHalf` beyond it with the same sign, all of one sign (§U3.2) | none | `slope` (s/s, signed, positive = client clock fast), `fits` (the run so far), `firstHalf`, `secondHalf` (s/s), `othersSlope` (s/s), `others` (fits), `drift` (s: o of the first window since the last restart minus o of this fit's last window, sign as `slope`) | a one-way delay whose lower envelope rises (`slope` < 0) or falls (> 0) by more than `reportSlope` s/s across both halves of `reportFits` fits, i.e. for at least 60 + 5 × (`reportFits` − 1) s: a queue building or draining on the client's uplink (other traffic on the link; multi-second queues are reported, [Gettys & Nichols 2011](https://queue.acm.org/detail.cfm?id=2071893)) or in the server's inbound processing (then `othersSlope` is within the fit noise of `slope`; unmeasured on Roblox). Simulated: a 1 s queue built over 60 s fires for 300 of 300 players, 0.5 s over 60 s for 0 at the default and 232 of 300 at `reportSlope` 0.0068. At `reportSlope` ≤ 0.0069 only: a clock correcting at the documented 0.6% bound plus fit noise (mobile model max 0.00691). Not causes (simulated): network jitter, one delay step of any size, hitches up to 10 s |

- `drift` bounds path causes: a queue can move o by at most its depth (C1r: p50 0.70 s, max 1.03 s at first fact),
  while a modified clock's `drift` grows with time (+2%: 1.37–1.50 s at the first fact, 0.02 s more per second
  after). Coalescing delivers the last occurrence's evidence at window close, so the game sees `drift` grow.
- **Default threshold.** Unchanged at 0.01: the largest unmodified |s| simulated is 0.00691 (A7), a margin of 1.45.
  Noise and slew on devices remain unmeasured (`v5.md` §10); this makes them simulated, not measured.
- **Counters** (R37's per-player `clockFits`, `clockRestarts`, `clockSlope` unchanged). Add, server only, without
  `player`: `clockSlopeMedian` (level, s/s: the median of every player's s at the latest epoch; absent when that
  epoch had no fit) and `clockSlopeFits` (level: that epoch's fit count).

### U3.6 Cost at 100 players (server, native unless stated)

| Item | Measured | At 100 players |
|---|---|---|
| per beacon: window minimum | 8.8 ns (`RESULTS.md` claim 9) | 100 beacons/s: 0.9 µs/s |
| per fit: 66-pair Theil–Sen | 1.52–1.59 µs here (`beacon_cost.out` C); 1.06–2.86 µs by form (claim 9) | 20 fits/s: ≤ 57 µs/s |
| per fit beyond T: two half fits | 0.56–0.60 µs (1.09–1.41 µs interpreted) | 0 in every unmodified scenario; ≤ 12 µs/s if every fit were beyond T |
| per epoch: sort the epoch's slopes | 1.72–2.10 µs net of setup, both modes (100 slopes) | one per 5 s: 0.34–0.42 µs/s |
| per fact: rank and leave-one-out median | ≤ 0.12 µs (≤ 0.23 µs interpreted; the probe allocates a closure) | per occurrence only |
| R37 counters | 7.4–8.1 ns per fit | 0.16 µs/s |

Total ≤ 71 µs/s at 100 players, 0.007% of a core. Memory: per player one more number (the first window's o, for
`drift`); per server one reused array of up to 100 slopes. No bytes.

## The `BEACON` frame gap

**Today** (`design/v5-integrity.md` §6, **verified** by reading): the client puts `BEACON` "in the first reliable
frame it sends once `clock.beacon` tenths of a second have passed … it never forces a frame". Control messages
travel only on the reliable lane (`v5.md` §4.6), and a client flushes only when data is pending (§5.1). R37 noted
the gap; R26 closed the same gap for `REPORT`.

### What happens to the fit (`beacon_sim.out` B1–B7, D4; `clock.beacon` 10 unless stated)

| Client's reliable sends (Poisson, per s) | Epochs with a fit | Restarts per player-hour |
|---|---|---|
| 0: sends only unreliable frames, or idle | 0% | — (one beacon, never a second) |
| 0.1 | 0% | 264 |
| 0.33 | 0% | 457 |
| 1 | 0.6% | 241 |
| 1, `clock.beacon` 15 | 25.6% | 72 |
| 3 | 89.2% | 6.8 |
| 10 | 100% | 0 |
| forced (below), any traffic | 100% | 0 on both network models |

- Derivation: a riding beacon leaves at the first reliable send after the period, so the gap is P + Exp(1/λ); it
  restarts the estimator when Exp(1/λ) > 2P, probability e^(−2Pλ) per beacon, and a fit needs every gap kept for
  90 s (30 s warm-up plus 12 windows). At λ = 1, P = 1 that is 13.5% per beacon against 45 beacons (90 s at 2 s each) to survive: no fit.
- A modified clock at +2% on a client sending 1 reliable message a second: 3 of 30 facts in 600 s, first at
  570 s (D4), against 30 of 30 at 100 s when forced (D2).
- So `clockRate` today covers only clients that send reliable data at 3 or more messages a second for 90 s.
  Input-only clients (unreliable streams), menu and idle clients, and games whose clients fire reliable events on
  clicks, are not measured, and `clockRestarts` counts their send pattern, not a clock.

### Form: a due `BEACON` is pending reliable data

Client behaviour only, as R26 for `REPORT`; no wire, hash, protocol-version or golden-vector change: the forced
frame is an ordinary tagged reliable frame with one control chunk, which the server already decodes.
- After the connection's first `WELCOME`, a `BEACON` is **due** once `clock.beacon` tenths of a second of
  `os.clock()` have passed since the last frame carrying one was passed to `FireServer` (for the first, since the
  first `WELCOME`). A due `BEACON` is pending reliable data for §5.1's flush rule.
- The next flush (automatic, or `Lync.flush()`) puts it in that flush's reliable frame, with other reliable data
  when there is some, alone otherwise. The stamp is read when the frame is encoded, not when it fell due.
- Like `REPORT` (R26): it never counts toward `missedFlush` and never enters the join hold. Under
  `Lync.scheduler("manual")` it waits for the game's next `Lync.flush()`: frames leave only then, so the gaps are
  the game's flush gaps and a custom tick slower than 3 × `clock.beacon` restarts the estimator (counted in
  `clockRestarts`).
- With R26 adopted, a due `BEACON` and a pending `REPORT` share one frame (9 B, below).

**Bound, derived.** One forced frame per period at most: 1 a second at the default `clock.beacon` 10, 2 a second
at its minimum 5, and only in flushes with no other reliable data. Against the default `inbound.reliable.frames`
(120/s, burst 240): at most 1.7% of the rate. With R26's bound (≤ 60 forced `REPORT` frames a second, only while a
count changes) both stay under 120/s, since a due `BEACON` rides any frame already forced.

**Cost** (`beacon_cost.out`; bytes **verified** against G4, CPU on the CLI):

| | Value |
|---|---|
| forced `BEACON`-only frame, tag included | 8 B (`b4 bf fb 02 f6 78 71 ca` for stamp `0xBEEF`, count 7, golden key); 11 B when the frame carries a full ack (`'1' seq received`); 9 B with a `REPORT` (probes 1, identity 1) |
| riding `BEACON` | +3 B on G4 (9 → 12 B): 20 bits of chunk plus 2 bits of toc, rounded to the byte |
| upstream, per idle player | ≤ 8 B/s at `clock.beacon` 10, ≤ 16 B/s at 5; ≤ 11 B/s while state frames flow; plus one `FireServer` call a second (engine bytes and CPU per call unmeasured, `v5.md` §10) |
| client CPU, interpreted | encode 0.61–0.63 µs (the probe's general bit writer, an upper bound) + tag 1.11–1.15 µs: ≤ 1.8 µs per forced frame, ≤ 1.8 µs/s at the default |
| server CPU, native | tag 0.11–0.12 µs per frame, plus shape, budget and decode of one control row (§6.1 steps 4–5: 39 ns per message, `v5.md` §6.1); at 100 idle players ≤ 100 frames/s, ≤ 16 µs/s |

**What forcing protects, and what not.** It makes the beacon reach the server from every client with the option
on, whatever the game sends, so the fit exists for the clients the measure targets: an accelerating tool on an
input-only or idle client. It changes when beacons arrive, never what a client can state. Not protected, as
before: stamps kept on unmodified time or patched, and a client that blocks Lync's frames. A forced frame is
distinctive (8 B, control type 6) and can be blocked whole; the count gap then reaches the server as `frameGap`
on the next reliable frame (as R26), and a client that blocks every beacon gets no fit, with `clockRestarts`
counting the gaps (gaps over 3 × `clock.beacon`).

**Options.** None added. `clock.beacon` = 0 stays the off switch; a "ride only" mode would be a second way to run
the measure at lower coverage, and its saving is ≤ 8 B/s per idle client. `clock.beacon`'s cost column becomes:
"≤ 8 B and one reliable `FireServer` per beacon on a client with no other reliable data; u4 in `WELCOME`".

**Outcome: adopt.** A due `BEACON` is pending reliable data, with R26's exclusions.

## U4. `roundTrip` and `ping` on server request results

**The research's proposal** (`research/client-security.md` §4 T3): "Expose `roundTrip` and `ping` on server-side
results so game code can study processing-time distributions for human-gated prompts". This defines them for
server `invoke(player, data)` (`v5.md` §3.5, §5.2), with the times `earlyAnswer` (`v5-integrity.md` §7) and U10
(`research/server-facts.md` §U10.4) already read, so the result, `earlyAnswer` and `earlyReaction` agree.

### U4.1 Fields

All on the server, in seconds (real); −1 marks "no such moment", the facts' convention (`desync.sinceRekey`).

| Field | Definition | −1 when |
|---|---|---|
| `roundTrip` | t_r − t_s: t_s = `os.clock()` at the flush that passed the ask's frame to `FireClient` (for a held send, the flush that released it; U10's t_s); t_r = `os.clock()` at the decode of the frame holding the answer (U10's t_r) | no answer arrived |
| `pingAtSend` | `Player:GetNetworkPing()` sampled at t_s (the sample `earlyAnswer` and U10's bound already take per ask) | the ask was never sent |
| `pingAtAnswer` | `Player:GetNetworkPing()` sampled at t_r | no answer arrived |
| `minPing` | U10's path bound at t_r: the minimum over the last 10 s of the player's ping samples and of Lync's ack round trips where state frames flow (§U10.4); the number `earlyAnswer` compares with, and its evidence `minPing` | no answer arrived |

| Outcome | `roundTrip` | `pingAtSend` | `pingAtAnswer` | `minPing` |
|---|---|---|---|---|
| `ok`; `rejected` or `unanswered` (the client answered with that outcome) | value | value | value | value |
| `timeout` after the ask left | −1 | value | −1 | −1 |
| `timeout` while waiting for a slot or in the join hold (§5.3); `left`, `shutdown` before the flush | −1 | −1 | −1 | −1 |
| `left`, `shutdown` after the ask left | −1 | value | −1 | −1 |

- A late answer (after the timeout) has no result; it stays `lateAnswers` (§5.2).
- `earlyAnswer` fires on exactly the answers whose result shows `roundTrip` < `earlyAnswer.factor` × `minPing`,
  and its evidence carries the same two numbers. That needs `earlyAnswer`'s "send time" to be t_s (the flush), not
  the `invoke` call, and its bound to be U10's (U10 implication 10); both are stated here so the three agree.
- Client-side results are unchanged. The measure serves the server, which owns the answer; a client timing the
  server states nothing about any player. Principle 4 favours one result shape on both sides; the sides differ
  here because only the server's measurement is about a player, and the client would pay one `os.clock` per ask
  and answer and one `GetNetworkPing` on `LocalPlayer` for fields no decision reads. Each side already has its own
  `invoke` signature (the server's takes the player first).

### U4.2 Resolution

- **Clock:** `os.clock()` is sub-microsecond (documented). The measured quantity is coarser:
  - t_s is read at `PostSimulation`; whether the engine sends in that frame's network step is unmeasured
    (`v5.md` §10): 0 to one server frame (16.7 ms at 60 Hz) is in `roundTrip` and not in the network.
  - t_r is read when the engine runs Lync's `OnServerEvent` handler: quantized to the server's frame, up to 16.7 ms.
  - On the client: the ask is dispatched at its next frame (up to 1/fps), the handler runs, and the answer leaves
    at the next automatic flush (§5.1: at `PostSimulation`, at least 1/60 s after the previous one).
- **Ping:** a `float` (24-bit mantissa: a step of 7.45 × 10⁻⁹ s at 0.1 s); its smoothing is unmeasured (§10).
- **Ack round trip** (inside `minPing`): exists only where `:newest()` state frames flow to the player; an ack rides
  the first frame of a client flush, or an ack-only frame once 2 frames are unacked or the oldest is 100 ms old
  (§4.1), so each sample includes 0 to 1/60 s of client hold, and the bound takes the 10 s minimum.

### U4.3 Values on an unmodified client (`roundtrip_sim.out`, simulated; `v5.md` §9 default network, ping taken as the mean network round trip 0.120 s)

| Answer | `roundTrip` − ping: p1 / p50 / p99 (s) | `roundTrip` / ping: p1 / p50 |
|---|---|---|
| automatic (handler returns at once), 30, 60, 144 or 240 fps | −0.003 / 0.030 / 0.213–0.230 | 0.97 / 1.25 |
| after one yielded frame, 60 fps | 0.013 / 0.047 / 0.247 | 1.11 / 1.39 |
| human, reaction lognormal median 0.35 s (assumed), 60 fps; 30 fps | 0.180 / 0.380 / 0.847; 0.197 / 0.397 / 0.847 | 2.50 / 4.17; 2.64 / 4.31 |

Latency drop from 0.10 to 0.03 s one-way, automatic answer (ping as an exponential average with time constant τ,
**assumed**): `roundTrip` / ping-only minimum falls to 0.52–0.59 within 0.5 s of the drop (τ 10 s and 2 s) and
is back to 0.90 at 2 s (τ 2 s) or 10 s (τ 10 s) after it; with the ack round trip in the bound it stays 1.64.

**Known causes on an unmodified client**, for the docs page of the result fields:
- *Short* (`roundTrip` at or below `pingAtSend`): an answer computed without waiting for input, which is most
  server asks (a state query, a confirmation the client code answers itself): their p1 is 0.003 s under the
  smoothed ping; `pingAtSend` above the current path (jitter below its mean, or a latency drop the smoothing
  hasn't followed, as above).
- *Long:* waiting for a person (the human row); a handler that yields (one frame: +0.017 s at p50); reliable-lane
  stalls and retransmission (the p99 tail, +0.2 s); a low client frame rate (each frame of dispatch wait is 1/fps);
  a server frame that runs long (t_r waits for it); ping spikes on mobile of 100–500 ms
  (`client-security.md` §4 T3, reported), which also make `pingAtSend` and `pingAtAnswer` differ.
- `roundTrip` − `minPing` is the processing estimate U10 uses; it is at least the true client time whenever the
  bound is at or below the true path (§U10.6).

### U4.4 API

Generated Luau shard, server view (checked clean under luau-analyze 0.740 `--solver=new` and `--solver=old`;
narrowing on `ok` exposes `value` only in the success arm, and reading `value` in the failure arm is an error on
both solvers; `probes/clock-facts/result_types.luau`, `result_types.out`):

```luau
export type ServerResult<R, E> =
	{ ok: true, value: R, roundTrip: number, pingAtSend: number, pingAtAnswer: number, minPing: number }
	| { ok: false, error: E, roundTrip: number, pingAtSend: number, pingAtAnswer: number, minPing: number }
```

- The four fields are written out in both arms rather than intersected with a timing type, so neither solver has
  to normalise an intersection of a union. A helper typed `(t: ServerTiming) -> number`, with
  `ServerTiming = { roundTrip: number, pingAtSend: number, pingAtAnswer: number, minPing: number }`, accepts a
  result as is (structural; checked on both solvers).
- The no-build path gives the same shape; exact types there only under the new solver, as everywhere (§3.2).

roblox-ts `.d.ts` (checked clean with `tsc` 6.0.2 `--strict`, same narrowing; `result_types_ts.ts`):

```ts
interface ServerTiming {
	readonly roundTrip: number; readonly pingAtSend: number; readonly pingAtAnswer: number; readonly minPing: number;
}
type ServerResult<R, E extends string> =
	| (ServerTiming & { readonly ok: true; readonly value: R })
	| (ServerTiming & { readonly ok: false; readonly error: E });
```

JSDoc on each field carries the definition and its −1 case (the table in §U4.1).

### U4.5 Cost (`beacon_cost.out` D, `cost.out`)

| Item | Native | Interpreted | When |
|---|---|---|---|
| record t_s and `pingAtSend` in the slot | 6.3–7.2 ns | 21.5–29.3 ns | per ask (already needed by `earlyAnswer`) |
| result with the four fields, against `{ ok, value }` | 48.0–62.0 against 32.3–36.6 ns: +15.7–25.4 ns | 79.7–89.4 against 39.8–42.2 ns: +40–47 ns | per result |
| bound: minimum of ten one-second buckets | 44.3–55.5 ns | 144–162 ns | per answer; cacheable per second (U10.7: 45.4–46.0 ns) |
| `GetNetworkPing` at t_r | engine call, unmeasured | — | per answer: the only new engine call |
| `os.clock` at t_r | shared: one read per inbound frame for `earlyAnswer` and U10 | | |

If results were frozen (the design doesn't say; facts are), `cost.out` measured +12 to +33 ns for three extra
fields on a frozen table. Memory: two numbers per slot, 16 slots, 256 B per player. Wire: none.

**Outcome: adopt** the four fields on server-side results, defined on U10's t_s, t_r and bound.

## Implications

1. **Measure beacon arrivals with server `os.clock()`**, never server `GetServerTimeNow()` (Unix time), so Lync adds
   no common-mode slope of its own (§U3.2 rule 1).
2. **Align windows and fits to one server grid** (⌊t/5⌋ of `os.clock`), so every player's fits share epochs
   (§U3.2 rule 3).
3. **Add the split-half test to the `clockRate` trigger**: one delay step of 0.5 s or more otherwise fires at the
   defaults (188–300 of 300 players simulated, 0 with the test); `reportFits` 4–5 is not enough on the mobile
   model (42–52 of 300) (§U3.1, §U3.2 rule 5, `step_response.out`).
4. **Report slow clocks through the same fact,** with signed `slope` and the threshold on its magnitude; the
   sources are symmetric in sign (§U3.4).
5. **Refuse every server-wide correction in the trigger** (literal window rule, discard, guard): the research's
   cause (hitches) produces no slope, and discard and guard hide any majority applying the same clock change
   (§U3.1, §U3.3).
6. **Expose "together" as evidence:** `othersSlope` and `others` on `clockRate`, and the server counters
   `clockSlopeMedian` and `clockSlopeFits`; R37's `clockSlope` stays the player's own slope (§U3.3, §U3.5).
7. **Add `firstHalf`, `secondHalf` and `drift` to `clockRate`'s evidence** so the trigger can be re-checked and
   bounded path causes told from growing offsets (§U3.5).
8. **Replace `clockRate`'s known causes** with the delay-envelope ramp (client uplink or server inbound), and the
   0.6% slew only at `reportSlope` ≤ 0.0069 (§U3.5).
9. **Keep `clock.reportSlope` 0.01 and `clock.reportFits` 3;** the largest unmodified |s| simulated is 0.00691;
   device noise and slew still need measuring (`v5.md` §10) (§U3.1, §U3.5).
10. **Make a due `BEACON` pending reliable data** with R26's exclusions: without it, clients sending fewer than
    3 reliable messages a second get no fit at all (0–0.6% of epochs at 0–1 msg/s); cost ≤ 8 B/s and one
    `FireServer` a second per idle client (BEACON gap).
11. **Add no option for beacon delivery;** `clock.beacon` 0 stays the only switch, and its cost column states the
    forced frame (BEACON gap, options).
12. **Add `roundTrip`, `pingAtSend`, `pingAtAnswer`, `minPing` (s, −1 when absent) to server-side results only**,
    written out in both arms of the union; checked on both Luau solvers and `tsc --strict` (§U4.1, §U4.4).
13. **Define t_s as the flush that sent the ask and `minPing` as U10's bound** in `earlyAnswer` too, so the fact's
    evidence equals the result's fields for the same answer (§U4.1).
14. **Document `roundTrip`'s granularity** (server frame at both ends, client dispatch and flush) and the
    simulated values: automatic answers at ping + 0.030 s (p50), humans at ping + 0.38 s (§U4.2, §U4.3).
15. **Still unmeasured, and each changes a cause's strength, not a rule:** `GetNetworkPing` smoothing and cost,
    whether `PostSimulation` sends leave in that frame, client clock slew on devices, and server inbound backlog
    behaviour under load (§U3.5, §U4.2).
