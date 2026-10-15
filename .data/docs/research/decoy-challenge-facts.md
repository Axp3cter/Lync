# Decoy-adjacent facts (U11) and server-issued challenges (U14)

Researcher findings, 2026-10-15. **Decision it feeds:** what the architect writes into `v5-integrity.md` for the two
items `research/security-refusals.md` §4 lists as described but never decided: U11 (a rewound hit on a decoy, a
game-reported interaction with a decoy, a build lint for client-sent key fields into decoy collections) and U14
(server-issued challenges). Lync reports facts with exact triggers and numeric evidence; it never judges, scores or
acts beyond dropping malformed input.

Read in full: `design/v5.md` §3.4–§3.6, §5.2, §6, §7; `design/v5-integrity.md`; `design/v5-collections.md`;
`research/anticheat-design.md` (AC) §2, §4.1, §4.3, §7, §8; `research/generation-methods.md` §0 and M15;
`research/interest-rewind.md` (IR) §1–§3, §6, §8, §10, §11; `research/diagnostics.md` §2, §5;
`research/client-security.md` (CS) §1; `research/checks-telemetry.md` C5 (lint conventions).

**Labels.** **verified**: I ran it or read the source. **documented**: official docs say so. **reported**: a third
party says so. **unverified**: inference, or nothing found.

**Capability classes** as `generation-methods.md` §0 groups CS §1.2: **code**, **mem**, **api**, **hook**,
**signal**, **packet**, **identity**, **naming**, **clock**, **state**, **share**.

**Tools.** Luau 0.742 built from `.data/projects/luau` (Release; `luau -O2` interpreted stands for clients,
`--codegen` native for servers); `luau-analyze` 0.740 (the `luau` skill's pinned toolchain) with `--solver=new` and
`--solver=old` for typing probes; the skill's Roblox API dump 0.741.19 for member lookups. CLI on a shared 2.1 GHz
Xeon: timings show scale only.

**Probes** (`.data/docs/probes/decoy-challenge-facts/`): listed in §9.

## Checklist

- [x] 0. What exists today, and the gaps U11 and U14 fill
- [x] 1. U11a: decoys under `rewind` (rings, `held`, what `rewound` returns)
- [x] 2. U11b: `reportInteraction` and the fact `decoyInteraction`
- [x] 3. U11c: the build lint `decoyRef`
- [x] 4. U11: what it protects, how it fails on an unmodified client, cost, options
- [x] 5. U14: mechanism, what Lync carries and what the game designs, API (Luau and roblox-ts)
- [x] 6. U14: outcome, facts and evidence
- [x] 7. U14: known causes on an unmodified client, accessibility included
- [x] 8. U14: what it protects, cost, options
- [ ] 9. Probes and measurements
- [ ] Implications

---

## 0. What exists today, and the gaps

**Decoys** (`v5-integrity.md` §8, verified by reading). `Net.c:decoys(behaviour, { maxPerViewer })` on the server
view; the behaviour returns per viewer `{ [Key]: Record }` each state tick; decoys take slots from a shared pool and
ride in per-viewer copies of changed chunks. M15b adds `Net.c:decoyFrom(sourceKey, overrides)` (values cloned from a
live record). IR §6.1 adds the rule that a decoy must pass the viewer's interest test (`decoyOutsideInterest`, a
caller error in the behaviour's thread).

**The one decoy fact today**, `decoyReferenced`: "a delivered message whose `refers` field holds a key of a decoy
sent to that player", evidence `sentAgo`, action delivered (`v5-integrity.md` §10). It needs
`Net.d:refers(field, collection)`; unknown fields throw `unknownField`.

**Rewind** (IR §11). `Net.c:perceived(player)` (only inside a handler's synchronous part), `Net.c:rewound(seen, key)`
→ `{ ok, value } | { ok = false, error = "expired" | "notHeld" | "unknownKey" }`, `rewoundSpan`, `at(tick, key)`.
IR §11.6 states the rule this unit keeps: **no `Lync.observe` fact from rewind, because Lync can't know a message is
a hit claim**; the game decides hits (R36 refuses a built-in verifier).

**Requests** (`v5.md` §5.2). A server `invoke(player, data)` already yields until the client's `handle` returns,
with `timeout` 0.1–300 s and the `earlyAnswer` fact. A client handler may yield (it runs in a pooled thread).

**Gaps.**
1. A rewound shot that names no target (origin and direction only) can land on a decoy only inside the game's own
   hit test, and that test never sees decoys: the game iterates its own records, and `rewound` holds no decoy
   rings. So "a rewound hit on a decoy" has no path at all today.
2. Interactions the server resolves from something other than a declared key field (a ray, "nearest pickup", a key
   nested in an array of records, a key sent on a non-Lync remote) are never matched against decoys.
3. Nothing tells the developer that a client-sent field could carry a decoy key without a `refers` declaration, so
   `decoyReferenced` silently never fires for it.
4. There is no server-issued challenge. A server request can carry a UI prompt and its answer, but Lync's client
   then holds a pending ask for the client's `handle` to answer, the same shape in every Lync game, and the reply
   carries no gameplay. A shape identical across Lync games gets one bypass that works in all of them (CS §1.4,
   "Economics of a shared library").

---

## 1. U11a: decoys under `rewind`

**Problem.** For "a rewound hit lands on a decoy" to exist, two things must hold: the game's hit test must be able to
see the shooter's decoys at the perceived tick, and Lync must not decide the hit (IR §11.6, R36). So Lync supplies
state and the game supplies the test, and the fact comes from the game's call in §2.

**Mechanism** (applies when a collection has both `decoys` and `rewind`):
- **Per-viewer decoy rings.** After the behaviour's output is applied each state tick, Lync writes each live decoy's
  declared `rewind` fields into a ring per (viewer, pool slot): the same 24 B slot and the same K as real records
  (IR §11.2), holding the *decoded quantized* values that viewer was sent.
- **Per-viewer decoy history**: key → (pool slot, add tick, remove tick, add time, remove time), kept while the decoy
  lives and for `max(2 s, maxRewind + 0.25 s)` after its remove. 2 s is the slot reuse delay (COL §2), so a pool
  slot can't carry a newer decoy's samples under an older key: a read checks that the ring slot holds the tick asked
  for and that the tick lies in [add tick, remove tick).
- **`rewound(seen, key)` and `rewoundSpan(seen, key)`** for a key that is one of `seen`'s player's decoys return its
  values from that viewer's ring, with the same result shape as a real record. `"received"` mode works unchanged:
  decoy rows are rows in that viewer's state frames, so notify's walk of acked frames records them like any other.
  A tick outside the decoy's life gives `notHeld`. A decoy key of *another* viewer gives `unknownKey`, the result a
  never-live key gives, because that player was never sent it.
- **`at(tick, key)`** (the truth ring, no viewer) gives `unknownKey` for every decoy: a decoy has no truth, only what
  one viewer was shown.
- **New: `Net.c:held(seen)`** returns a frozen array of every key k for which `rewound(seen, k)` returns `ok`: the
  records in the viewer's audience (and interest, IR §2) at some tick of the window, records removed since the
  window's low end, and the viewer's decoys alive in the window. **Order: slot order.** Pool slots are drawn at
  random among free slots (COL §2), so decoys fall among real records rather than at the end, and a "first hit
  wins" loop treats them like any record.

**What game code writes** (server; the hit test is the game's, as today):

```luau
Net.shot:connect(function(player, shot)
	local seen = Net.fighters:perceived(player)
	for _, key in Net.fighters:held(seen) do
		local r = Net.fighters:rewound(seen, key)
		if r.ok and rayHits(shot.origin, shot.direction, r.value.position) then -- the game's own test
			Net.fighters:reportInteraction(player, key, HIT) -- states a fact only for a decoy (§2)
			local target = Net.fighters:get(key) -- nil for a decoy, and for a record removed since the tick
			if target then applyDamage(key, target) end
			break
		end
	end
end)
```

- `get(key)` returning nil is not new: a record removed between P and now already gives a rewound value and a nil
  `get` (IR §11.6). Game code written for rewind handles decoys with no extra branch.
- A shot that names its target (`Net.strike:refers("target", "fighters")`) needs no `held`: `rewound(seen,
  shot.target)` works for a decoy key, and `decoyReferenced` has already been recorded on arrival.
- **Not built:** a Lync-side hit test, a decoy flag on the result, or a fact from `rewound` itself. A flag would
  invite game code to branch on it before its own test, and a fact from `rewound` would fire on every lookup of a
  named decoy, which `decoyReferenced` already states.

**Cost** (server; `probes/decoy-challenge-facts/cost_runs.out`, best of 5 per run, range over 3 runs; IR §11.7):
- Ring push: 4.1–5.2 ns native for the bare 24 B write (probe (b)); IR §11.7 measures 9.5–10.5 ns for its full push.
  At 100 viewers × 1 decoy × 20 Hz × 10.5 ns: 21 µs/s.
- Memory: viewers with decoys × `maxPerViewer` × K × 24 B: 100 × 1 × 27 × 24 B = 65 KB at 20 Hz and `maxRewind` 1 s;
  259 KB at `maxPerViewer` 4; 185 KB at 60 Hz (K = 77). History: one small record per decoy, live or removed in the
  last 2 s.
- `held(seen)`: 316–564 ns native per call for 64 real + 1 decoy keys, 808–891 ns for 300 + 1 (probe (c)), one
  allocation. The game's own loop over the 65 keys costs 708–791 ns, and a `rewound` per key costs 108–121 ns (IR §11.7). So a ray
  test over every held record is dominated by the game's per-key work: about 8 µs per shot at 65 keys, 8 ms/s at
  1,000 shots/s (0.8% of a core). Games that narrow candidates first (by cell or distance) pay less.
- Wire: zero.

---

## 2. U11b: `reportInteraction` and the fact `decoyInteraction`

**API** (server view of any collection): `Net.c:reportInteraction(player, key, kind)`.
- `key` has the collection's key type; `kind` is an integer 0–255 the game chooses (say 1 hit, 2 pickup, 3 open).
  A `kind` outside 0–255 or a fraction throws `valueRefused` at the caller; a wrong-typed key is a type error on
  both solvers and in TypeScript (`probes/decoy-challenge-facts/types.out`, `types_ts.out`).
- It returns nothing, for real and decoy keys alike. Game code calls it for every interaction it resolves, with no
  branch on what the key is, and a collection without decoys pays one failed lookup.
- **On the view, not `Lync.reportInteraction(ref)`** as the research named it: the key type and the decoy set are
  per collection, and verbs live on views (`v5.md` §3.5, principle 3). The name is kept.
- Call it only for records the client's own message selected (named, aimed at, touched, opened). Records the server
  selects by itself (area damage, server-side auto-target) make the fact fire with no client involvement (§4).

**Fact.**

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `decoyInteraction` | game code calls `Net.c:reportInteraction(player, key, kind)` and `key` is in `player`'s decoy history for `c`: a decoy of that player live now, or removed less than max(2 s, `maxRewind` + 0.25 s) ago | none (the call is the game's; Lync records it) | `kind` (the game's integer), `sentAgo` (s since the decoy's add to that player), `removedAgo` (s since its remove, −1 while live), `heldAtPerceived` (1 the decoy was alive for that player at some tick of the perceived window of the message being dispatched; 0 it was not; −1 no window: called outside a handler's synchronous part, or `c` has no `rewind`) | §4.2 |

- The fact's `definition` is the collection's name; `kind` tells actions apart. Evidence is numbers only, as
  `v5.md` §7.3 requires.
- **With `decoyReferenced`.** A shot naming a decoy in a `refers` field records `decoyReferenced` on arrival; if the
  game's test then finds the hit and reports it, `decoyInteraction` follows. They have different triggers ("the
  client named it" and "the game's own test found the client interacted with it"), so both are stated. A named
  decoy that the game's test misses gives only the first.
- **Proposed alignment of `decoyReferenced`.** Match it against the same history (today's text, "a decoy sent to
  that player", leaves removed decoys undefined) and add `removedAgo`. A reference to a decoy removed 0.2 s ago is the
  interpolation case of §4.2; a reference with no history entry is not a decoy reference at all.

**Cost** (`cost_runs.out` probe (a), server native; interpreted in brackets; ranges over 3 runs):
- A real key (lookup misses): 24–36 ns (41–43 ns). Most calls take this path.
- A decoy key: 44–54 ns (97–106 ns), evidence included, with a one-increment stand-in for the fact record; the real
  record is 20.5 ns native (`v5.md` §7.3) and the fact's delivery is capped and coalesced as for every fact.
- Memory: the decoy history of §1 (also needed without `rewind`, minus the ticks). Wire: zero.

---

## 3. U11c: the build check `decoyRef`

**Why.** `decoyReferenced` fires only for fields declared with `refers`. A key field left undeclared is silent, and
nothing says so. The research proposed a lint for "client→server definitions with `ref` fields into a collection
that has decoys" (AC §2.2). v5 has no `ref` codec; keys are ordinary codecs, so the check matches codecs, exactly as
`unscopedRef` does for server-sent fields (IR §8).

**Exact trigger** (build diagnostic, family `build`, `v5-tooling.md` §3):
- a collection C with a `.C:decoys(` call in the scanned server scripts (the text pass reachability and
  `unscopedRef` already make, `v5-integrity.md` §3); and
- a leaf of a client-sent payload (`data` of `from = "client"` events and requests, `reply` of `from = "server"`
  requests), walked depth first in name order as `freeFormField` walks it (`checks-telemetry.md` C5), whose codec
  serialises (`v5.md` §4.7) identically to C's `key` codec; and
- no `.D:refers("<top-level field>", "C")` call for that definition D and the leaf's top-level field.

**Evidence:** definition, field path (`data.offers[].item`), collection; the Diagnostic's `range` at the
definition's schema line. When the path is not declarable by `refers` (below), the message says so and names
`reportInteraction` as the way to state it.

```
warning[decoyRef]: arena.tip data.to has the key codec of fighters, which has decoys, and no :refers("to", "fighters")
warning[decoyRef]: arena.trade data.offers[].item has the key codec of pickups, which has decoys, and no :refers("offers", "pickups"); not declarable by :refers (not a top-level key, optional key or array of keys): report it with reportInteraction
```

**Proposed widening of `refers`.** Today it takes "a client-sent field" holding keys. The check is satisfiable only if
`refers` accepts a top-level field whose codec is the key, `t.optional` of it, or `t.array` of it (each element
matched). Keys deeper than that (inside records in arrays, union variants) stay undeclarable; the game reports them
with `reportInteraction` from the handler. Cost of arrays: one decoy-history lookup per element (24–36 ns native, §2).

**Measured on stand-in codecs** (`probes/decoy-challenge-facts/lint.luau` → `lint.out`, verified): the `arena` schema
of `v5.md` §3.4 plus a `pickups` collection with decoys and five demo definitions gives 4 reports:
- `sweep data.items[]` and `tip data.to`: true positives, declarable;
- `trade data.offers[].item`: true positive, not declarable;
- `score data.points` (`t.int(1, 2 ^ 40)`, the same codec as a `UserId` key): a false positive;
- `strike data.target` and `collect data.item` are silent (declared); `chat` is silent (no key codec).

**Known causes of a report without a missing declaration:** a field that shares the key codec but isn't a key (the
score above); a key field the developer leaves undeclared on purpose (a player naming its own record, which is
never a decoy). The check reports the codec match; only the game knows whether the field is a key. **Misses:**
decoys declared with a computed collection name or outside the scanned scripts; keys carried in another codec (a
string, a slot index); keys sent on remotes Lync doesn't own (`rawRemote` reports those).

**Review list, not a diagnostic.** `report.md` lists every (definition, field, collection) where `refers` meets
`decoys`, with the client scripts the reachability scan found firing the definition. It is the place to review the
known cause AC §2.2 names: client code that sends a key for every record it holds (aim assist, "select nearest", a
report button). A list costs no warning noise; whether that code can reach a decoy is a question about placement,
which only the game can answer.

**Runtime path:** nothing. There is no build to report to, and a line in every session is the channel M11 refused
(`v5-changes.md`), as for `freeFormField`.

| Option (`lync.toml`) | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `[check] decoyRef` | `"off" \| "warn" \| "error"` | — | — | `"warn"` | build time only: one codec comparison per client-sent leaf per collection with decoys, inside the existing text pass; 0 B and 0 ns at run time |

---

## 4. U11: what it protects, how it fails, cost, options

### 4.1 What it protects, and what it does not

- **Prices state readers that act on what they read** (class **state**, routes A4 and A8 of CS §1.4): aimbots and
  target selectors locking onto records read from memory, and auto-collect or auto-interact bots that choose
  records from replicated state rather than from the screen. With the decoy placed where the game's rendering never
  shows it, `decoyInteraction` says the client chose a record its own rendering did not show. §1 extends this from
  shots that name a target to shots the server resolves from a ray; §2 extends it to any interaction the server
  resolves (nearest pickup, opened door, keys nested in payloads).
- **Prices api drivers** that fire actions at every key they find (`Net.collect:fire(key)` over all records):
  already `decoyReferenced`; §2 covers the same drivers when the key goes through a field `refers` can't declare.
- **Robustness.** The fact is computed on the server from the client's own message and the game's own test. A
  modified client can't suppress or forge it; it can only avoid choosing decoys. What the fact proves is exact
  ("the server sent this record only to this player, and the game's test says this player interacted with it");
  what it means depends wholly on placement, which is the game's (AC §2.1: "reduces the anti-cheat problem to the
  bot design problem").
- **Does not price:**
  - tools that act only on what is rendered (screen-reading aimbots, externals reading the frame): AC §2.1 reports
    this as Activision's admitted weakness;
  - state readers that reproduce the game's visibility (a raycast from the camera before targeting). They skip any
    decoy that is truly invisible; the contest becomes per-game work on both sides;
  - passive readers (ESP that never acts): nothing fires, and `interest` (D1) is what limits them;
  - **share**: two accounts comparing key sets still spot a decoy only one of them holds (R15 stays refused);
  - engine-replicated characters and parts: decoys are Lync records only (AC §9).
- Nothing on the client marks a decoy (R19 stays refused), so **mem** and **code** readers of Lync learn nothing new;
  what they could learn is the game's own rendering rule, which is placement again.

### 4.2 Known causes on an unmodified client

The same for `decoyInteraction`, `decoyReferenced` and a rewound hit on a decoy:

1. **Placement the game's client renders**: the behaviour put the decoy where the game's renderer shows it. A
   declaration mistake; the fix is the behaviour.
2. **A camera turn faster than the behaviour follows.** "Behind the viewer" is relative to the server's last view of
   the player. The client's camera leads it by the upstream latency plus up to one state tick, and the decoy is
   drawn D behind, so after a fast turn a "behind" decoy can be on screen for about rtt + 1/`state.rate` + D: 0.25 s
   at 100 ms round trip, 20 Hz and D = 0.1 s (derived, unmeasured). A player firing at what appears in that time hits
   it. Lync has no camera evidence; the behaviour can keep "behind" decoys outside the angle a turn sweeps in that
   time, or use geometry.
3. **Interpolation and in-flight removes.** The client keeps a removed decoy until the remove arrives (one-way
   latency) and draws `:newest()` fields D behind, so a decoy the behaviour moves out of view stays visible at its
   old place for up to one-way latency + D. Evidence: `removedAgo` at most about rtt + D, `heldAtPerceived` 1. In
   `"received"` mode the rewound value is what the client showed (IR §11.5), so a hit there is a hit on a drawn
   decoy, and the cause is placement timing.
4. **Streaming.** An "inside geometry" decoy assumes the occluder exists on the client. With `StreamingEnabled`,
   parts outside the streamed region, or not yet streamed after a teleport, are absent (IR §12.1: the radius is no
   secrecy bound), and a game that renders Lync records regardless of streaming shows the decoy in the open. Lync
   has no evidence for this. Occluders the behaviour relies on can be kept on every client with
   `Model.ModelStreamingMode = Persistent` (enum value 2, verified in the API dump 0.741.19).
5. **A world-blind hit test.** A ray test that doesn't raycast the world first "hits" a decoy inside a wall when the
   player shoots the wall. A bug in the game's test; Lync's `rewound` is correct and the world is the game's.
6. **Server-selected interactions** reported through `reportInteraction`: area damage or server auto-target over
   `held(seen)`. The client did nothing; the call is in the wrong place (§2).
7. **Game code that targets every record it holds** (AC §2.2): aim assist, target lock, tab-targeting, an
   auto-collect magnet, "select nearest", a scoreboard report button. Games with these exclude decoys by placement
   (outside the assist range) or don't use decoys in that collection.

### 4.3 Cost

| Item | Server CPU (native) | Memory | Wire | Developer |
|---|---|---|---|---|
| decoy rings (§1) | 9.5–10.5 ns per decoy per state tick (IR §11.7; bare write 4.1–5.2 ns) | `maxPerViewer` × K × 24 B per viewer with decoys (65 KB at 100 viewers, 1 decoy, 20 Hz, 1 s) | 0 | none: follows `rewind` |
| `held(seen)` (§1) | 316–564 ns per call at 65 keys, 808–891 ns at 301, one allocation | the frozen array | 0 | hit code iterates `held` instead of its own list |
| decoy history (§1, §2) | one map update per decoy add and remove | one record per decoy, live or removed in the last max(2 s, `maxRewind` + 0.25 s) | 0 | none |
| `reportInteraction` (§2) | 24–36 ns per call (miss), 44–54 ns (decoy) | none | 0 | one call where the game resolves an interaction |
| `decoyRef` (§3) | build time only | — | 0 | one `refers` per key field, or a deliberate ignore |

### 4.4 Options

No new run-time options: the rings follow `rewind`'s `fields`, `maxRewind` and `mode` (IR §11.9), and decoys keep
`maxPerViewer` (`v5-integrity.md` §8).

| Name | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `kind` (argument of `reportInteraction`) | integer | — | 0–255 | required | none; evidence only |
| `[check] decoyRef` | `"off" \| "warn" \| "error"` | — | — | `"warn"` | build time only (§3) |
| decoy history retention (constant, `v5.md` §4.9's rule: not a knob) | number | s | — | max(2, `maxRewind` + 0.25) | one record per removed decoy for that long |

---

## 5. U14: server-issued challenges

### 5.1 What Lync carries, what the game designs

AC §7 describes "periodic interactions that only an attentive human passes (anti-AFK-bot)" and judged it "Recipe;
accessibility false-positive risk; not core". This section designs the part a library can own.

| Lync carries | The game designs |
|---|---|
| an unpredictable token per challenge, drawn by the server | what the player sees or hears, and where (a UI prompt, a code on a sign, a marker to walk to, a sound) |
| which client fields may carry an answer (`answers`) | which of its own definitions carries the token down and the answer up |
| matching every arriving answer against the player's open challenge | the action that produces the answer (typing, choosing, walking, pressing) |
| the deadline, extension, cancellation, attempts | when to issue, how long to allow per player, alternatives for players who can't answer in that form |
| the outcome with timing evidence, and facts for answers outside a challenge | what a missing or mismatched answer means |

**Design rule: server-only, invisible in the shared schema and on the client.** The token travels in an ordinary
field of the game's own server-sent message (or a collection field, or an engine instance), and comes back in an
ordinary field of the game's own client-sent message. Lync's client runtime and the shared schema know nothing of
challenges; the schema hash doesn't change. This follows traps ("the shared schema shows nothing special",
`v5-integrity.md` §3) and the economics of a shared library (CS §1.4): a challenge kind visible to Lync's client
would be the same in every Lync game, and one hook on it would answer every game's challenges. Here a bot must find,
per game, which field carries the token and which action carries the answer.

### 5.2 API (Luau, both solvers)

```luau
-- shared schema: ordinary definitions, nothing marks them
afkPrompt = Lync.event({ from = "server", data = { code = t.int(0, 9999), spot = t.vector3(-2048, 2048, 1 / 8) } }),
use = Lync.event({ from = "client", data = { target = t.int(1, 4096), code = t.optional(t.int(0, 9999)) } }),

-- server
Net.use:answers("code") -- once: this field may carry an answer
local c = Lync.challenge(player, { within = 120, values = 10_000, attempts = 3 })
Net.afkPrompt:fire(player, { code = c.token, spot = spot }) -- the game sends the token however it likes
local closed = c:wait() -- yields until answered, mismatched, timed out, cancelled, or the player leaves
if closed.outcome == "timeout" then
	-- the game's policy
end

-- client: ordinary game code
Net.afkPrompt:connect(function(prompt) showPrompt(prompt.code, prompt.spot) end)
-- on the player's action:
Net.use:fire({ target = key, code = enteredCode })
```

- **`Net.d:answers(field)`** (server view of a client-sent event or request): `field` is a top-level field of codec
  `t.int(min, max)` or `t.optional` of one. An unknown field throws `unknownField`; another codec throws
  `valueRefused`. Several definitions may declare answers fields. A message's answers field is read in step 5's
  report-only checks (`v5.md` §6.1), after `unresolved` and `limit`, before validators: a message dropped earlier
  answers nothing; a message the game's validator then rejects still counts as having arrived. A nil field answers
  nothing.
- **`Lync.challenge(player, options)`** draws `token` = `Random:NextInteger(0, values − 1)` from a server `Random`
  created with no seed, which "uses a seed from an internal entropy source" (documented,
  [Random](https://create.roblox.com/docs/reference/engine/datatypes/Random)); the bounds are inclusive (documented).
  - At most one open challenge per player: a second call throws `challengeOpen` at the caller. Every value arriving
    on an answers field while one is open is then an attempt at it, with no ambiguity.
  - `values` must fit some declared answers field (0 and values − 1 within its `min`–`max`), else `valueRefused`
    (subject `options.values`). Misspelled option keys are not type errors in Luau on either solver
    (`types.out`: the `MISSED` line), so the call throws `unknownOption` for an unknown key, as declarations do.
- **The handle** `Challenge`: `token`, `deadline` (`GetServerTimeNow()`), and three methods.
  - `wait()` yields until close and returns the frozen outcome (§6); after close it returns at once, the same value
    to every caller.
  - `extend(seconds)` moves the deadline later while open (seconds 1–3600, total `within` at most 3600 s); on a
    closed challenge it does nothing.
  - `cancel()` closes it as `cancelled`.
  - A leaving player closes it as `left`; `BindToClose` closes every open one as `shutdown`.
- **Exact types** on both solvers: the generated server shard declares `answers` with the definition's eligible
  field names as a string-literal union, and the outcome as a union discriminated on `outcome`, with `after:
  number` on `answered`/`mismatched` and `after: nil` otherwise. Verified with `luau-analyze` 0.740,
  `--solver=new` and `--solver=old`, strict (`probes/decoy-challenge-facts/types.luau` → `types.out`): a
  misspelled field and reading `after` after a timeout are errors on both; the shard must not use `read`
  modifiers, which the old solver rejects ("read keyword is illegal here", first run of the probe).

### 5.3 roblox-ts

```ts
interface ChallengeOptions { within: number; values: number; attempts?: number }
type ChallengeClosed =
	| { readonly outcome: "answered" | "mismatched"; readonly after: number; readonly attempts: number; readonly minPing: number; readonly definition: string }
	| { readonly outcome: "timeout" | "cancelled" | "left" | "shutdown"; readonly after: undefined; readonly attempts: number; readonly minPing: number; readonly definition: undefined };
interface Challenge { readonly token: number; readonly deadline: number; wait(): ChallengeClosed; extend(seconds: number): void; cancel(): void }
// Lync: challenge(this: void, player: Player, options: ChallengeOptions): Challenge
// per definition: answers(field: "code"): void
```

Checked with tsc 6.0.2 `--strict` (`types.ts` → `types_ts.out`): the misspelled field, `after` after a timeout, a
string key and the misspelled option key `attemps` are each one error (TypeScript's excess-property check catches
what Luau misses). Method form (`c.wait()` compiles to `c:wait()`) or `this: void` follows whatever `v5.md` §3.6
settles for views.

### 5.4 Not built

- **A challenge definition kind or a client API**: refused by the design rule of §5.1.
- **Server-resolved answers** (`c:answer()` when the game's own check passes, such as the player reaching a
  marker): Lync would observe nothing; the game has the same clock and `GetNetworkPing()` and times it itself.
- **A request-shaped challenge**: a game that wants a UI ask with a reply already has a server `invoke` with
  `timeout` up to 300 s and `earlyAnswer` (§0); it gets the shared-shape cost of §5.1.

---

## 6. U14: outcome, facts and evidence

### 6.1 The outcome (result value)

`c:wait()` returns one frozen record. Times are `GetServerTimeNow()` differences in seconds.

| Field | Type | Meaning |
|---|---|---|
| `outcome` | `"answered" \| "mismatched" \| "timeout" \| "cancelled" \| "left" \| "shutdown"` | `answered`: a value equal to `token` arrived on an answers field from that player while open. `mismatched`: `attempts` values arrived and none was equal. `timeout`: the deadline passed first. The other three as §5.2 |
| `after` | number, or nil | answered or mismatched: decode time of the frame carrying the closing value minus the `Lync.challenge` call |
| `firstAfter` | number, or nil | the same for the first value received, nil if none |
| `attempts` | integer | values received while open, the closing one included |
| `minPing` | number (s) | the smallest `Player:GetNetworkPing()` sampled at issue, at each attempt and at close |
| `definition` | string, or nil | the answers definition that carried the closing value |

- **What `after` contains**: the wait for the next server flush (at most one frame, `v5.md` §5.1), downstream
  transit, the client's time before it sent (the person's response plus up to 1/60 s of client flush), and
  upstream transit. `after − minPing` estimates the client-side part; Lync states both numbers and computes no
  difference.
- `timeout`, `left` and `shutdown` are the existing outcome codes (`v5.md` §7.1). `answered`, `mismatched` and
  `cancelled` are new codes of the `outcome` family, each with a registry page. "Mismatched" states a comparison;
  it is not a word about the value's quality (§7.1's rule).

**Channel: a result value, not a fact.** `v5.md` §7.2 sends request outcomes to the result and what players send
to facts. A challenge is issued by server game code that is waiting for it, like an `invoke`. As a fact, every
answered challenge would also print a console warning line (§7.4), and the issuer would have to match facts back to
its call. Game code that centralises policy in `Lync.observe` can forward the outcome. Alternative, not
recommended: a fact `challengeClosed` with the same evidence, which duplicates one record in two channels.

### 6.2 Facts

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `unsolicitedAnswer` | a non-nil value in an answers field from a player with no open challenge | none (the message is delivered as usual) | `closedAgo` (s since that player's last challenge closed, −1 if none this session), `closedAs` (0 answered, 1 mismatched, 2 timeout, 3 cancelled, −1 none), `matchesLast` (1 if the value equals that challenge's token, 0 if not, −1 none) | an answer after the deadline (`closedAs` 2, `matchesLast` 1, small `closedAgo`): the player needed more than `within`; a repeated answer (`closedAs` 0, `matchesLast` 1): a double press or a game client that resends; game client code that fills the field when no prompt is shown (continuous occurrences); an answer entered after the game cancelled |
| `earlyAnswer` (widened) | as today, or a value closing a challenge as `answered` arriving sooner than `earlyAnswer.factor` × the smallest ping sampled for the player in the last 10 s, measured from the `Lync.challenge` call | delivered | `roundTrip` (s), `minPing` (s), new `challenge` (0 a server ask, 1 a challenge) | as today (`GetNetworkPing` smoothing lags a drop in latency); for challenges, game client code that sends the answers field without a prompt on screen, matching by chance with probability 1/`values` per value |

- **No fact for a token arriving from another player.** Answers are matched only against the sender's own open
  challenge, so another player's value is that player's attempt. Tokens drawn from 10^4 values coincide between
  players by chance; equality across players proves nothing.
- **Coalescing** as every fact (`v5.md` §7.3): key (player, reason, namespace, definition), the definition being the
  answers definition.

---

## 7. U14: known causes on an unmodified client, accessibility included

Every outcome other than `answered` has causes that involve no modified client. The outcome states what arrived and
when; it cannot tell a person from a program, or a person who stepped away from one who could not answer.

### 7.1 `timeout`

1. **The player is away.** This is the thing an AFK check measures, not a property of the client. Roblox itself
   fires `Player.Idled` "approximately two minutes after the engine classifies the player as idle", then "every 30
   seconds", "only … in client scripts", and "automatically disconnects players that have been idle for at least 20
   minutes" (documented, `Player.yaml` in `Roblox/creator-docs`, fetched 2026-10-15).
2. **Slower than `within`.** "People with physical disabilities often need more time to react, to type and to
   complete activities" (WCAG 2.2 Understanding 2.2.1, [W3C](https://www.w3.org/WAI/WCAG22/Understanding/timing-adjustable.html),
   documented). SC 2.2.1 asks that a time limit can be turned off, adjusted "over a wide range that is at least ten
   times the length of the default setting", or extended after a warning with "at least 20 seconds to extend the
   time limit with a simple action", unless it is part of a real-time event, essential, or longer than 20 hours.
   `within` per call and `extend` make all three possible; choosing them is the game's.
3. **Controllers and touch.** A prompt whose buttons a gamepad can't select can't be answered without a mouse.
   `GuiObject.Selectable`, `GuiService.SelectedObject`, `ProximityPrompt.GamepadKeyCode` and
   `UserInputService.PreferredInput` exist for this (verified in the API dump 0.741.19). A typed code on a console
   needs an on-screen keyboard; a choice among a few buttons doesn't. Small touch targets on phones cost attempts.
4. **Screen readers.** The API dump 0.741.19 has no scriptable screen-reader member (verified: no member name
   containing "screenreader", "accessib" or "texttospeech"), and Roblox's accessibility guide doesn't mention
   screen readers (documented absence, [guide](https://create.roblox.com/docs/production/publishing/accessibility),
   fetched 2026-10-15; searched DevForum and the web for in-experience screen-reader support, found none). So a game
   can't detect a screen-reader user, and a visual-only prompt can't be presumed reachable. The guide also warns
   that events "only conveyed with sound" confuse hearing-impaired players (documented): a prompt needs both a
   visual and a sound form, answerable with one key.
5. **Motion and text settings.** A moving target conflicts with `GuiService.ReducedMotionEnabled`, which means the
   player wants motion "reduced or completely removed" (documented, same guide). A larger `PreferredTextSize` can push
   a prompt's parts off screen.
6. **The prompt is covered or missing**: the Roblox menu open (`GuiService.MenuOpened`), another modal, a loading
   screen or teleport, the mobile app in the background (whether a backgrounded client keeps receiving is
   unmeasured), or a message arriving before the client's handler is connected (what Lync's client does then is
   unspecified in `v5.md`; §10 lists the engine-side question).
7. **Network**: a reliable-lane stall longer than the time left (the test model's stalls are 0.3 s; mobile is
   unmeasured), or a challenge issued before `WELCOME`, which waits in the server's join hold (`v5.md` §5.3) while the
   deadline runs.

### 7.2 `mismatched`

- Typos and misclicks: with `attempts` 1 a single slip closes the challenge. Controller drift selecting a neighbour.
- A code misread: font, text size, contrast, or colour ("over 5% of people in the world have some form of color
  blindness", the same guide, documented).
- An answers field that also means something in ordinary play, so values arrive that were never answers.

### 7.3 `answered` sooner than a person could

- Game code that fills the answer itself (autofill, a default-focused correct button).
- A confirm key still held from the previous action on a gamepad, or key repeat.
- `firstAfter` and `after` close to `minPing` show these as numbers; any reaction floor is the game's (U10 is the
  separate unit on reaction floors).

### 7.4 Least work, and the docs recipe

The page "Challenges" in the docs gives, as practice and not as Lync behaviour: a `within` per player from a saved
setting with at least a 10× range; a warning 20 s before the deadline and `extend` on any simple action; `attempts`
at least 3 for typed codes; every answer button `Selectable`, with `SelectedObject` set when the prompt opens; a
visual and a sound form; a still form when `ReducedMotionEnabled`; no challenges during menus, cutscenes or the
first seconds after join; a way to opt out where the game has other evidence; and the statement that one `timeout`
distinguishes nothing listed above.

---

## 8. U14: what it protects, cost, options

### 8.1 What it protects, and what it does not

- **Prices automation that doesn't produce the game's response.**
  - Generic idle-timer defeaters: input simulation keeps Roblox's 20-minute idle disconnect away but answers no
    game-specific prompt. `VirtualUser.CaptureController` and its siblings are `LocalUserSecurity` (verified, API
    dump 0.741.19), so game scripts can't call them and executor threads at identity 8 can (CS §1.2); that such
    scripts are what AFK farms run is widely circulated but not checked here (unverified).
  - **api**-class farm bots firing gameplay definitions from executor code without per-game prompt handling.
  - Blind guessing: a guesser closes a challenge as `answered` with probability at most `attempts`/`values` (3/10^4
    at the recipe's values). Each wrong guess is an attempt in the outcome, and guesses outside a challenge are
    `unsolicitedAnswer`.
  - Tools written once for all Lync games: Lync's client has no challenge shape (§5.1), so each game is new work.
- **Robustness.** The outcome is computed on the server from what arrived. A modified client can't close a
  challenge as `answered` without the token, and it can't hide a timeout. Clock tools (**clock**) change nothing:
  deadlines and `after` are server time.
- **Does not price:**
  - a bot that reads the token (from Lync's decoded payload, the UI text, a collection field: **state**, **mem**) and
    sends it through the game's action (**api**): one handler per game, redone only when the game changes how the
    token travels. An answer by such a bot is byte-identical to a person's; `firstAfter`, `after` and `minPing` are
    the only difference, and only if it answers faster than people do;
  - screen readers of a different kind (OCR, ML solvers reading the frame), human farms, and a player who answers
    and then goes idle;
  - **packet** tools add nothing over **api**: they still need the token.
- **Signal strength.** `timeout` is weak alone: §7.1 lists seven ordinary causes. A run of fast correct answers is
  evidence about timing, and only the game knows what is fast for its prompt.

### 8.2 Cost

| Item | Server CPU (native, `cost_runs.out`, 3 runs) | Memory | Wire | Developer |
|---|---|---|---|---|
| token draw | 27–28 ns with `math.random` standing in for `Random:NextInteger` (cost on Roblox unmeasured) | — | 0 | — |
| answers check, per message of a definition with `answers` | 2.4–2.5 ns when the field is nil; 14.3–14.6 ns with a value and no open challenge (plus a fact record, 20.5 ns, `v5.md` §7.3); 23.6–30.5 ns with one open | — | 0 | one `answers` call |
| deadline sweep | 293–336 ns per flush for 50 open challenges (about 6 ns per open challenge; 18–20 µs/s at 60 flushes a second) | one record (token, deadline, attempts, two times, ping) per open challenge; three numbers per player for `unsolicitedAnswer` | 0 | — |
| ping samples | one `GetNetworkPing()` at issue, per attempt and at close (cost on Roblox unmeasured) | — | 0 | — |
| the token's own fields | — | — | the game's codecs: `t.int(0, 9999)` is 14 bits down; `t.optional(t.int(0, 9999))` is 1 bit on every message of the carrying definition and 15 bits when set (`v5.md` §3.3) | the game's fields |
| the prompt | — | — | — | the large part: the UI and its accessible forms (§7.4) |

Interpreted (client-irrelevant here: everything runs on the server) figures are in `cost_runs.out` for reference.

### 8.3 Options

| Name | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `within` (`Lync.challenge`) | number (real) | s | 1–3600 | required | one open record held up to `within` (plus extensions) |
| `values` | integer | token values | 2–2^32 | required (it must match how the game shows the token) | none; a blind guess closes as `answered` with probability ≤ `attempts`/`values`; must fit a declared answers field |
| `attempts` | integer | values received | 1–255 | 1 | none; more attempts raise the blind-guess bound proportionally |
| `extend(seconds)` | number (real) | s | 1–3600, total `within` ≤ 3600 | — | none |
| `Net.d:answers(field)` | declaration (server view) | — | a top-level `t.int` or `t.optional(t.int)` field | none | 2.4–2.5 ns per message when nil, 14–31 ns when set (above) |

Constants (not knobs): one open challenge per player; the `earlyAnswer` window (its own option `earlyAnswer.factor`,
`v5-integrity.md` §7) applies to challenges unchanged.
