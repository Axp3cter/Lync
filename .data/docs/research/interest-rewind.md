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

- [ ] §11 D2 `rewind`: rings at the perceived tick
- [ ] §12 U15: `StreamingTargetRadius` and staged release
- [ ] §13 `PlayerGui` variant timing
- [ ] Implications (rewind and timing)
