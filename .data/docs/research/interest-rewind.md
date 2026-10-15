# Lync v5: `interest` — per-viewer relevancy, visibility classes, scoped events

Researcher findings, 2026-10-15. Design-grade research for the items `research/security-refusals.md` lists as
D1 (`interest`), U8 (visibility classes beyond owner-only; scoped events `:about(ref)` and their lint) and U13
(relevancy counters), so that the architect can specify them now rather than in milestone 7. Rewind (D2) will be
appended to this file by another agent.

Read in full: `research/anticheat-design.md` (AC), `research/state-sync.md` (SS), `design/v5.md`,
`design/v5-collections.md` (COL), `design/v5-extensions.md`, `design/v5-integrity.md` (INT),
`research/security-refusals.md` §3–§4.

**Labels.** **verified**: I ran it or read the source. **documented**: official docs. **reported**: a third party.
**unverified**: my inference.

**Probes** (`.data/docs/probes/interest-rewind/`, luau 0.740 on a 2.1 GHz Xeon, best of 5; native means
`-O2 --codegen`, which Roblox runs on servers only; clients are interpreted):
- `place_read.luau`, `.out`: what a Lune 0.11.0 build host reads from a place file. Another agent wrote it; I
  re-ran it and the output was byte-identical.
- `interest_cost.luau`, `.out`: visibility classes, PVS tests and counters, per (viewer, record) pair.
- `pvs_bake.luau`, `.out`: the cost and table size of a build-time PVS bake.

Interest only refines a collection's audience per viewer; it never widens one (COL §4). Lync reports what it
counts, never a judgement of a player.

## Checklist

- [x] §1 What `interest` protects, and its limit
- [x] §2 Membership: cells, hysteresis, look-ahead
- [x] §3 Encoding under per-viewer membership: cell chunks, catch-up, removal, generations
- [x] §4 Narrowing: a build-time PVS bake, run-time raycasts, a predicate
- [x] §5 Distance priority inside the state budget
- [x] §6 Interaction with decoys and per-player variants
- [x] §7 Visibility classes (U8): owner, team, gated, seen
- [x] §8 Scoped events `:about(ref)` and their lint (U8)
- [x] §9 Relevancy counters (U13)
- [x] §10 Options
- [x] Implications

Dropped from this task by the coordinator (other agents own them; nothing was written into this file):
- D2 `rewind`. The probe `probes/interest-rewind/rewind_cost.luau` and its `.out` were already written; they are
  left in place for that agent.
- U15 (`StreamingTargetRadius` and staged release).
- The `PlayerGui` variant timing rule.
- All of `checks-telemetry.md`. The probe `probes/checks-telemetry/checks_cost.luau` and its `.out` were already
  written and are left in place.

---

## 1. What `interest` protects, and its limit

- **What it prices.** A client can read anything Lync replicates to it (AC §1.4; client-security §1.2): radar and
  ESP built on Lync records, peeking at loadouts, health or objectives. Records a client never receives cannot be
  read, so per-viewer relevancy is the one measure here that removes information rather than detecting its use.
  AC §1.1 cites Riot, whose Fog of War is built on the same principle and runs in under 2% of server frame time.
- **What it cannot protect.** The engine streams every Workspace instance within the streaming radius to each
  client, player characters included, with no line-of-sight filter (AC §1.2, documented). Interest covers only
  state Lync replicates: health, inventory, cooldowns, NPC proxies, projectiles, pickups, and characters only in
  games that render them from Lync records.
- **Where it sits.** It is a refinement of the audience: a record must be in a viewer's audience (COL §4) *and*
  pass that viewer's interest test. Membership changes travel through paths the core already has. Gaining sight
  is a catch-up add with every field (COL §4). Losing sight is a remove chunk carrying only the slot (COL §3), so
  a client cannot tell "left my interest" from "deleted".
- **Design rule kept from AC §1.4.** Every test is optimistic: when in doubt the record is sent. A pessimistic
  test causes pop-in for every player without a modified client; an optimistic one leaks only inside its margin.

---

## 2. Membership: cells, hysteresis, look-ahead

**Mechanism** (SS §7.2, measured there).
- The world is a grid of square cells of side R, where R is the collection's `interest.radius`.
- Each viewer subscribes to the 3 × 3 block around its focus cell. Each record is filed under the cell holding its
  position field.
- A record is a member for a viewer while its cell is inside the viewer's block, or inside the one-cell ring
  around it if it was already a member (hysteresis). It leaves only when it is two cells away.
- Work happens only when a viewer or a record crosses a cell boundary. Exact distance is not used for membership;
  it sets priority inside the budget (§5).

**Focus.** `Player.ReplicationFocus` when set, otherwise the character's root part: the engine's own streaming
focus (SS §8.2; `Player.ReplicationFocus` is scriptable, `Players` capability, verified in the dump). Using it keeps
Lync's view consistent with what the engine streams.

**Look-ahead** (AC §1.1, Riot's version 3: "bigger than the expected ping time").
- A record's filing position is p + v × `interest.lookAhead`, where v is its position change per state tick.
- Lync takes v from the position field's last two state-tick values, so no velocity field is needed.
- A record moving toward a viewer therefore enters that viewer's block early, covering the latency between the
  server's decision and the client rendering it.

**Cost.**

| Item | Native | Interpreted | Source |
|---|---|---|---|
| Cell subscription upkeep, 200 viewers × 10,000 entities, R = 256 | 0.009 ms/pass, plus 0.01–0.19 ms of cell moves | 0.012 ms/pass | SS §7.2 (measured) |
| Exact per-viewer distance membership, same load | 3.85–6.61 ms/pass | 5.5–5.85 ms/pass | SS §7.2 (measured) |
| Look-ahead | one vector multiply-add per moving record per state tick | — | derived |

- **Bytes.** Cells over-include about 2.6× against an exact circle of R (SS §7.2). Under the state budget,
  over-included records cost bytes only when they are dirty *and* win priority; distance priority (§5) gives them
  low weight.
- **Churn.** Without hysteresis, a record on a boundary toggles every tick: a remove plus a full catch-up add,
  10–30 B, instead of a 3–8 B update (SS §7.3). The one-cell ring bounds this to one leave per two cells of
  travel.

**How it fails.**
- A record more than one cell from the block's edge is invisible to that viewer even when a wall doesn't block it.
  So R must be at least the game's useful sight range for that collection. This is a developer setting, and pop-in
  is the symptom.
- Look-ahead leaks a record up to `lookAhead` × speed early, by design.

---

## 3. Encoding under per-viewer membership

**Problem.** The core encodes reliable changes once per audience partition (COL §4) and `:newest()` rows once per
tick (COL §5). Per-viewer membership means two viewers in one partition hold different subsets of its records.

**Options.**
- (a) **Per-record byte-aligned pieces, copied per viewer.** This is COL §5's model for rows, extended to reliable
  updates.
  - Encode-once holds.
  - Each update is padded to a byte, which costs 5.4–8% on rows (COL §5).
  - Column coding *across* records is lost. How much that costs for reliable updates is unmeasured.
- (b) **Per-viewer encoding.** Ruled out on CPU: 48 against 25 ns per record native, 237 against 43 interpreted
  (SS §3.6).
- (c) **Cell chunks.**
  - Each flush, encode the changes of the records filed in one cell (per audience partition) once, as one chunk:
    column coding inside the cell is kept, and the chunk sits on a byte boundary like every downstream chunk.
  - A viewer's frame copies the chunks of the cells in its 3 × 3 block.
  - Records held only by hysteresis travel as pieces, as in (a).
  - This is ReplicationGraph's per-cell lists (SS §2.1), applied to Lync's chunks.

**Recommendation: (c), falling back to (a) for pieces.**
- Membership comes from cells (§2), so viewers with the same block hold exactly the cell chunks of that block.
- A cell-level PVS (§4) keeps whole cells in or out, so it preserves chunks.
- Only a per-pair predicate (§4) or a `seen` field (§7) forces pieces.
- **Cost:** up to 9 `buffer.copy` calls per viewer per changed cell per flush, at 25–44 ns per call (SS §3.6) —
  about 0.2–0.4 µs per viewer. Plus one piece copy (27.6 ns native, COL §5) per hysteresis-held record.

**Membership changes use existing chunks.**
- Entering: a catch-up add with every field, in the viewer's own state chunk, ahead of the shared cell chunks
  (COL §3–§4).
- Leaving: a remove chunk with the slot only.
- A record moving between cells: remove or add only for viewers whose block covers one cell and not the other.
  Every other viewer just takes the new cell's chunk.

**Finding: generations need to travel in adds** (inference from the design text, unverified until milestone 4
builds it).
- COL §2: "Both ends count adds per slot modulo 4 … Only unreliable rows carry the 2-bit generation", and rows are
  encoded once per tick.
- So a row's generation is a server-wide count per slot. A viewer that loses sight of a record and regains it
  (audience change today, interest constantly) receives a second add while the server-wide count is unchanged.
  Its own count is then ahead of the rows' generation, and it drops every later row of that record as older
  (COL §2).
- **Fix:** each add carries the slot's current `gen:u2`, and the client stores it instead of counting.
  - Cost: 2 bits per add, nothing per row.
  - It also removes the need for both ends to agree on a count.

---

## 4. Narrowing: a build-time PVS bake, run-time raycasts, a predicate

Cells decide who could see a record by distance. Narrowing removes cells or pairs that walls hide. All three
forms are optional, and each must stay optimistic (§1).

### 4.1 What a build can read from the place

Verified by re-running `place_read.luau` under Lune 0.11.0 on a place it serialises and reads back
(`place_read.out`):
- **Readable:** a `Part`'s `Size`, `CFrame`, `Shape`, `CanCollide` and `Transparency`. These are enough to treat
  blocks as boxes, and balls and cylinders by their bounds.
- **Not usable:**
  - `MeshPart` and `UnionOperation` geometry: `PhysicalConfigData` and `MeshData` come back as opaque binary
    strings, and `MeshId`/`AssetId` read as missing in a place Lune built.
  - Terrain: `SmoothGrid` is an opaque string, and `Terrain:ReadVoxels` doesn't exist in Lune.
  - Raycasting: Lune has no `WorldRoot:Raycast`.
- **Bake rule:** only opaque collidable parts occlude (`Transparency == 0`, `CanCollide`). Meshes, unions, terrain
  and moving or scripted parts (doors, destructibles) never occlude, because a bake cannot know their state. Every
  rule errs toward visible.

Whether a Studio-saved place exposes `MeshPart` content any better through rbx-dom is unverified.

### 4.2 Bake cost and table size (measured)

`pvs_bake.luau` runs native on a synthetic, densely walled box map:
- occluders are axis-aligned boxes, tested in 2D (XZ) at eye height;
- rays walk a 16-stud occluder grid;
- a cell pair is visible if any of S × S sample rays per cell is unblocked.

| Map (studs) | Cell | Cells | Boxes | Samples | Bake time | Rays | Rays/s | Table |
|---|---|---|---|---|---|---|---|---|
| 1024² | 32 | 1,024 | 1,500 | 1 × 1 | 0.17 s | 0.52 M | 3.07 M | 128 KiB |
| 1024² | 32 | 1,024 | 1,500 | 2 × 2 | 2.16 s | 8.2 M | 3.80 M | 128 KiB |
| 1024² | 64 | 256 | 1,500 | 3 × 3 | 0.65 s | 2.5 M | 3.89 M | 8 KiB |
| 2048² | 64 | 1,024 | 6,000 | 1 × 1 | 0.20 s | 0.52 M | 2.68 M | 128 KiB |

- **Size.** N cells need N² bits: 1,024 cells take 128 KiB; 4,096 cells (64 × 64) take 2 MiB
  (`interest_cost.out`). The table is symmetric, so storing half saves 2×; run-length encoding would save more on
  sparse maps (unmeasured).
- **Time.** Seconds for a realistic grid at build time. That is cheap in CI and too slow for a Studio plugin's
  on-edit path, so the bake belongs to `lync build` or a plugin "Bake" action.
- **Caveats.** The map is synthetic and maze-like, so its visible fraction (0.2–6.4%) says nothing about real
  maps. A 3D bake (multi-storey maps) costs more per ray and is unmeasured.
- **Where the table lives.** Server-only. Either a `ModuleScript` under `ServerStorage` returning a base64 string,
  decoded at start with `EncodingService:Base64Decode` (security None, verified in the dump; whether a string
  this large is accepted is unverified), or a data store value (≤ 4,194,304 characters per key, documented),
  written by CI.

### 4.3 Run-time checks

- **PVS test per pair:** 10.8 ns native, 61.6 interpreted (`interest_cost.out`). At cell granularity it is a test
  per (viewer cell, source cell), so cell chunks survive (§3).
- **`WorldRoot:Raycast`:** security None and **thread Safe** (verified in the dump), so it can run from parallel
  Luau. Its cost is reported, not documented: about 10.7 µs (2,500 studs) and 17.4 µs (5,000 studs) per ray, from
  one unrepeated devforum timing ([thread](https://devforum.roblox.com/t/most-efficient-raycast-length/2096868)).
  - So 20,000 candidate pairs at 10 Hz would be 2–3.5 s of CPU per second: unaffordable, as AC §1.4 predicted.
  - Raycasts are only usable on the few pairs left after cells and PVS, under hysteresis.
  - Lync's own cost on a real server can be measured with an Open Cloud Luau Execution task against the game's
    place. Whether spatial queries work there without physics running is unverified.
- **Predicate** `(viewer, key, record) -> boolean`, for game logic such as stealth or smoke.
  - It runs only on pairs that passed cells and PVS, at most `interest.predicateRate` times a second per pair.
  - A pair it rejects is not sent. Its records travel as pieces (§3), since the predicate is per pair.
  - A predicate that throws or yields is reported natively, like a validator (`v5.md` §6.1), and the pair is kept,
    so the result stays optimistic.

---

## 5. Distance priority inside the state budget

**What changes from the core.**
- The core selects `:newest()` rows per viewer from one FIFO per collection, by `priority` × age (COL §7).
- Distance, owner and first-send weights change per viewer every tick, which a FIFO cannot hold. So `interest`
  replaces the selector through the scheduler seam (`v5-extensions.md`).

**Mechanism** (SS §3.3–§3.5, measured there).
- Per (viewer, pending record), each state tick:
  `acc += priority × distanceFactor × ownerBoost × firstSendBoost`.
- `acc` resets to 0 when the row is *sent*, not acked.
- Selection is a 40-bucket pass over ⌊log2 acc⌋, not a sort.
- `distanceFactor` is the Iris sphere (SS §2.1): 1.0 inside R/4, falling with the square of distance to 0.2 at R,
  and 0.1 beyond (members held by hysteresis).
- `ownerBoost` is ×4 for the viewer's own records. `firstSendBoost` is ×4 on the first row after a catch-up add.
- A pending record older than 2 s goes first (`maxPendingAge`, SS §3.4).

**Cost** (SS §3.5).
- The bucket pass costs 20–60 ns native per (viewer, pending record), and visits only pending records.
- 100 viewers × 300 relevant records at 20 Hz is about 35 ms/s, 3.5% of a core. A comparator sort costs 3.5–7× as
  much.
- Exact distance is computed here, for pending records only, so membership (§2) never needs it.

**Fairness** (SS §3.4, simulated).
- At 50% of demand, accumulators keep far records at a mean of 1.1 ticks and p99 3 ticks, with own and near
  records at 0.
- Strict priority starves far records completely.

**What it protects.** Nothing directly: priority shapes freshness, not secrecy. It makes the over-inclusion of
cells (§2) cheap in bytes, so R can be large enough to avoid pop-in.

---

## 6. Interaction with decoys and per-player variants

### 6.1 Decoys (INT §8)

- **Placement must pass the same interest test as real records.** A real record outside a viewer's block (or in a
  cell the PVS hides) is never sent. So a decoy there would be the only record of its kind outside the viewer's
  region, and anything reading raw state could filter it by position against its own focus.
- **Rule:** Lync applies §2 and §4 to every decoy the behaviour returns.
  - A decoy that fails throws `decoyOutsideInterest` in the behaviour's thread and is removed. This is the same
    channel as `decoyKeyLive` (INT §8): a mistake in the game's declaration, not a fact about a player.
  - Exact trigger: the decoy's filed cell is outside the viewer's block and hysteresis ring, or the PVS bit for
    (viewer cell, decoy cell) is 0.
  - Cost: one cell test, plus one PVS bit test, per decoy per state tick.
- **Consequence for behaviours.** AC §2.1's "beyond max draw distance" placement is not available inside an
  interest collection. Placements must lie within R where honest rendering ignores them: behind the viewer,
  inside geometry, or beyond the game's own render distance when that is shorter than R.
- **Encoding.** INT §8 re-encodes each changed partition chunk per viewer with decoys mixed in. Under cell chunks
  (§3) that becomes: per viewer with decoys, one re-encode of each changed cell chunk that holds one of its decoys.
  This is smaller than a partition re-encode, because a decoy sits in one cell. The viewer leaves shared copying
  for those cells only.
- **Unchanged tell:** two colluding accounts comparing key sets (INT §8).

### 6.2 Per-player shard variants (R7, refused)

- Cell chunks, like every shared chunk, are encoded in one field order.
- A per-player field-order variant needs one encode per distinct variant per cell chunk. With V variants that is
  V× the encode CPU and the chunk memory, the same bytes, and no sharing across variants.
- Interest doesn't change R7's recorded reasons. It raises R7's CPU cost by V for every interest collection,
  which a re-judgment of R7 should include.
- The per-server id permutation is unaffected: it is per server, so every viewer shares it.

---

## 7. Visibility classes (U8): owner, team, gated, seen

**Problem.** A record can be visible while some of its fields should not be: enemy ammo and cooldowns, health
above a threshold, a loadout before it has been seen (AC §1.4, field-level visibility). Unreal (`COND_OwnerOnly`
and others) and Mirror (`syncMode` Owner) offer per-field conditions (SS §2.1, §2.7). The core today has only
whole-record audiences (COL §4).

**Declaration.**
- The class is a field modifier in the shared schema, because the client's type depends on it.
- Which viewers belong to a class is bound on the server view, so policy never ships.

| Modifier (shared schema) | Server binding (server view) | A viewer receives the field when | Client type |
|---|---|---|---|
| `:owner()` | `Net.c:owner(fn(key, record) -> Player?)` | it is the record's owner | `T?` |
| `:team()` | `Net.c:team(fn(key, record) -> Target)` | it is in the record's team target | `T?` |
| `:gated()` | `Net.c:gate(field, fn(key, record) -> boolean)` | the gate returns true, or it is in the team (else owner) class | `T?` |
| `:seen()` | — | the pair has passed the narrowing test (§4) at least once since the record was last added for it | `T?` |

- An unbound `:owner()` or `:team()` modifier means no viewer receives the field. That is a declaration mistake,
  reported natively once at first use.
- The modifiers go into the schema hash: one class byte per record field, beside the `newest` byte of `v5.md`
  §4.7. This bumps the serialization version.
- They are refused where `:newest()` is refused, and on decoy-referenced fields.

**Encoding** (each class keeps encode-once at its own granularity):

| Class | Unit encoded once | Who receives it | Extra wire |
|---|---|---|---|
| owner | one piece per changed record | its owner | none |
| team | one chunk per (cell, team) | the team's members holding the cell | none |
| gated | in the public cell chunk while the gate is true | the cell's holders | 1 presence bit per gated field per update, so that "hidden again" decodes as `nil` |
| seen | one piece per changed record | viewers whose seen bit is set | none |

- The gate runs once per changed record per state tick, never per viewer.
- `seen` needs one bit per (viewer, record): 12.8 KB for 100 viewers × 1,024 slots.

**Cost.**
- Computing the full 4-class mask per (viewer, record) pair costs 19.6 ns native and 96 ns interpreted, 0.31 ms
  per pass for 100 viewers × 160 relevant records (`interest_cost.out`).
- Only `seen` is per pair at run time; owner, team and gated are per record, so most collections pay far less.

**What it protects, and how it fails.**
- It withholds field values from viewers outside the class, against raw-state readers of Lync state.
- A gated field reveals that its gate flipped ("health crossed 30"), by design.
- Game UI must handle `nil`, which the `T?` type enforces on both solvers.
- A `:team()` binding that returns the wrong group leaks to that group.
- **Least developer work:** one modifier per field and one binding per collection; no change at call sites.

---

## 8. Scoped events `:about(ref)` and their lint (U8)

**Problem.** Riot's worst Fog-of-War bug class was events about an actor sent to viewers who couldn't see it:
the "Start Spike Defuse" RPC (AC §1.1). An event fired to `Lync.all` with an enemy's key tells every client where
that enemy is, whatever interest withholds.

**Mechanism.**
- Declared on the server view: `Net.hit:about("target", "fighters")`, the server-sent twin of
  `Net.strike:refers(...)` (INT §8).
- An unknown field or collection throws `unknownField` at the caller, as `refers` does.
- At flush, each message's target is intersected with the viewers that hold the record named by its `target`
  field: in the record's audience and passing interest.
  - Viewers outside the intersection never receive the message; it is not queued.
  - These drops are counted, `scopedDropped.<namespace>.<definition>` (§9). A count, not a fact: nothing a
    player sent caused it.
- **Order.** State chunks precede runs in every reliable frame (`v5.md` §4.1). So a viewer gaining sight of the
  record in the same flush receives the catch-up add before the event, and the event never names an unknown slot.

**Cost.**
- One holder lookup per (message, target viewer), the same O(1) bit test as the PVS test: 10.8 ns native and
  61.6 ns interpreted per test (`interest_cost.out`).
- Scoped messages to different holder sets become separate runs, so frames carrying them leave `FireAllClients`
  (`v5.md` §4.2). The bytes are unchanged.

**What it protects, and how it fails.**
- It closes event leaks about records interest withholds.
- An event that should be scoped but isn't still leaks. That is what the lint is for.
- An effect with a duration ("defusing since t") must be state on the record, so catch-up shows it. An event can't
  be repaired after a relevancy gap (AC §1.4).

**Lint `unscopedRef`** (build check; `lync.toml` `check.unscopedRef = "off" | "warn" | "error"`, default `"warn"`).
- **Exact trigger:**
  - a server-sent event or request whose `data` holds a field whose codec serialises (`v5.md` §4.7) identically to
    some collection's `key` codec; and
  - no `:about("<field>", …)` call on that definition in the scanned server scripts.
- **Evidence:** definition, field path, collection; the Diagnostic `range` at the definition's schema line.
- **Known causes without a leak:**
  - a field that shares the codec but isn't a key (a `t.int(1, 2^40)` score, say);
  - an event deliberately sent to every viewer.
  - The check reports the codec match; whether the field is a key, only the game knows.
- **Cost:** build time only — one codec comparison per event field per collection, and a text search of the
  scanned server scripts, the same pass as reachability (INT §3).

**Not built: AC §1.4's "duration" lint** (an `:about` event whose effect has a duration should be a field). The
schema doesn't say what a field means, so there is no exact trigger (principle 5). It stays documentation:
anything that must survive a relevancy gap is state.

---

## 9. Relevancy counters (U13)

**Why counters, not facts.** In `v5.md` §7.2 a fact records what another player sent. Relevancy is the server's
own behaviour, so it goes in `Lync.counters` (`v5.md` §7.4), alongside `rowsDeferred`, not through
`Lync.observe`. Riot's lesson (AC §1.1) is that these numbers catch relevancy bugs: a stuck sound loop showed up
as "significantly higher relevancy time for Jett players".

| Counter (`<field>.<namespace>.<collection>`) | Increments by | Reads as |
|---|---|---|
| `relevantPairTicks` | the viewer's member count, once per viewer per state tick | divided by (viewers × ticks), the mean relevant-set size; a jump flags over-inclusion |
| `interestEnters`, `interestLeaves` | each catch-up add and each remove caused by interest | churn; a high leave rate at steady load points to R too small or hysteresis defeated |
| `narrowedPairs` | each pair cells admitted but the PVS or the predicate removed | how much narrowing buys; zero means the bake isn't loaded |
| `predicateErrors` | each predicate throw or yield (also reported natively) | broken game predicates |
| `scopedDropped` (`.<namespace>.<definition>`) | each (message, viewer) a scoped event skipped (§8) | which events scoping actually filters |

- `Lync.counters(player)` gives the same totals per viewer, so an outlier player (a focus stuck far away) is
  visible, as the inspector already polls at 4 Hz (`v5-tooling.md` §5).
- **Cost:** one add per viewer per state tick, plus one per membership change: 0.1 ns per pair native and 0.2 ns
  interpreted, amortised over 160-member sets (`interest_cost.out`). A snapshot copies five more numbers per
  collection.
- **Names** follow `v5.md` §7.1's rule: they state what was counted, never a judgement.

---

## 10. Options

**Run time:** one server-view call per collection, `Net.fighters:interest({ … })`. Interest is server policy, so
it never ships in shared code (`v5.md` §7.5's rule for integrity policy).

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `position` | field name: a top-level `t.vector3`, `t.vector3f32` or `t.cframe` field | — | — | required | none |
| `radius` | number (real) | studs | 8–4096 | required | the cell side. Larger means more members: more catch-up bytes, more pairs in the priority pass (20–60 ns native each, §5) |
| `lookAhead` | number (real) | s | 0–1 | 0.2 (chosen, unmeasured: above typical one-way latency, Riot's rule) | one multiply-add per moving record per state tick; leaks up to `lookAhead` × speed early |
| `focus` | `(player) -> Vector3?` | — | — | `ReplicationFocus`, else the character's root part | one call per viewer per state tick; nil keeps the last cell |
| `pvs` | buffer (a table from the build, §4.2) or nil | — | N ≤ 65,536 cells | nil | N²/8 B of server memory; 10.8 ns native per (viewer cell, source cell) test |
| `predicate` | `(viewer, key, record) -> boolean` or nil | — | — | nil | one call per candidate pair per period; its collection's records travel as pieces (§3) |
| `predicateRate` | number (real) | Hz | 1–20 | 10 (SS §7.2: "at ≤ 10 Hz") | as `predicate` |

Field modifiers (shared schema, §7): `:owner()`, `:team()`, `:gated()`, `:seen()`. Server bindings: `owner`,
`team`, `gate`; scoped events: `:about(field, collection)` (§8).

**Constants** (`v5.md` §4.9's rule: none is a knob):

| Constant | Value | Derivation |
|---|---|---|
| hysteresis | a member leaves only when two cells away | SS §7.2 recommendation |
| distance factor | 1.0 inside R/4, squared falloff to 0.2 at R, 0.1 beyond | Iris sphere defaults (SS §2.1) |
| owner boost, first-send boost | ×4 each | SS §3.3 (Iris `SphereWithOwnerBoost`; Netcode for Entities `FirstSendImportanceMultiplier`) |
| `maxPendingAge` | 2 s | SS §3.4 |

**Build time** (`lync.toml`):

| Key | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `[[pvs]] place` | path to a built `.rbxl` | — | — | none (no bake) | — |
| `[[pvs]] cell` | integer | studs | 8–256 | 32 | N = (map side / cell)² cells; table N²/8 B |
| `[[pvs]] samples` | integer | rays per axis per cell | 1–4 | 2 | samples⁴ rays per cell pair: 0.2–2.2 s for 1,024 cells at 3–4 M rays/s native (§4.2) |
| `[[pvs]] output` | path to a server-only module | — | outside replicated folders | none | the table's size, base64 (4/3×) |
| `check.unscopedRef` | `"off"`, `"warn"`, `"error"` | — | — | `"warn"` | build time only (§8) |

---

## Implications

Ranked for the architect. Each points at its findings.

1. **Specify `interest` now as cell subscriptions** (cell = R, a 3 × 3 block, a one-cell hysteresis ring) at the
   engine's replication focus, with look-ahead by finite-difference velocity. The measured upkeep is about 0.01 ms
   per pass for 200 × 10,000 native (§2).
2. **Encode interest collections as cell chunks**, copied per viewer (up to 9 copies per changed cell), with
   per-record pieces only for hysteresis-held records, predicates and `seen` fields. Encode-once and column coding
   inside a cell survive (§3).
3. **Fix generations before milestone 4:** carry `gen:u2` in every add instead of counting adds on both ends. As
   written, a viewer that regains sight of a record would drop that record's rows (inference from COL §2 and §4;
   2 bits per add) (§3).
4. **Ship the PVS as a build-time bake** in `lync build`, never on the plugin's edit path. Parts only occlude, and
   meshes, unions, terrain and moving parts never do, which keeps it optimistic. A 1,024-cell table is 128 KiB,
   baked in 0.2–2.2 s, stored server-side (§4.1–§4.2).
5. **Keep run-time raycasts off the per-pair path.** At a reported 10–17 µs per ray, they fit only on the pairs
   left after cells and PVS. Measure the real cost with a Luau Execution task before specifying a rate (§4.3).
6. **Replace the core's FIFO selector with distance accumulators and a 40-bucket pass** for interest collections,
   through the scheduler seam (§5).
7. **Make decoys pass the interest test,** with `decoyOutsideInterest` as a caller error. Document that
   "beyond draw distance" placements don't exist inside an interest collection (§6.1).
8. **Add the four visibility classes** (`:owner`, `:team`, `:gated`, `:seen`) as shared-schema field modifiers
   typed `T?` on the client, with server-view bindings. They go into the schema hash (§7).
9. **Add `:about(field, collection)` on the server view, plus the `unscopedRef` build check** (default warn). The
   duration lint has no exact trigger and stays documentation (§8).
10. **Count relevancy, don't report it:** `relevantPairTicks`, `interestEnters`/`interestLeaves`, `narrowedPairs`,
    `predicateErrors`, `scopedDropped`, per collection and per player. They cost one add per viewer per tick (§9).
11. **Re-judge R7 with interest in mind:** per-player field-order variants would multiply cell-chunk encode CPU and
    memory by the variant count (§6.2).

---

# Rewind and timing

Researcher findings, 2026-10-15, appended by the agent that owns D2 (`rewind`), U15 (streaming guidance and staged
release) and the `PlayerGui` variant timing rule (`research/security-refusals.md` §3–§4, R7). Labels as above.
Probes added to `.data/docs/probes/interest-rewind/` (Luau 0.742 built from `.data/projects/luau`, Release, on the
same 2.1 GHz Xeon, best of 5; native is `-O2 --codegen`, which Roblox runs on servers only):
- `rewind_cost.luau`, `.out`: the earlier probe, re-run on 0.742 (it matched the 0.740 figures within noise).
- `rewind_full.luau`, `.out`: the design below: 24 B slots, perceived-tick resolution, rotation decode and nlerp,
  the "as received" mode, an error simulation and a memory table.
- `stream_read.luau`, `.out`: what a Lune 0.11.0 build host reads from a place file for the U15 checks.

Roblox documentation is quoted from `Roblox/creator-docs` at commit `efe8741` (2026-10-15); API tags from the
pinned dump (Roblox 0.741.19).

## Checklist (rewind and timing)

- [x] §11 D2 `rewind`: rings at the perceived tick
- [x] §12 U15: `StreamingTargetRadius` and staged release
- [x] §13 `PlayerGui` variant timing
- [x] Implications (rewind and timing)

---

## 11. D2 `rewind`: rings at the perceived tick

### 11.1 What it protects, and what it is not

- **The claim it prices.** A client says "I hit record k" or "I fired from here". The server must judge that
  against the state *that client was shown*, not the state now; otherwise every honest player with latency misses
  (Bernier's lag compensation, AC §4.1).
- **The flaw it removes.** Community rewind libraries take the rewind time from the client, clamped to a window
  (RollbackHitbox: `clientTimestamp` "clamped to [0, MAX_REWIND_SECONDS]", AC §4.1, reported). A clamped client time
  is a free choice of any past position inside the window: the "backtrack" advantage. R20 refuses it.
- **What Lync adds.** Lync sent every state frame and receives every ack, so the server can name the state frame a
  client had applied when it sent a message. The rewind tick is derived from Lync's own frames and the engine's ping,
  never stated by the client.
- **What it is not.** Lync returns state at a tick. The game decides the hit: hitbox shape, ray test, tolerances,
  world occlusion, and anything done about a miss (R36, `v5-extensions.md`: "the game decides what a hit is").

### 11.2 What Lync records, per tracked entity and per tick

- **Declared on the server view**, because it is server policy and the client never needs it:
  `Net.fighters:rewind({ fields = { "position", "look", "alive" }, maxRewind = 1 })`. Nothing goes into the schema
  hash.
- **One slot per record per state tick**, written after the tick's `:newest()` rows are encoded, for every tracked
  record (changed or not), so a read is an index, never a search:

  | Bytes | Content | Why |
  |---|---|---|
  | 4 | state tick T (u32) | a slot is valid only if it holds the tick asked for |
  | 12 | position x y z (f32) | the *decoded quantized* value the row carried, which is what the client saw (a `t.vector3(-2048, 2048, 1/32)` value is exact in f32) |
  | 4 | rotation as its `t.rotation(9)` code (30 bits used) | 4 B instead of a 16 B quaternion; decoded only when queried |
  | 1 | up to 8 boolean `:rewind()` fields | `alive`, `crouched` |
  | 3 | padding | keeps slots aligned |

  Other declared fields add their single-row width rounded up to bytes. The ring holds
  K = ⌈(`maxRewind` + 0.25 s) × `stateRate`⌉ + 2 slots per record: the window, the 0.25 s extrapolation cap of the
  `interpolation` extension, and the two lerp neighbours.
- **Per player**, a map from state-frame seq to (state tick, send time), L = K + 17 entries of 12 B. The notify ring
  already holds 17 frames (COL §6); rewind extends the per-frame tick and send time back to `maxRewind`.
- **Per (viewer, record), only in "as received" mode (§11.5):** the ticks of the last M rows of that record the
  viewer acked, M = ⌈`delay` × `stateRate`⌉ + 2 (4 at 20 Hz with 0.1 s), u32 each, plus a 1 B head.

### 11.3 How the perceived tick is established

Two ticks matter, because the client shows `:newest()` fields `delay` behind and applies reliable fields at once.

**Inputs, all on the server:**
- s, the newest state-frame seq acked in the header of the frame that carried the message (`v5.md` §4.1 `ack`);
  T_s its state tick and t_s its send time, from the per-player map.
- t_r, `GetServerTimeNow()` when the frame was decoded.
- rtt, the round trip: `Player:GetNetworkPing()` ("round-trip, isolated network latency in seconds … doesn't involve
  data deserialization or processing", documented, `Player.yaml`), raised to Lync's own ack round trip where that is
  larger, by at most `rttSlack`. The ack round trip is the windowed minimum of (arrival of the first frame acking
  seq n) − t_n. Engine ping excludes processing, so it is a lower bound on what a remote sees.
- D, the interpolation delay the client used (below).

**Formula (fractional ticks):**
- held = clamp(t_r − t_s − rtt, 0, h_max), how long the client had held frame s when it sent; h_max is the time
  until the next state frame to this player was sent, plus one client flush (1/60 s). The unclamped value is kept as
  evidence.
- **Q = T_s + held × `stateRate`**: the newest state the client had applied. Reliable fields are returned at Q.
- **P = Q − D × `stateRate`**: the tick the client was rendering. `:newest()` fields are returned at P.
- **Window:** [P − u, P + u] with u = (jitter + 1/60 s) × `stateRate`, clamped to
  [T_s − D × rate, T_s + (h_max − D) × rate]. Jitter is the mean absolute deviation of the ack round trip. The game
  may test a hit against the whole window (§11.6).

**Rule: a frame carrying a perceived message carries its ack.** Today only the first frame of a flush carries a
full ack, and only when a state frame arrived since the last one; the rest carry `'0'` (`v5.md` §4.1). With `'0'`
the server would use the newest ack it holds, which is wrong in two ways: the frame that carried the real newest ack
may be an unreliable frame that was lost (P too old), or a frame sent later on the other lane may have arrived first
(P too new). So a client definition declared `perceived = true` (shared schema, hashed, since the client must act on
it) makes every frame holding one of its messages carry `'1' seq received` whenever any state frame has arrived.
- Cost: 28 bits on each such frame that would have carried `'0'`. At 10 claim frames a second, at most 35 B/s up.
- An undeclared definition can still be rewound; its result has `exact = false`.

**Rule: D is chosen by the server, never by the client.** The `interpolation` extension as scoped adapts its delay
from jitter the client measures (`v5-extensions.md`: max(2/rate, 0.1 s) + 2 × jitter). A client-chosen D is a
client-stated rewind offset bounded by a formula, which is R20 again. So:
- the server computes D per player with the same formula, using its own jitter estimate (the deviation of the ack
  round trip, which includes both directions, so it errs toward a longer delay);
- it sends D to that client, in 4 ms units, in a `delay u8` field added to `RATE` (control types are a full u3, so a
  new type costs a wider field); this changes protocol version 1;
- D moves by at most one unit per second and takes effect at the tick named in the message; the server keeps a log
  of (tick, D) back to `maxRewind`, so P uses the D in force at that time.
- A game that interpolates with its own code sets `delay` to the constant it uses. Lync can't see it.

### 11.4 The engine's interpolation delay

- **Searched:** creator-docs at `efe8741` for "interpolat" across classes, guides and Server Authority pages;
  devforum for physics replication, character interpolation and buffers.
- **Found:**
  - Server Authority: other characters "will render slightly in the past" (documented,
    `projects/server-authority/techniques.md`), with no figure.
  - No engine property sets or reports it. `Workspace.InterpolationThrottling` "no longer takes effect"
    (documented).
  - Roblox replaced its physics replication backend for "eventual consistency" from 2026-06-15
    (`Workspace.ImprovedPhysicsReplication`; staff post,
    [thread](https://devforum.roblox.com/t/upcoming-improvements-to-physics-replication/4675512), 2026-06-09). The
    post gives no delay figure, and any delay measured before it may no longer hold.
  - Community statements only: "a large, non configurable interpolation delay … designed primarily for mobile
    devices" (Chrono, [thread](https://devforum.roblox.com/t/chrono-drop-in-custom-physics-replication-library/3873294),
    2025-08-10, reported, no figure); "no fixed period … varies with distance and ping"
    ([thread](https://devforum.roblox.com/t/character-interpolation-period/1523855), 2021, reported).
- **Status: unverified.** It can't be measured outside a live engine, and the only candidate figure (a 2021 "100"
  with no unit) predates the new backend.
- **Design rule that holds either way:**
  - Lync records are rewound with Lync's own D (§11.3), which is exact by construction. The engine delay never
    enters that path.
  - For engine-replicated parts (characters the game doesn't render from Lync records), the delay is a game option,
    `engineDelay`, never a Lync constant, with a spread `engineSpread`. Lync returns the state at both ends of
    [t_r − rtt/2 − engineDelay − engineSpread, t_r − rtt/2 − engineDelay + engineSpread]. A hit test against the
    swept span is correct for any true delay inside it.
  - The docs give a calibration recipe for a test server: the server keeps a ring of a character's root `CFrame`
    by `GetServerTimeNow()`; a test-only client script reports the rendered `CFrame` of another character with its
    own `GetServerTimeNow()`; the server finds the lag that fits best. Its median gives `engineDelay` and its
    spread `engineSpread`. These reports are client-stated, so they are for calibration only, never enforcement.
  - Games that need exact rewind of characters render them from Lync records (AC §1.2).

### 11.5 Truth at P, or what the viewer had

**Problem.** Under the state budget a viewer doesn't get every row (COL §7: a 100-player shooter's rows run at about
13 Hz instead of 20), and rows are lost. The client interpolates between the samples it *received*. The server's
ring holds the truth for every tick. Lerping the ring at P differs from what that client showed whenever rows
were missing around P.

**Measured** (`rewind_full.out`): a target strafing at 16 studs/s, reversing every 0.2–0.6 s, 20 Hz, D = 2 ticks.
Error of truth-at-P against the client's own samples:

| Rows missing | Mean | p99 | Max |
|---|---|---|---|
| 0% | 0 | 0 | 0 |
| 5% (loss) | 0.005 studs | 0.16 | 1.24 |
| 33% (≈ the 100-player shooter's deferral) | 0.084 | 1.33 | 4.89 |
| 50% | 0.245 | 2.55 | 8.66 |

**Options.**
- (a) **Truth:** lerp the ring at P. Exact when the viewer got every row; at 33% missing, p99 1.3 studs, a large
  share of a 2-stud-wide root part.
- (b) **As received:** bracket P with the ticks of the rows this viewer acked (the per-pair ring of §11.2), then lerp
  the ring at those two ticks, as the `interpolation` extension did. It is exact for Lync's interpolation, because
  the server runs the same sampling function on the same inputs.
  - Cost: 8.3–8.8 ns native per acked row recorded, done where notify already walks the rows of each acked frame,
    plus the per-pair memory.
  - A record the viewer never received in the window returns `notHeld`. That is a fact worth having: the client
    named a record Lync never sent it, which on an unmodified client happens only when the game also shows that
    entity through Workspace or another remote.
- **Recommendation: (b) when the collection uses the `interpolation` extension, (a) otherwise** (a game's own
  interpolation is invisible to Lync).

### 11.6 What Lync returns, what the game decides

```luau
Net.strike:connect(function(player, shot)
	local seen = Net.fighters:perceived(player) -- only inside the handler's synchronous part
	local target = Net.fighters:rewound(seen, shot.target)
	if target.ok then
		-- game code: its own ray test against target.value.position, with its own tolerance
	end
end)
```

- `perceived(player)` returns a frozen value: `tick` (P), `applied` (Q), `low`, `high`, `ackSeq`, `ackTick` (T_s),
  `held`, `heldRaw`, `ping`, `rtt`, `delay` (D), `exact` (the frame carried a full ack), `expired` (P older than the
  ring). It may be stored and used later, while its ticks are still in the ring. Called outside a handler it throws
  the caller error `perceivedOutsideDispatch`.
- `rewound(seen, key)` returns `{ ok: true, value }` with the declared fields (`:newest()` fields at P, reliable
  fields at Q) or `{ ok: false, error }` with `"expired"`, `"notHeld"` or `"unknownKey"`, the one error model of
  `v5.md` §3.5. `rewoundSpan(seen, key)` returns the two records at `low` and `high`.
- Interpolation per codec: positions, `t.number` and `t.angle` lerp; `t.rotation` and `t.direction` nlerp; every
  other field holds the value at ⌊tick⌋.
- `Net.fighters:at(tick, key)` reads the truth ring at any tick in the window.
- **No new `Lync.observe` fact.** Lync can't know a message is a hit claim, so it states no trigger about one. The
  evidence goes in the value the game asked for. Acks of frames never sent are already `impossibleAck`.
- **The game decides:** the hit test and its tolerance, world occlusion (Roblox can't rewind geometry), what a miss
  or `expired` means, and anything done about a player.

### 11.7 Cost

Probes `rewind_full.out` and `rewind_cost.out`, two runs each; native is the server figure.

| Operation | Native | Interpreted |
|---|---|---|
| push, one record per tick (24 B slot) | 9.5–10.5 ns | 130–138 ns |
| perceived tick (map lookup, clamps, window) | 26–32 ns | 130–134 ns |
| truth sample: lerp xyz, two rotation decodes, nlerp | 80–87 ns | 381–388 ns |
| position-only lerp (the earlier 16 B slot) | 26–31 ns | 141–146 ns |
| as received: record one acked row | 8.3–8.8 ns | 56 ns |
| as received: bracket P, lerp, two decodes | 108–121 ns | 389–437 ns |

Memory (24 B slots, `maxRewind` 1 s; `rewind_full.out` also has 0.5 s):

| Model | K | Ring per record | Ring total | Seq map | As received |
|---|---|---|---|---|---|
| shooter, 30 players, 20 Hz | 27 | 648 B | 19 KB | 9.7 KB | 15 KB |
| shooter, 30 players, 60 Hz | 77 | 1,848 B | 55 KB | 28 KB | 15 KB |
| shooter, 100 players, 20 Hz | 27 | 648 B | 65 KB | 32 KB | 170 KB |
| mmo, 300 tracked, 100 viewers, 20 Hz | 27 | 648 B | 194 KB | 32 KB | 510 KB |

CPU at the 100-player shooter (rows capped at about 66 per viewer per tick by the 16,000 B/s budget; 10 claims a
second per player, 5 targets each, all derived from the table):
- pushes: 100 × 20 × 10.5 ns ≈ 21 µs/s;
- as-received recording: 100 viewers × 66 rows × 20 Hz × 8.8 ns ≈ 1.2 ms/s;
- queries: 1,000 claims/s × (32 + 5 × 121 ns) ≈ 0.64 ms/s;
- in total about 1.8 ms/s, 0.2% of a core.

Wire: nothing for the ring. 28 bits per `perceived` frame that would have carried `'0'`, and 1 B per D change
(at most one a second per player).

### 11.8 How it fails on an unmodified client

- **Ping above `maxRewind`** (minus `delay`): `expired`. The game chooses whether to judge at the oldest tick or
  refuse. AC §4.1: under-coverage punishes high-ping players with misses.
- **Bursty downstream loss, or a client hitch longer than a tick:** `heldRaw` exceeds h_max and is clamped; the
  window widens by up to h_max. `exact = false` on undeclared definitions.
- **Asymmetric links:** rtt/2 misplaces the client's send time by half the asymmetry. Only `held` and Q depend on
  it, because s pins the state frame exactly.
- **Reliable fields** are returned at Q on the assumption that the reliable lane is as current as state frames.
  During a reliable stall (the test network model's 0.3 s stalls), the client held older reliable values. Reliable
  frames aren't acked, so Lync can't tell.
- **Teleports:** a lerp across a teleport returns a point on the line between. A `Net.fighters:cut(key)` call marks
  the tick so neither the ring nor the interpolation extension lerps across it. This needs one bit in the next row,
  unspecified here.
- **A game's own interpolation** with a delay other than `delay`: P is off by the difference.

**Defeated by (capability class, not steps):** a modified client that withholds acks or delays its own traffic,
engine pings included, makes itself look laggier and moves P older, at most to `maxRewind`. This is the inherent
limit of lag compensation (Bernier accepts it). The evidence fields `held`, `heldRaw`, `ping`, `rtt` and `ackTick`
show it as numbers. Lync attaches no verdict. Aim itself is an input, and an aimbot passes any geometric test.

### 11.9 Options

Server view, `Net.<collection>:rewind({ … })`:

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `fields` | array of top-level field names | — | — | every `:newest()` field | single-row width (bytes, rounded up) × K per record |
| `maxRewind` | number (real) | s | 0.1–2 | 1 (chosen, unmeasured: above typical p99 round trips) | K = ⌈(maxRewind + 0.25) × stateRate⌉ + 2 slots per record; L = K + 17 map entries per player |
| `mode` | `"received" \| "truth"` | — | — | `"received"` with the `interpolation` extension, else `"truth"` | received: (4M + 1) B per (viewer, record) and 8.3–8.8 ns native per acked row |
| `delay` | number (real) | s | 0–1 | the extension's server-chosen D; else 0.1 (Source's `cl_interp`, AC §4.1) | none |
| `rttSlack` | number (real) | s | 0–0.2 | 0.05 (chosen, unmeasured) | none; bounds how far Lync's ack round trip may raise engine ping |

Shared schema, client-sent definitions: `perceived = true` (boolean, default false; 28 bits per carrying frame that
would have had `'0'`; hashed). Engine parts, `Lync.rewind.parts(parts, { engineDelay, engineSpread, maxRewind })`:
`engineDelay` s, 0–0.5, default 0.1 (unverified, calibrate, §11.4); `engineSpread` s, 0–0.25, default 0.05; cost
one `CFrame` read per part per state tick (allocates a userdata; cost on Roblox unmeasured) plus a 32 B slot.

Constants: M = ⌈`delay` × `stateRate`⌉ + 2; L = K + 17; D unit 4 ms, at most one unit per second.

---

## 12. U15: `StreamingTargetRadius` and staged release

### 12.1 What the engine streams, and why the radius is no secrecy bound

All documented (`workspace/streaming/index.md`, `frustum.md`, `Workspace.yaml` at `efe8741`) unless marked.

- **The region.** Parts stream in around each replication focus: the character's `PrimaryPart` or
  `Player.ReplicationFocus`, plus foci added with `Player:AddReplicationFocus()`. `StreamingMinRadius` defaults to
  64 studs and `StreamingTargetRadius` to 1024.
- **Three things widen it:**
  - frustum streaming reaches "the lesser of the client's current draw distance and an engine-defined maximum
    range" in the camera view (`Player.FrustumStreaming`, server-only);
  - predictive streaming adds temporary foci at spawn points and recently left places;
  - extra foci.
- **The radius bounds stream-in, not what a client holds:**
  - "the engine is allowed to retain previously loaded instances beyond the target radius, memory permitting";
  - under the default `StreamOutBehavior` `LowMemory`, "the client only streams out regions beyond the minimum
    radius in a low memory situation";
  - so a client keeps most of what it has ever been near. `Opportunistic` lets the client drop it, but a modified
    client keeps its own copies regardless.
- **Some content ignores the radius altogether:**
  - Workspace instances other than parts and atomic or persistent models replicate at join: folders, values, their
    attributes, scripts;
  - under `ModelStreamingBehavior` `Legacy` (the default), every model's container and its non-part descendants do
    too;
  - `ReplicatedStorage` and `ReplicatedFirst` "are ineligible for streaming": everything in them reaches every
    client at join;
  - with streaming off, the whole Workspace does.
- **Readable by whom** (verified, API dump 0.741.19): `StreamingTargetRadius`, `StreamingMinRadius`,
  `StreamOutBehavior` and `ModelStreamingBehavior` are `NotScriptable`, so neither Lync's runtime nor a plugin can
  read them. `StreamingEnabled` has no `NotScriptable` tag (read None, write PluginSecurity) although its doc prose
  says "not scriptable". I believe the dump and the doc's own empty tag list: game code can read it (unverified in
  an engine). A build host reads all of them from a place file: verified, `stream_read.out` (set, serialized,
  read back under Lune 0.11.0).
- **Characters** stream like other Workspace content, to every client whose region covers them (AC §1.2).

### 12.2 What Lync's docs say (a page, "What engine streaming shows, and what Lync can hide")

1. **The leak radius of an entity is the larger of the engine's and Lync's.** `interest.radius` hides a record
   beyond its cells only if the same information isn't also in Workspace: a part, a model, an attribute, a
   character. A game that hides X with interest keeps X's instance out of Workspace, or accepts that the engine
   shows it out to the streaming region.
2. **The engine's region is wider than `StreamingTargetRadius` suggests:** retention under `LowMemory`, frustum
   streaming, extra and predictive foci (§12.1). Treat the region as "everything this client has been near since
   joining".
3. **What reduces it:** a smaller `StreamingTargetRadius` (pop-in is the cost, and the docs recommend 1024),
   `StreamOutBehavior = Opportunistic` (recommended for memory anyway), `ModelStreamingBehavior = Improved`, and no
   frustum streaming where it isn't needed. None of these hides anything from a modified client inside the region.
4. **Never put a secret in a Workspace attribute or value.** It replicates at join, whatever the radius.
5. **Fog of war for players** needs characters rendered from Lync records (AC §1.2, §1.4); `interest` and
   `rewind` (§11) then work on exact data.
6. **Lync's interest focus defaults to the engine's focus** (§2), so the two regions are centred on the same point.

### 12.3 Staged release of unreleased content

**What leaks.** Anything replicated can be read before it is used:
- models and assets in `ReplicatedStorage`;
- script code: clients can "Decompile any replicated LocalScript or any ModuleScript, even if they never run on the
  client" (documented, `scripting/security/security-tactics.md`, quoted in `generation-security.md` §2.2);
- Lync's shared schema and client shard, which name every definition, field and enum item. One
  `t.enum({ …, "dragonblade" })` announces the item.
- Kicking doesn't help: "replication begins as soon as the player joins and before server-side kick logic can
  execute" (documented, `scripting/security/access-control.md`).

**Mechanism: a staged namespace.** v5 already carries any number of namespaces over one remote pair. The server
numbers them in order of first server-side use, and a `HELLO` for one the server hasn't loaded is held up to 10 s
(`v5.md` §4.6). So:
1. Unreleased definitions go in their own schema module, declared in `lync.toml` as `[[namespace]] staged = true`.
   Its schema module and client shard are built to a server-only folder (`ServerStorage`).
2. At release, server code calls `Lync.release(folder)`. It requires the server view first (its first server-side
   use), then parents the folder into `ReplicatedStorage`.
3. Client code waits for the folder and requires the client shard, which sends `HELLO` and gets `WELCOME`.
4. No restart, no new remote. Released namespaces never change, so their schema hash is unaffected.
- **Cost:**
  - run time: one namespace index more in the segment toc (a few bits per segment of it), and one `HELLO`/`WELCOME`
    round trip per client at release;
  - sends made during that round trip wait in the join hold (32,768 B);
  - developer effort: one more schema module per staged feature, written as its own namespace from the start.
- **Limit:** content that has to extend a *released* definition (a new item in a released enum) can't be staged
  this way. It needs a new build and a server restart, which is a design constraint the docs state.

**Build checks** (`lync check`; each `[check]` key takes `"off" | "warn" | "error"`):

| Code | Exact trigger | Evidence | Default | Known causes without a leak |
|---|---|---|---|---|
| `stagedReplicated` | a staged namespace's `schema` or `client` path, or a path listed in `[[staged]] paths`, maps to a replicated container (`ReplicatedStorage`, `ReplicatedFirst`, `Workspace`, `StarterGui`, `StarterPack`, `StarterPlayer`). It is mapped through the Rojo project file, the plugin's instance path, or the built place when `[check] place` names one | namespace or path, container | `"error"` | none: the declaration says server-only |
| `stagedReferenced` | a scanned replicated script, or a released namespace's schema, contains the staged module's instance path or a `require` of it | file, line, column | `"error"` | a client loader that waits for the folder by name, which is allowed when it names the release folder in `[[staged]] loader` |
| `stagedNameLeak` | a definition name, field name, union variant or enum item of a staged namespace, at least 4 bytes long, occurs byte for byte as a string literal in a released namespace's schema or a scanned replicated script | the string, file, line | `"warn"` | a common word ("name", "level") used in both; the check reports the match, and only the game knows whether it is a leak |
| `streamingOff` | the place read through `[check] place` has `Workspace.StreamingEnabled = false` | place path | `"off"` | a game that streams nothing on purpose |

- **Report.** `report.md` lists the place's `StreamingEnabled`, `StreamingTargetRadius`, `StreamingMinRadius`,
  `StreamOutBehavior` and `ModelStreamingBehavior`, with the place file they came from. The runtime can't read most
  of them (§12.1); the build can (`stream_read.out`).
- **Cost:** build time only.
  - The text checks share the scan that `rawRemote` and reachability already make (`v5-tooling.md` §3,
    `v5-integrity.md` §3).
  - Reading a place costs one Lune `deserializePlace`; time for a large place is unmeasured.
- **What no build can check:**
  - whether an asset is unreleased, unless the developer lists its path;
  - game code that parents content into a replicated container early at run time;
  - attributes set at run time.
- **Least developer work:** `staged = true` on a namespace and one `Lync.release(folder)` call. The defaults
  catch the two mistakes that leak everything, a staged module in a replicated folder and a replicated `require` of
  it, as errors.

**`lync.toml` keys:**

| Key | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `[[namespace]] staged` | boolean | — | — | false | the namespace's shard goes to `ServerStorage`; one namespace index at release |
| `[[staged]] paths` | array of instance paths | — | — | [] | one container lookup per path at build |
| `[[staged]] loader` | instance path of the release folder | — | — | none | exempts that path from `stagedReferenced` |
| `[check] place` | path to a built `.rbxl` | — | — | none | one place read per `check` |
| `check.stagedReplicated`, `.stagedReferenced`, `.stagedNameLeak`, `.streamingOff` | `"off" \| "warn" \| "error"` | — | — | as the table above | build time only |

---

## 13. `PlayerGui` variant timing

**Context.** R7 (per-player client shard variants from a build-time pool) is refused today; one of its recorded
costs is that the variant may arrive after the client's first send (CH:107). This section gives the protocol rule
that keeps Lync correct whichever arrives first, so a re-judgment of R7 can weigh it with its real cost.

### 13.1 The facts the rule rests on

- `PlayerGui` exists from join: "When a player first joins the experience, their `PlayerGui` is automatically
  inserted" (documented, `PlayerGui.yaml`). A child the server parents there replicates to that player only
  (`PlayerReplicated`, verified, `generation-security.md` §2.1). It doesn't wait for spawn; only `StarterGui`
  copies do.
- A `LayerCollector` with `ResetOnSpawn = true` "deletes itself and re-clones" on respawn (documented,
  `LayerCollector.yaml`), so the variant sits in a `ScreenGui` with `ResetOnSpawn = false`, as Adonis does
  (`generation-security.md` §2.1).
- **Unverified:** the arrival order of a server-parented `PlayerGui` child relative to `ReplicatedFirst` and
  `ReplicatedStorage` content, and relative to remote messages. The remote docs order messages "across different
  `RemoteEvent` instances" but say nothing about instance replication against remotes (searched
  `scripting/events/remote.md`, `projects/client-server.md`). So no rule may depend on it.
- `RemoteEvent`: with no handler connected, "Roblox queues it and delivers it, in order, as soon as a handler
  connects. The queue is limited in both count and memory" (documented, `remote.md`). `UnreliableRemoteEvent`
  messages with no handler are discarded "immediately".
- Before a namespace's `WELCOME` the client sends only untagged `HELLO`s (`v5.md` §4.5). A `HELLO` is a control row
  of namespace 0 with fixed fields, untouched by the seed (the seed changes record field order and the tag's
  constants only, §3.2). It carries the build seed (u32).

### 13.2 The rule

1. **Assignment before cloning.** Lync's server runtime picks each player's variant at `Players.PlayerAdded`, and
   for players already present at start (the loop `PlayerAdded` needs). It records the variant's seed for the
   player, then parents the clone under a `ResetOnSpawn = false` `ScreenGui`. The server always knows the
   assignment before the client can see the clone.
2. **Bind before `HELLO`.** Game code requires a shared stub (`ReplicatedStorage`), which returns the API at once,
   so `require` still never yields (`v5.md` §3.5). The stub binds to the variant when it finds it under `PlayerGui`
   and only then sends `HELLO`, carrying that variant's seed. Until binding, every send goes to the join hold
   exactly as before `WELCOME` (§5.3): reliable sends are held, and unreliable sends are dropped as `sendDropped`
   cause 2.
3. **The hold keeps values, not bytes.** Field order isn't known until binding, so held sends stay as values and
   are encoded at release with the bound plan. Their size against the 32,768 B cap is counted with the seed-0
   plan. That count is exact, because no codec's encoded size depends on field order:
   - single rows sum their fields;
   - column blocks code each column on its own;
   - the tail holds the same bytes in another order;
   - (derived from `v5.md` §4.3).
4. **The server accepts only the assigned seed.** A `HELLO` whose seed differs from the player's assignment gets
   `MISMATCH` and the existing fact `schemaMismatch` (`seedDiffers` = 1). If any variant in the pool were accepted,
   a modified client could choose the variant its tool was built for, and per-player variation would be void.
5. **Bind once per connection.** Later changes under `PlayerGui` (a respawn, a game script deleting the
   `ScreenGui`) are ignored. The server never reassigns within a session; a rejoin may get a different variant.
6. **Variants change the upstream plan and the tag constants only.** Downstream chunks keep the build's own field
   order, so encode-once and cell chunks (§3, §6.2) keep sharing across players. The client then decodes downstream
   frames from first use, and its `OnClientEvent` handler connects at once. With rule 2, the only message the
   engine's queue ever holds for it is a `WELCOME` (or `MISMATCH`), one small control frame, well inside any
   plausible queue limit. No bulk data waits on that undocumented limit.

### 13.3 Why it is correct either way

- **Variant first:** binding is immediate, and the join behaves as today.
- **First send first:** the send waits in the hold. `HELLO` leaves when the variant is bound, and `WELCOME` releases
  the hold. No frame is ever encoded with a plan the server doesn't expect, because nothing but `HELLO` (which has
  no seed-dependent bits) leaves before binding, and the server checks the seed against its own assignment.
- **No ordering assumption** between instance replication and remotes is needed (§13.1).

### 13.4 Cost

| Item | Cost |
|---|---|
| join latency | max(0, variant arrival − client first use), plus the `HELLO`/`WELCOME` round trip as today. The arrival time is unmeasured; measure it in Studio and live from `os.clock()` at a `ReplicatedFirst` script's start to the variant's `ChildAdded` |
| client memory | held values up to 32,768 B of encoded size (the existing cap), now kept as values until binding |
| server memory | one seed per player; V upstream decode plans (size per plan unmeasured; about one shard's tables each) |
| server CPU | one plan reference per player, read once per upstream frame (a table field) |
| wire | none: `HELLO` already carries the seed |
| replication | one script instance per player, about one shard's size (CSB §3.3) |
| developer effort | `[variants] count = N` in `lync.toml`. The stub, the variants and the server's assignment are generated; game code requires the stub as it requires the shard today |

### 13.5 How it fails on an unmodified client

- **The variant never arrives** (a server error before parenting, or `PlayerGui` missing): the client keeps waiting
  and reports natively `variantMissing` after 10 s, as `remotesMissing` does (`v5.md` §7.3). It is a local, client
  fact with no evidence, and a new runtime constant: variant wait 10 s (chosen, unmeasured).
- **A slow variant:** sends beyond the hold are `sendDropped` cause 1, and unreliable sends cause 2. Their known
  causes gain "waiting for the variant (`[variants]` set)".
- **A game script that clears `PlayerGui`** before binding: as "never arrives". After binding it has no effect
  (rule 5).
- **A modified client** can read its own variant in full, as it reads the shared shard today. Variation prices only
  tools shared between players inside one build (R7's recorded reason), and rule 4 keeps a client from opting out
  of its assignment.

---

## Implications (rewind and timing)

1. **Specify `rewind` as tick-indexed 24 B slots per tracked record** (quantized position, rotation code, flag
   byte), declared on the server view and never hashed. It costs 648 B per record at 20 Hz for 1 s, and about
   10 ns native per push (§11.2, §11.7).
2. **Derive two ticks per message from the ack in its own frame,** Q (applied) and P = Q − D (rendered), with
   `held` from engine ping raised to Lync's ack round trip. Never take a time from the client (§11.3, R20).
3. **Add `perceived = true` on client definitions,** forcing a full ack into every frame that carries them. It costs
   28 bits per such frame and makes P exact (§11.3).
4. **Make the interpolation delay a server value sent in `RATE`** (4 ms units, at most one step a second, logged by
   tick). A client-adapted delay is a client-stated rewind offset (§11.3).
5. **Default to "as received" sampling with the `interpolation` extension.** Truth-at-P is off by p99 1.3 studs once
   a third of rows are deferred, and as received costs about 1.2 ms/s at 100 players (§11.5, §11.7).
6. **Return evidence, not a verdict:** `perceived()` values (`held`, `heldRaw`, `ping`, `rtt`, `exact`, `expired`)
   and `rewound()` results with `notHeld`. Add no `observe` fact, because Lync can't know a message is a claim (§11.6).
7. **Keep the engine's interpolation delay out of Lync's constants.** It stays unverified. Rewind engine parts over
   a game-set `engineDelay ± engineSpread` span, and ship the calibration recipe (§11.4).
8. **Ship the streaming page:** the leak radius is the larger of the engine's and Lync's. The engine region keeps
   what a client has been near, and Workspace attributes replicate at join (§12.1–§12.2).
9. **Stage unreleased features as their own namespace** in `ServerStorage`, released with `Lync.release(folder)`.
   Build checks `stagedReplicated` and `stagedReferenced` (error) and `stagedNameLeak` (warn), and `report.md`
   lists the place's streaming settings, which only the build can read (§12.3).
10. **If R7 is re-judged, adopt the variant rule with it:** bind before `HELLO`, hold values, accept only the
    assigned seed, bind once, and vary upstream only. That costs no wire bytes, and join latency only by the
    unmeasured variant arrival (§13).
