# Design-level anti-cheat for Lync v5: what AAA games and the research literature do, mapped to Roblox

Researcher brief, 2026-10-15. Question: what do serious multiplayer games do against client cheating *by
design*, and which of those techniques can a networking library that owns the schema, the wire, replicated state
and per-player timing build in, generated from the schema with little developer effort?

Framing: defensive. Every section describes what the defender builds, what it protects, how robust it is, and
what it costs. Client-side tamper detection is covered in `client-security.md` (scratchpad) and is not repeated
here.

Labels: **verified** (I ran it or read the primary source), **documented** (the vendor's own docs or blog),
**reported** (third party), **unverified** (recalled or inferred). Probes are in
`.data/docs/probes/anticheat-design/` and ran on `luau 0.740` (Linux, Xeon 2.1 GHz), interpreted `-O2` and
native `-O2 --codegen`. On Roblox, native code generation runs on servers only and clients are interpreted
(`.data/docs/research/landscape.md` item 10). CLI timings indicate scale; they do not transfer exactly to Roblox.

---

## 0. Bottom line

1. The AAA consensus is that the best anti-cheat is **design that leaves nothing to steal or claim**:
   - the server withholds what a player should not perceive (Riot's Fog of War, League's net visibility);
   - clients send inputs, never outcomes ("The Server Is The Man", Sweeney via Fiedler);
   - claims that must exist are checked against the client's *perceived* past (Bernier's lag compensation);
   - detection is behavioural and server-side, trained on what the server already sees (VACnet, XGuardian);
   - mitigation is quiet and reversible (Ricochet's Damage Shield; Roblox's consequence ladder).
2. Lync owns three things these techniques need, and a game does not easily own them:
   - **per-viewer replication** (audiences, catch-up, eventually consistent state);
   - **the schema** (field meaning, ranges, direction, which fields are claims);
   - **per-player timing** (send times, acks, RTT, arrival times).
3. The highest-value, lowest-effort Lync features, ranked:
   - (a) per-viewer relevancy for replicated state, with look-ahead and scoped events;
   - (b) server-derived "perceived time" for every inbound message, plus a rewind buffer over replicated state;
   - (c) schema-declared constraints that compile into per-player server checks;
   - (d) direction and claim typing that makes outcome claims explicit;
   - (e) per-viewer decoy records, injected at encode time, never in server state;
   - (f) bounded per-player feature streams for offline detection.
4. The hard limit on Roblox: the engine replicates **player characters** (and other streamed Workspace content) to
   every client within the streaming radius (default 1024 studs), with no line-of-sight filter. Lync cannot hide
   them. Information hiding protects what Lync replicates:
   - health, loadouts, abilities, objectives, NPCs and custom entities;
   - characters only in games that replicate them through Lync instead of `Player.Character`.
5. Things that are theatre or harmful in this setting:
   - quicksand-style mitigations that other players can see (Activision retired its own);
   - lag compensation driven by client-claimed timestamps (it creates the "backtrack" advantage);
   - decoys flagged on the client (any flag in memory is a filter for the cheat).

---

## 1. Information hiding as security (anti-ESP, anti-wallhack)

### 1.1 How AAA does it

**VALORANT Fog of War** (Riot tech blog, 2020-04-14, [primary](https://technology.riotgames.com/news/demolishing-wallhacks-valorants-fog-war), **verified by reading**):
- Principle, inherited from League of Legends: "the game server withholds information about the positions of
  enemies until a client needs to display it … there would be nothing for the wallhack to see."
- Three needs: "A way to decide which information is necessary for each player; A way of preventing players from
  receiving unnecessary information; A way of catching a player up when unnecessary information becomes
  necessary." It relies on Unreal's network relevancy and on replication being "eventually consistent, so once
  information became relevant, the state of enemy players would catch up."
- Visibility evolved through three versions:
  1. a single ray to the actor's centre, which was pessimistic and caused pop-in;
  2. ten rays to the bounding-box corners, camera and centre, which was still fallible and 10× the cost;
  3. **look-ahead**: "expanding the actor's bounding box by the actor's velocity multiplied by a 'look ahead' time
     which was bigger than the expected ping time", combined with **server-side PVS occlusion culling**. The map
     is pre-divided into voxel cells and a precomputed table says which cells can see which, so "Instead of doing
     a ray trace … I just did a table lookup". It is optimistic: "As long as any part of a voxel can see any part
     of the other voxel, the table returns 'visible'."
- Cost: the first prototype took 50 % of server frame time, and in a 10-player game they were "calculating
  relevancy more than 350 times every frame". After PVS, plus "relevant actors stay relevant for a small amount of
  time" (hysteresis) and "attached actors share their parent's visibility", it is "less than 2% of server frame
  time … Overall the system even improves performance because of the reduction in network messages".
- The biggest bug class came from **events instead of state**. When an enemy hidden by fog began defusing, the
  "Start Spike Defuse" RPC was never sent to the observer, and "there was no mechanism to repair the state after
  leaving Fog of War". The fix was a systemic one ("Effect Containers") that restarts and fast-forwards effects
  when an actor becomes relevant.
- Measurement: "telemetry into the game server that measures the results of every Fog of War query", with
  dashboards by map and agent and alert thresholds. A stuck inaudible sound loop showed up as "significantly
  higher relevancy time for Jett players".

**Unreal Replication Graph** (Epic docs, [primary](https://dev.epicgames.com/documentation/en-us/unreal-engine/replication-graph-in-unreal-engine), **documented**):
- Built for Fortnite, which "starts each game with 100 connected players and about 50,000 replicated Actors".
  Per-actor-per-connection checks "will bottleneck the server's CPU".
- Nodes hold spatial grid cells or rooms. A connection gets a precomputed actor list for its area, plus lists that
  are "always (or never) relevant to certain clients", such as teammates and revealed opponents.

**OpenConflict** (Bursztein, Hamburg, Lagarenne, Boneh, IEEE S&P 2011, best student paper,
[paper](https://www.ieee-security.org/TC/SP2011/PAPERS/2011/paper032.pdf), **reported** from the abstract):
- Built *Kartograph*, a passive, remotely undetectable map hack for RTS games that reads memory.
- Defended with protocols so "each client receives only the game-state data it is entitled to see": 22 ms on one
  core per state synchronization at peak, over 1000 StarCraft II replays.
- The point carries over: a passive reader cannot be detected, only starved.

### 1.2 Roblox constraints

- **Instance streaming is radius-based, not visibility-based.**
  - The streaming area is "the standard cube around the replication focus" plus optional extra foci and, since
    2026, optional *frustum streaming* for scopes ("the camera-view pyramid").
  - Defaults are `StreamingMinRadius` 64 and `StreamingTargetRadius` 1024; streaming is required for Server
    Authority.
  - There is no per-viewer line-of-sight filter for Workspace instances (creator docs `workspace/streaming/
    index.md`, `frustum.md`, **documented**).
  - Other players' characters therefore reach every client within the radius, and a wallhack reads them from the
    DataModel. Lync cannot change this.
- **Network ownership**: without Server Authority, clients own their character and nearby unanchored parts and
  "have complete authority over the physics simulation for those objects" (docs
  `scripting/security/network-ownership.md`). With `AuthorityMode = Server` (full release 2026-07-09), the server
  simulates and "automatically rejects invalid client movements". Characters are still replicated to everyone.
- **What Lync can hide**: everything it replicates.
  - Non-spatial secrets: health, ammo, cooldowns, loadouts, economy, quest and objective state, hidden cards and
    roles.
  - Spatial data the game keeps out of Workspace: NPC positions computed on the server, custom characters,
    projectiles, pickups, traps, minimap blips, footstep and sound events.
  - Games that need real fog of war for players must render other players from Lync state (client-side rigs driven
    by replicated records) and not use `Player.Character` replication for enemies.
  - Chickynoid, a community server-authoritative character controller, already replicates characters through its
    own remotes and "trusts nothing from the client except input directions and buttons"
    ([repo listing](https://gittrend.io/repo/easy-games/chickynoid), **reported**; last push reported 2024-05).
- Developers can shrink the leak radius with `StreamingTargetRadius`. It is a Roblox knob, not a Lync one, but
  Lync's docs should say so.

### 1.3 What Lync has today (v4) and what is missing

- v4 sets are keyed records replicated to **audiences**: `Net.Fighters:audience("red", redGroup)`, where an
  unassigned key means nobody. There is one partition per key value, columnar sections encoded once, catch-up
  keyframes for "late joiners/new viewers", and `onAdded` fires on "gaining sight" (`.data/docs/research/v4.md`).
- That is team-level visibility: a partition is shared by a whole audience. Fog of war needs **per-entity,
  per-viewer** relevancy that changes every few ticks.

### 1.4 Design: per-viewer relevancy generated from the schema

**Model.** A replicated collection may declare a *relevancy policy*. Each server tick at the relevancy rate, Lync
computes `relevant(viewer, record)` for candidate pairs and diffs it against the previous result:
- newly relevant → catch-up keyframe for that record (the existing late-join path);
- no longer relevant → a removal that reads exactly like any other removal (v5's "removed not revealing delete vs
  hide" idea is required here, or the removal itself leaks).

**Policy building blocks**, cheapest first. All of them are optimistic (they never hide what might be seen):
1. *Ownership/team*: always relevant to the owner and the team (Unreal's "always relevant" lists).
2. *Distance*: radius per collection, in studs.
3. *Cell visibility*: a PVS-style bitset over map cells.
   - Lync can't build it from the schema; it needs the map.
   - The build-time bake belongs to the other researcher. A runtime bake at server start, raycasting between cell
     centres, is possible but slow.
4. *Look-ahead*: expand the target's position by `velocity × lookAhead` with `lookAhead` ≥ the viewer's measured
   one-way latency plus interpolation. Riot's rule is "bigger than the expected ping time".
5. *Hysteresis*: keep a pair relevant for `hold` ticks after the last positive test.
6. *Attachment*: a record whose schema field references another record (`ref(Collection)`) inherits that record's
   relevancy. Weapons follow their owner, as in Riot's optimisation.
7. *Custom predicate*: `(viewer, record) -> boolean`, for game logic (stealth, smoke).

**Generated from the schema**:
- which field is the position (a `vec3` field marked `:position()`) and which is the velocity (or a finite
  difference of positions);
- which fields are owner/team keys (`keyBy`);
- which fields are references (attachment);
- field-level visibility classes. Some fields of a visible record can stay hidden:
  - `hp` visible to the team, or to everyone only below a threshold;
  - `loadout` visible after first sight;
  - `cooldowns` visible to the owner only.
  This is information hiding at field granularity; no AAA source above describes it, but it is the same
  principle and falls straight out of a schema.

**Scoped events.**
- Riot's worst bugs were events sent outside relevancy. A packet that is *about* a record (`:about(field)`, the
  field being a `ref`) is delivered only to viewers for whom that record is relevant, and is never queued for the
  others.
- Anything that must survive a relevancy gap belongs in the record as state with a start time (e.g.
  `defuseStartedAt`), so catch-up shows it correctly. This is Riot's Effect Container lesson expressed as a schema
  rule.
- Lync can lint for it: a packet declared `:about(X)` whose effect has a duration should be a field on `X`.

**Encoding cost and the encode-once model.**
- v4 encodes each partition's section once for its whole audience. Per-viewer relevancy breaks that.
- Workable plan, following Unreal's per-connection lists:
  1. Encode each **record's** delta once per tick as a byte-aligned chunk.
  2. Assemble each viewer's frame by copying the chunks of its relevant records (`buffer.copy`).
  3. Prefix the frame with the viewer's relevancy diff.
- Encode cost stays O(records). Assembly is O(Σ relevant pairs) byte copies. Bit-packing across record boundaries
  is lost; that costs at most 7 bits per record per viewer.
- **Unverified**: the size cost depends on record size; a probe should compare it against v4's columnar sections.

**Measured relevancy cost** (`.data/docs/probes/anticheat-design/relevancy_cost.luau`: distance cull + PVS bitset
test + hysteresis per pair; 5 runs, medians):

| Viewers × records | Interpreted, ms/pass | Native, ms/pass | ns/pair (native) |
|---|---|---|---|
| 30 × 60 | 0.085 | 0.023 | 12.9 |
| 50 × 100 | 0.233 | 0.066 | 13.3 |
| 100 × 200 | 0.974 | 0.250 | 12.5 |

- At 20 Hz relevancy for 100 × 200 that is 5 ms/s native, **0.5 %** of a server core; at 60 Hz, 1.5 %. This
  matches Riot's "< 2 %".
- Raycast-based visibility instead of PVS would dominate. Roblox `Workspace:Raycast` cost per ray is not measured
  here (**unverified**). If it is a few µs, 20,000 pairs at 20 Hz is 0.4 M rays/s, which is not affordable.
  Raycasts should therefore be limited to the pairs that pass the distance and cell tests, with hysteresis.
- PVS memory: a 64 × 64 cell grid as a full bitset is 2 MiB (4096² bits). A coarser grid, a 2-D grid, or a
  sparse/RLE table is needed for big maps.

**Protection.** Against passive memory readers of Lync state (ESP from Lync collections, radar, loadout peeking)
it is strong: what is not sent cannot be read. It does nothing for Roblox-replicated characters, and it leaks
inside the look-ahead window by design.

**False-positive risk** (players seeing pop-in, not bans):
- Comes from pessimistic policies; use optimistic cells, look-ahead and hysteresis.
- Riot's dashboards are the tool for catching mistakes: Lync should count relevant-pair time per collection and
  per record kind and expose it.

**Developer effort.** Opt in per collection with a policy table. Minimal form: radius + team + position field.
Full form: + cell table + predicate.

---

## 2. Decoys and canaries (hallucinations, honeypot entities)

### 2.1 How AAA does it

**Call of Duty RICOCHET Hallucinations** (blog 2023-06, [primary](https://www.callofduty.com/blog/2023/06/call-of-duty-ricochet-anti-cheat-season-04-update);
white paper Durst & Taylor 2023-03-30, [paper](https://research.activision.com/publications/2023/03/reversing-anti-cheats-detection-generation-cycle-with-configurable-hallucinations); **verified by reading both**):
- Blog: decoys "can only be detected by cheaters that have been specifically flagged by our system … undetectable
  by legitimate players, and they cannot impact a legitimate player's aim, progression, end of match stats".
- Two uses: mitigation for verified cheaters, or "in secret, as a detection for suspicious players … forcing them
  to self-identify as a cheater if they engage with the cloned character in any way."
- "These are not AI but a clone of an active user in the match". They "trigger the same information that cheaters
  would have access to", so they look legitimate in cheat tools.
- Paper, the four constraints: "1. Hallucinations look like real players in memory. 2. Non-cheating players are
  not able to observe the hallucinations. 3. Implementation is maintainable and performant. 4. Hallucination
  mechanism supports configurable in-game behavior."
- **Where to insert them**: during snapshot creation, after game logic. "We can't change the server state when we
  create the hallucinations. Otherwise, we may introduce bugs". Creating them on the client is "too late … cheat
  developers can watch this client-side code".
- **How**: "Copy and Update". Copy a real player's snapshot entry into a free slot each frame and modify it.
- **Behaviours deployed**:
  - "positioned directly in front of the possibly cheating player at different distances, like beyond max draw
    distance";
  - "angled behind" the player;
  - prototype "Emerge", where the hallucination starts inside a real player and walks out of them.
- **Result**: three popular cheat programs "treated our hallucinations like real players for all accessible
  feature combinations" (ESP, ESP properties, radar, aimbot behind and in front of walls, FOV limits).
- **Thesis**: configurability "reduces the anti-cheat problem to the bot design problem" and reverses the
  detection–generation asymmetry. Prior art: Counter-Strike 1.6 plugins (Lucia Hallucination, AimBot Detection)
  used static placements that cheat developers learned to filter.
- **Admitted weakness** (third-party notes, **reported**): cheats that only act on targets after they have been
  rendered on screen.

**Roblox's own guidance** (`scripting/security/server-side-detection.md`, **documented**):
- Honeypot remotes are "a very high-confidence signal".
- Firing a server→client remote from the client "serves as a reliable detection method".

### 2.2 Design: Lync decoy records

**Where.** Decoys are injected in Lync's **per-viewer frame assembly** (§1.4). That is exactly Activision's
"snapshot creation" step: after game logic, never in server state, never in other viewers' frames.

**What.** A decoy is a record in a real collection:
- same schema;
- slot id taken from the same allocator;
- same encode path, catch-up and relevancy machinery;
- its field values come from a **behaviour function** supplied per collection: `(viewer, now) -> record?`.

**Constraint 1 ("looks real in memory")** is met if, and only if, the client receives nothing that distinguishes
a decoy:
- no flag bit;
- no separate id range (slot ids are drawn from the same free list);
- no timing tell: added in the same frame position as real adds and updated at the same rate. Activision's warning
  about client-side code watching for "newly created entities" applies to Lync's `onAdded`, so a decoy must appear
  on a path real records also use, e.g. becoming relevant or entering range.
- The typed client API therefore **cannot** hide decoys. Any filter in Lync's client would be a filter in memory
  for the cheat to read.

**Constraint 2 ("honest players can't observe it")** therefore has to come from the decoy's *values*, which only
the game understands. Placement must make honest rendering and honest logic ignore it:
- beyond draw or streaming distance;
- inside map geometry;
- behind the viewer;
- a team or state the honest UI never renders.

Lync provides the machinery and a few placement presets. The game provides or approves the behaviour, because only
it knows what is visible.

**Detection ("self-identify").** Lync can detect references to decoys mechanically:
- any inbound message whose `ref(Collection)` field names a decoy slot that was sent to that player is a certain
  signal ("targeted a record you were shown but could never have perceived");
- a lag-compensated hit test (§4.1) whose ray intersects a decoy's rewound hitbox is a strong signal;
- interaction kinds the game reports through `Lync.reportInteraction(player, record)`.

**Required companion: per-viewer slot permutation.**
- Cross-client diffing (two colluding accounts comparing what they see) reveals a decoy as a record only one of
  them has.
- If slot ids are permuted per viewer, ids can't be compared across clients. The comparison needs positions,
  which Activision's "clone of an active user" design blurs.
- The same permutation is the watermark in §6.

**False-positive risk.**
- Honest **aim assist or auto-target** code in the game iterates every record in a collection and will target
  decoys. Games with aim assist, target lock or auto-interact must exclude decoys by placement (e.g. outside the
  assist range) or not use them.
- Honest *client* code that sends a `ref` to every record it knows (a "select nearest" button, a scoreboard
  "report" button) is another false-positive path.
- Lync's lint can flag client→server definitions with `ref` fields into a collection that has decoys enabled.
- Activision's answer, "we rely on the behavior generator to hide the hallucination", means false-positive risk is
  a property of the behaviour, not of the mechanism.

**Cost.**
- One extra record per targeted viewer: wire bytes equal to a real record's at its update rate.
- Server CPU: the behaviour function plus one encode per decoy per tick, without shared encoding since each decoy
  goes to one viewer. 10 decoys at 20 Hz is negligible next to the relevancy pass.

**Canary fields** (a non-spatial variant):
- A per-player field value that honest code never sends back. Example: a hidden `promoCode` or item id in a
  replicated inventory that the UI does not show. Any inbound message carrying it proves the client read raw state.
- Lync's role: mark a field `:canary()`. The server fills it with a per-viewer random value and checks every
  inbound string or id field against the viewer's canaries.
- Cheap, certain when it fires, and rarely fires.

**Direction traps** (zero cost):
- A server→client definition id arriving from a client, and a client→server definition id the honest client code
  never calls ("trap definitions"), are certain signals in Lync's own wire.
- These are Roblox's documented honeypot and direction checks, implemented by the library for every definition
  automatically.

---

## 3. Intent-based protocols: clients send inputs, never outcomes

### 3.1 The AAA rule

- Bernier (Valve, GDC 2001, [paper](https://www.gamedevs.org/uploads/latency-compensation-in-client-server-protocols.pdf),
  **verified by reading**): a client that reports "I'm now at position x and, by the way, I just shot player 2 in
  the head" is "fine if you can trust the client … For Half-Life, this mechanism is unworkable because of realistic
  concerns about cheating".
- Fiedler (Gaffer On Games, [article](https://gafferongames.com/post/what_every_programmer_needs_to_know_about_game_networking/),
  **verified by reading**): "in FPS games it is absolutely necessary that the server is the authoritative over the
  state of each player character", quoting Sweeney's "The Server Is The Man".
- Roblox Server Authority docs: "clients are only trusted to report their own inputs"; InputActions "should be used
  for **all inputs that affect the core simulation** and they should be checked for sanity" (**documented**).
- Roblox's defensive-design doc gives the same rule as examples. Reactive: "Try to detect and filter out impossible
  damage values". Defensive: "Server calculates all damage from server-sided weapon stats and validates hits
  through server-side raycasting".

### 3.2 Design: make outcomes structurally awkward in the schema

**Three field roles**, declared on client→server definitions:
1. **Input** (default): bounded controls and choices.
   - Enums, bitfields of buttons, unit directions (`vec3.unit`), quantized aim angles, ids chosen from a
     server-provided set.
   - Already safe if strict decode holds; the server derives outcomes.
2. **Claim**: a value the client asserts about the world: hit target, hit position, shot origin, interaction
   target, completion time.
   - Declared with `:claim(verifier)`. A claim field without a verifier is a **definition-time error** on the server
     view.
   - A verifier is a built-in (§4) or a function `(player, value, ctx) -> ok, reason`.
   - The handler only runs after every claim passes, so unverified claims can't reach game code.
3. **Outcome**: damage dealt, currency gained, score, item granted. **Not expressible** client→server.
   - The schema compiler can't recognise outcomes semantically. What it can do is make claims explicit:
     - every client→server field that is not an input-shaped codec (free `f64`, unbounded `str`, `inst` of
       another player, large ints) needs an explicit `:input()` or `:claim(...)` annotation;
     - otherwise the server view emits a warning naming the field.
   - The friction is deliberate: it puts the "how would an exploiter abuse this?" question (Roblox docs) on the
     definition line.

**Input transport choice.**
- In Server Authority games, simulation inputs belong in InputActions, which the engine replays during resimulation.
- Lync should not compete with them. It carries discrete intents (buy, equip, use ability) and claims that need
  verification (hits).
- The docs warn: "Remote events aren't synchronized with the shared timeline" (release post), and "RemoteEvents
  might not be consistently ordered with property and attribute updates".
- So a Lync intent that depends on simulation state must carry **which simulation frame or Lync frame it refers
  to**. That is the perceived-time machinery in §4.1.

**Re-derivation instead of verification.**
- When the client's outcome is a deterministic function of inputs (projectile path from origin, direction and
  speed; a crafting result), the strongest verifier is to recompute it with the shared module code and compare.
- Overwatch's GDC 2017 talk describes a deterministic simulation built for this (abstract only,
  [GDC Vault](https://gdcvault.com/play/1024001/-Overwatch-Gameplay-Architecture-and), **reported**).
- Lync's part: `:claim(Lync.derive(fn, tolerance))`. The server runs `fn` on the input fields and compares within
  a tolerance in the field's own units.
- Determinism caveat (prior Lync work): float results may differ across hardware; compare quantized indices, not
  raw floats.

---

## 4. Server-side verification helpers

### 4.1 Lag-compensated rewind at the client's perceived time

**AAA design** (Bernier 2001, **verified by reading**). Before executing a user command the server:
- "Computes a fairly accurate latency for the player";
- searches its history "for the world update that was sent to the player and received by the player just before
  the player would have issued the movement command";
- moves other players back to "exactly where they were when the current player's user command was created";
- "must account for both connection latency and the interpolation amount the client was using";
- runs the command, then restores.

Two caveats from the paper:
- The paper accepts "shot around a corner" for high-latency shooters as a design trade-off.
- Projectiles are not lag-compensated in Half-Life.
- Valve's Source wiki states the same as *command execution time = server time − latency − view interpolation*, with
  a default 100 ms interpolation. The wiki is behind a bot wall from this environment; this is quoted from memory
  and secondary copies, **unverified**.

**Roblox state of play.**
- A Roblox engineer's Server Authority deep dive (2026-05-08, [thread](https://devforum.roblox.com/t/server-authority-tech-deep-dive-engineering-insights/4624565),
  **reported**): "Server-Side Rewind: For high-end shooters, we are missing the logic for latency-compensated hit
  detection. While you can implement this yourself with existing APIs, we want to create a built-in solution soon™."
- Under Server Authority, "other player characters … render slightly in the past" (`projects/server-authority/
  techniques.md`).
- Community libraries:
  - RollbackHitbox (2026-04): 60 Hz circular buffer, binary search plus lerp, `clientTimestamp` "clamped to
    [0, MAX_REWIND_SECONDS]", and "Fabricated shot direction is trusted".
  - Rewind (archived 2025-12).
  - SecureCast (archived 2023).

**The design flaw to avoid.**
- Letting the client name the rewind time, even clamped, hands the attacker a free choice of *any* past position
  inside the window. This is the classic "backtrack" advantage.
- v4's timestamped packets clamp client claims to `[arrival − 60 s, arrival]` (`.data/docs/research/v4.md`), far
  too wide for this use.
- Bernier's server *computes* the time from its own latency measurement and the client's known interpolation.

**Lync's advantage: server-derived perceived time.**
- Lync owns both directions:
  - the server knows when it sent downstream frame *k*;
  - if each upstream frame carries the id of the newest downstream frame applied (an ack, 2 bytes), the server
    knows **which replicated state the client had** when it acted.
- For Lync-replicated records, the perceived state is *exact*: frame *k* minus the client's interpolation delay.
  Lync's own client interpolation knows that delay, so the client doesn't need to claim it; the server config sets
  it.
- For Roblox-replicated characters, Lync only has an estimate: `now − RTT/2 − engineInterp ± tolerance`.
  `engineInterp` is not documented (**unverified**); calibrate it per game.
- The ack bounds the claim from both sides:
  - acking a frame never sent is a certain signal;
  - acking an old frame is allowed but bounded by `maxRewind`;
  - the RTT estimate bounds what is plausible.
- **Rewind buffer**: per record, a ring of the last *K* positions (and any fields marked `:rewind()`, e.g.
  crouch or alive) at the server tick rate.

**Measured cost** (`.data/docs/probes/anticheat-design/rewind_and_constraints_cost.luau`, 3 runs):

| Operation | Interpreted | Native |
|---|---|---|
| Rewind sample (64-entry ring, binary search + lerp) | 381–408 ns | 110–163 ns |
| Ring push | 74–75 ns | 4–7 ns |

- Memory: 64 × 32 B = 2 KiB per record (f64 t, x, y, z); 100 records = 200 KiB.
- Pushing 100 records at 60 Hz costs about 40 µs/s native.
- Validating one shot against 100 rewound targets is about 13 µs native, plus geometry tests.

**Verifier shape.** `Lync.hitscan{ target = ref(Collection), origin = vec3 claim, dir = unit, maxRange, maxRewind,
originTolerance, hitbox = fn | size }`, which:
1. resolves perceived time from the ack;
2. rewinds the shooter and the target;
3. checks the origin is within tolerance of the rewound shooter;
4. checks the ray hits the rewound target hitbox;
5. optionally raycasts the world for occlusion at present time (Roblox can't rewind world geometry, which is
   usually static).

**False-positive risk.**
- Tolerances must absorb interpolation differences and packet jitter.
- The rewind window must cover the 99th-percentile RTT of the game's players; under-coverage punishes high-ping
  players with misses, not bans.
- Hit-verification failures should *drop the claim* (quiet mitigation) and add only a weak signal.

### 4.2 Schema-declared physical and game constraints

**AAA practice and Roblox guidance.** Roblox's movement-validation section recommends "leaky bucket-style
accumulators" for burst movement, projecting onto the XZ plane, "averaging over time" for latency, and "explicit
exemption systems" for teleports (**documented**). Its heuristics section adds "Fastest Completion Time" and "Rate
of Gain".

**Lync design: constraints as field and definition modifiers**, compiled into per-player server state:

| Modifier | Meaning | Per-player state | Check |
|---|---|---|---|
| `:maxRate(units/s, burst)` on a numeric or vector field | value changes no faster than a rate | last value, last time, bucket (24 B) | leaky bucket on \|Δ\|, draining at the rate |
| `:planar("xz")` | apply `maxRate` on a projection | — | — |
| `:within(refField or fn, maxDist)` | claim close to a server-known position (e.g. shot origin vs rewound shooter) | — | distance |
| `:cooldown(s)` on a definition | minimum interval between messages | last time (8 B) | `t − last ≥ s`, measured on server arrival time, tolerant of jitter by `burst` |
| `:monotonic()` on an integer field | counters only increase | last (8 B) | `v > last` |
| `:maxTotal(per window)` | rate-of-gain bound | sliding sum (16 B) | sum ≤ cap |
| `:exempt(reason)` API | server opens a short exemption window (teleport, respawn) | expiry (8 B) | skip while open |

- Measured: one leaky bucket + cooldown + monotonic check costs 163–173 ns interpreted and **27–49 ns native** per
  message (same probe).
- At 100 players × 60 messages/s × 3 constrained fields that is about 0.5–0.9 ms/s native: negligible.
- **False-positive risk.** Rate checks on client-reported positions punish lag bursts, which is why the bucket
  exists. Arrival-time cooldowns need a `burst` allowance because packets bunch. Failing a constraint should, by
  default:
  - drop the message, or clamp a value for state-like fields;
  - emit a reasoned signal with a weight;
  - never kick.

### 4.3 Claims against measured RTT

- Lync measures RTT per player from acks (§4.1) with no extra messages.
- Server-checkable impossibilities:
  - **Response before stimulus could arrive**: a client message answering server event *e* (e.g. an interaction
    with a record first shown in frame *k*) arriving sooner than `RTT_min` after *k* was sent means the client acted
    on information it had not received from Lync.
    - The source is either Roblox replication (legitimate, if the game also shows it through Workspace) or a leak.
    - Strong when the data exists only in Lync; weak otherwise.
  - **Reaction-time floor**: the delay from a stimulus becoming relevant to the response, minus RTT, below a
    human floor. The floor is game-specific and not given here. Aggregated over many events this becomes a
    distribution feature (§5), not a per-event verdict.
- **False-positive risk.** Predictable events (a timer everyone can see) make fast responses legitimate. These
  checks belong only on definitions marked `:reactsTo(collectionOrPacket)`.

---

## 5. Telemetry for detection (VACnet-style)

### 5.1 What AAA does

**VACnet** (Valve, GDC 2018, via [PC Gamer](https://www.pcgamer.com/vacnet-csgo), **reported** with direct quotes):
- Each shot is an "atom": changes in pitch and yaw "a half a second before a shot, and a quarter second after",
  plus weapon, distance and the result of the shot (hit, miss, headshot).
- The model scores "140 of them … out of an eight round window".
- Human Overwatch reports convict 15–30 %; "when VACnet submits a case it convicts 80 to 95 percent of the time".
- About four CPU-minutes per match, 600,000 matches per day, about 1,700 CPUs.
- Humans still judge the cases, and "subtle" cheats remain hard.

**XGuardian** (USENIX Security 2026, [arXiv 2601.18068](https://arxiv.org/abs/2601.18068v1), **verified abstract**):
server-side, "requires only two raw data inputs, pitch and yaw … to construct novel temporal features", evaluated
on CS2 and two other games, and explainable.

**BotScreen** (USENIX Security 2023) does the opposite: client-side detection in SGX. A 2026 paper notes SGX's
deprecation; it is not applicable to Roblox (**reported**).

**Rainbow Six Mousetrap** (2023, **reported**): detects input-spoofing devices and responds with ramping input
latency, not bans. Ubisoft reported a 78 % drop in spoofers.

**Activision's security pipeline**: "info from that machine/server exchange splits off and feeds into the security
pipeline in real-time for detection and investigation" (RICOCHET blog, **documented**).

### 5.2 Design: Lync feature streams

**Declared, not inferred.** The schema marks what to record. Lync records only:
- server-visible facts: arrival time, server time, perceived time from the ack, RTT;
- values of fields marked `:feature()`.

**Built-in streams** (per player, ring-buffered, bounded):
- **Cadence**: inter-arrival times per definition marked `:human()`. Mean, variance and quantization are already
  computed online (Welford: 24 B).
- **Aim**: if a definition carries an aim field (`:aim()` on a quantized angle pair) or the game has Server
  Authority camera sync (`Player:GetCameraState()`, documented 2026-07 to synchronise "CFrame, FieldOfView,
  ViewportSize" client→server), Lync samples pitch and yaw at a declared rate into a ring.
- **Event atoms**: on each message of a definition marked `:atom(before, after)`, snapshot the aim ring from
  `before` seconds earlier to `after` seconds later (VACnet's 0.5 s / 0.25 s), plus the claim verdicts from §4 and
  any `:feature()` fields.
- **Reaction samples**: from §4.3, per `:reactsTo` pair.
- **Verifier outcomes**: counts per reason (claim rejected, constraint bucket overflow, decoy reference, canary).

**Size.**
- An aim sample is 2 × u16 = 4 B. A 0.75 s atom at 60 Hz is about 180 B.
- 140 atoms per player is about 25 KiB; 100 players is about 2.5 MiB of server memory if all are retained.
- Rings keep the last N atoms (knob).

**Export within Roblox's limits** (all **documented**):

| Sink | Limit | Fit |
|---|---|---|
| `HttpService` to the developer's own backend | 500 requests/min per server (non-Open-Cloud) | Raw atoms, batched per player per match |
| `MemoryStoreService` | Memory 64 KB + 1.2 KB × users (game-wide); 1000 + 120 × CCU request units/min | Cross-server short-term flags only, not raw telemetry |
| `AnalyticsService` custom events | 120 + 20 × CCU requests/min; 3 custom fields; values beyond 8,000 grouped as "Other" | Aggregate rates of signals per reason |
| DataStores | Per-key size and throughput limits (not re-checked here) | Per-player rolling summaries across sessions |

**Privacy and policy.** Sending gameplay telemetry off-platform must comply with Roblox's terms. Raw atoms hold no
personal data beyond the user id (**unverified** against current terms).

**Who trains the model.** Not Lync. Lync's job is to make the features cheap, consistent and bounded, and to offer
a stable export format with names taken from the schema. ML-style detection needs labelled data (Valve used Overwatch
verdicts). Most Roblox developers can start with simple statistical thresholds on the same features.

**Cost.** Per message: one ring write (native ~5 ns, from the push probe) and an O(1) running-statistics update.
Atoms: one copy of about 180 B per atom-marked event. Negligible next to decode.

---

## 6. Watermarking and attribution

**Prior art.**
- WoW screenshots carried a hidden pattern encoding "the account ID, a timestamp and the IP address of the server",
  found by players in 2012 and reportedly present since about 2008 (Engadget/Schneier coverage, **reported**).
- Canary traps and traitor tracing (Chor–Fiat–Naor) are the classical forms (**unverified** citation; well-known
  concepts).
- The goal is not to stop the reading but to know *which account* leaked.

**What leaks on Roblox and why attribution matters.**
- Datamined unreleased content shipped in replicated state.
- Shared "radar" services that aggregate positions from many clients.
- Leaked hidden information (another team's loadout or picks).
- With alts, banning the leaking account is cheap for them, so attribution is mainly evidence for the server and
  for patching the leak.

**Lync design options:**
1. **Per-viewer slot permutation** of record ids in a collection. Any exported dump of ids identifies the viewer,
   since a mapping exists per session.
   - Also blocks cross-client decoy detection (§2.2).
   - Cost: the id column must be encoded per viewer, which costs some of the encode-once saving. It fits the
     per-record chunk model of §1.4 if ids are kept out of the shared chunk.
2. **Low-order watermark in quantized values**: perturb non-gameplay fields (cosmetic offsets, unused precision
   bits of a quantized position below the game's tolerance) with a per-viewer pattern.
   - Defeated by rounding or by averaging several accounts.
   - Risk of visible jitter.
   - Weak; recipe only.
3. **Canary values** (§2.2): unique per-viewer strings or ids in fields the UI doesn't show. They are certain if
   they ever appear outside, and trivially stripped by a careful leaker.
4. **Staged release**: don't replicate unreleased content at all. Information hiding again beats watermarking.

**Honest limit.** Watermarks attribute careless leaks. A leaker who normalises data (re-numbers ids, rounds values)
or uses several accounts defeats them.

---

## 7. Other techniques, judged

| Technique | How it works | Fit for Lync | Verdict |
|---|---|---|---|
| **Quiet mitigation** (Ricochet Damage Shield; Roblox "quiet mitigation" rung) | When confidence is high, silently void the cheater's effect: drop claims, zero damage, withhold early reveal. Damage Shield "disables the cheater's ability to inflict critical damage"; Activision tracks encounters so it never applies "randomly or by accident". | Lync can apply a per-player *policy*: tighter relevancy (no look-ahead), all claims rejected, inbound delay. The game decides when. | Strong and cheap; needs an explicit API, never automatic. |
| **Latency or "quicksand" penalties** | Add input latency for flagged players (Mousetrap) or slow them (Quicksand). | Lync can delay a player's inbound processing. | Activision decommissioned Quicksand: "very visually jarring to anyone in the lobby". Offer delay only as an explicit, documented option; default off. |
| **Commit–reveal** (Baughman & Levine 2001 lockstep; provably fair RNG) | A party commits to a hash, reveals later. | The Roblox server is trusted, so withholding is simpler for hiding server secrets. Two real uses: (1) *provably fair* outcomes (gacha, card shuffles): the server commits to a seed hash and reveals after; (2) *pre-send then reveal key*: ship encrypted bulk data early, reveal a small key at the moment it becomes visible, for zero-latency reveal of large hidden data. | Niche recipe. (2) needs a client-side cipher in Luau: a keyed keystream over a few hundred bytes is cheap; secrecy lasts only until the key arrives. |
| **Deterministic re-simulation** | The server recomputes the client's claimed result from inputs. | `:claim(Lync.derive(fn))` (§3.2). Roblox Server Authority already re-simulates physics. | Good for projectiles and crafting; float determinism caveat. |
| **Server-issued gameplay challenges** | Periodic interactions that only an attentive human passes (anti-AFK-bot). | Needs game UI; Lync could provide a challenge/response definition kind with deadlines. | Recipe; accessibility false-positive risk; not core. |
| **Relevancy telemetry as a bug detector** (Riot dashboards) | Measure relevant time per record kind; alert on outliers. | Lync counts relevant pair-ticks per collection and kind. | Cheap; ship with relevancy. |
| **Hidden-information protocols** (OpenConflict) | Cryptographic sharing so peers learn only entitled state. | Unneeded: the server is trusted and simply doesn't send. | Not applicable beyond §1. |
| **Kernel/client anti-cheat** | Driver-level integrity. | Platform's job (Hyperion). | Out of scope. |
| **Behaviourally invisible decoys for bots** (AFK farmers, auto-collectors) | A pickup only a raw-state-reading bot would collect, placed where honest players can't reach it. | Decoy record in a pickup collection plus the reference check (§2.2). | Cheap recipe; very low false-positive risk when placed in unreachable geometry. |
| **Interest-managed events** | Events about an entity go only where it is relevant (Riot's lesson). | `:about(ref)` (§1.4). | Core with relevancy. |

---

## 8. Signal model: what the server receives

All of the above should feed one structured stream, as recommended by Roblox's "suspicion score" guidance ("Severe
actions … only after multiple, varied detections") and its consequence ladder ("Silent logging → Quiet mitigation
→ Temporary restrictions → Visible enforcement", "Delay visible consequences").

| Signal | Source | Confidence | Default weight (suggested) | Default action |
|---|---|---|---|---|
| Wrong-direction or trap definition | wire | certain | 10 | drop + signal |
| Decoy reference (`ref` to a decoy slot) | §2.2 | certain | 10 | signal only (keep the decoy running) |
| Canary echoed | §2.2 | certain | 10 | signal |
| Ack of a frame never sent | §4.1 | certain | 10 | drop |
| Rewound hit hits a decoy hitbox | §2.2 + §4.1 | strong | 5 | void claim |
| Claim verifier failed | §3.2, §4.1 | medium (lag) | 1 | drop claim |
| Constraint bucket overflow | §4.2 | medium | 1 | drop or clamp |
| Response before stimulus could arrive | §4.3 | medium (if the data exists only in Lync) | 2 | signal |
| Cadence or reaction outlier | §5 | weak | 0.5 | signal |

- Events are coalesced per (player, reason) per window and carry counts, so a burst can't flood the server.
- The score decays with a half-life.
- Lync never kicks or bans. It exposes the score, the evidence (recent atoms), and the mitigation policy hook.

---

## 9. Mapping summary: Roblox constraints versus each technique

| Technique | Network ownership (no Server Authority) | Server Authority | Replication model | Interpreted clients |
|---|---|---|---|---|
| Relevancy (§1) | Characters leak regardless | Characters still leak | Works for Lync state only | No client cost |
| Decoys (§2) | Spatial decoys can't be Roblox characters | Same | Lync records only | Client cost = one record |
| Intent typing (§3) | Movement is not via Lync anyway | InputActions for simulation; Lync for intents and claims | — | None |
| Rewind (§4.1) | Shooter's position is client-owned: verify the origin against the server-replicated character position, with tolerance | Character positions are server-authoritative: better rewind source | Lync records exact; characters estimated | +2 B ack per upstream frame |
| Constraints (§4.2) | Most valuable here (no engine movement checks) | Less needed for movement; still needed for economy and claims | — | None |
| Telemetry (§5) | Aim needs a Lync `:aim()` field | `GetCameraState()` gives camera server-side | — | Aim field costs upstream bytes (4 B × rate) |
| Watermarks (§6) | — | — | Per-viewer encode cost | None |

---

## Implications

Ranked by value per unit of developer effort. "Core" means it ships in Lync and is on by default or one call away.
"Extension" means first-party but opt-in and separately documented. "Recipe" means documented patterns built on
core hooks.

1. **Direction and trap checks on every definition.** Core, always on. (§2.2, §8)
   - Knobs: `trapDefinitions` (count of auto-generated client→server trap ids hidden from the typed API, 0–8,
     default 2); signal weights.
   - Limit: catches only blind wire-level senders, never API-driven ones.
2. **Upstream ack + server-derived perceived time + RTT.** Core. (§4.1, §4.3)
   - Knobs: ack field width (16 bit; 2 B per upstream frame); `interpDelay` for Lync-interpolated collections
     (seconds, default 0.1, range 0–0.5); `engineInterpEstimate` for Roblox characters (seconds, default 0.1,
     calibrate per game); `maxRewind` (seconds, default 0.5, range 0.1–1.0).
   - Limit: for Roblox-replicated characters it is an estimate with tolerance, not exact.
3. **Schema constraints compiled to per-player checks** (`maxRate`, `planar`, `within`, `cooldown`, `monotonic`,
   `maxTotal`, `exempt`). Core. (§4.2)
   - Knobs: per modifier, units as in the table; failure policy `drop | clamp | signal` (default `drop` for events,
     `clamp` for state); burst allowance.
   - Cost: 27–49 ns native per check.
   - Limit: only as good as the bounds the developer writes; lag bursts need the bucket.
4. **Input/claim/outcome typing for client→server fields.** Core, as types and lint. (§3.2)
   - Knobs: `:input()`, `:claim(verifier)`; a server-view definition error for claims without a verifier; a
     warning for unannotated free-form fields.
   - Limit: the compiler can't recognise outcomes semantically; this is deliberate friction, not proof.
5. **Per-viewer relevancy for replicated collections, with scoped events.** Extension, with core hooks for
   per-record chunk encoding and an indistinguishable removal. (§1.4)
   - Knobs: `radius` (studs); `lookAhead` (seconds, default = measured one-way + `interpDelay`, minimum 0.1);
     `hold` (ticks, default 3); `rate` (Hz, default 20, range 5–60); `cells` (precomputed bitset or nil);
     `predicate`; field visibility classes (`owner | team | relevant | all | fn`); `:about(ref)` on packets.
   - Measured: 0.25 ms per 100 × 200 pass native (~0.5 % of a core at 20 Hz).
   - Limit: Roblox characters and other streamed Workspace content are outside Lync's control.
6. **Lag-compensated hit verifier** (`Lync.hitscan` over rewind rings). Extension. (§4.1)
   - Knobs: ring length *K* (default 64 at the server tick rate, 2 KiB per record); `:rewind()` fields;
     `originTolerance` (studs, default 4); `hitbox`; `occlusionCheck` (bool).
   - Measured: ~110–160 ns per rewound sample native.
   - Limit: shot direction is still a client input; aimbots pass geometric checks.
7. **Feature streams and atoms for offline detection.** Extension. (§5)
   - Knobs: `:human()`, `:aim(rateHz)`, `:atom(before, after)` (seconds, default 0.5/0.25), `:feature()`;
     `atomsPerPlayer` (default 140); export sink adapter (`http` batch size and interval).
   - Limit: Lync supplies features, not verdicts; detection quality depends on the developer's labels and model.
8. **Per-viewer decoy records.** Extension. (§2.2)
   - Knobs: per collection `decoys = { behavior = fn | preset("beyondRange" | "insideGeometry" | "behind"),
     target = "suspects" | "sample", maxPerViewer (default 1), rate }`; requires per-viewer slot permutation.
   - Limit: honest invisibility comes from the behaviour the game supplies. Honest aim assist or "target all"
     code produces false positives, and cheats that act only on rendered targets ignore decoys.
9. **Canary fields.** Extension, cheap. (§2.2, §6)
   - Knobs: `:canary()` on string/id fields; per-viewer value length.
   - Limit: catches only careless raw-state readers and leakers.
10. **Per-viewer id permutation as watermark.** Extension, shipped with decoys. (§6)
    - Knobs: on/off per collection.
    - Cost: per-viewer id column encode.
    - Limit: attribution only; normalising leakers defeat it.
11. **Quiet mitigation policy hook.** Core API, no automatic use. (§7, §8)
    - Knobs: per-player `policy = { rejectClaims, noLookAhead, inboundDelay (seconds, default 0, max 0.3) }`.
    - Limit: the developer must decide when; visible penalties (Quicksand) are not recommended.

**Refuse:**
- Client-chosen rewind timestamps. Use perceived time derived from the ack instead.
- Client-side decoy filtering, i.e. any flag that tells honest code a record is fake.
- Automatic kicks or bans from any signal.
- Visible slow-down penalties by default.
- Commit–reveal or cryptographic state sharing as a general feature: the server is trusted, so withholding is
  enough. Keep provably-fair RNG and pre-send/reveal as recipes.
- Raycast-per-pair relevancy without distance and cell pre-filters.

**Open measurements before committing:**
- Roblox `Workspace:Raycast` cost per ray on servers.
- Roblox's interpolation delay for other players' characters, with and without Server Authority.
- Per-record chunk encoding size versus v4 columnar sections.
- PVS table size for a typical Roblox map at 16–32-stud cells.
