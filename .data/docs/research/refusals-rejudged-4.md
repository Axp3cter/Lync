# Five refused items, re-judged on protection and measured cost (R8, R16, R18, R19, R35)

Researcher findings, 2026-10-15. Item numbers and recorded reasons are from `research/security-refusals.md`. The
author's direction: earlier refusals leaned on runtime-path limits and costs that were not thought through, and on
assuming work had to be identical for every player; generation (per build, place, server, session, player) is
available. Each item gives the earlier reason and what it assumed, what the measure protects (capability classes of
`research/client-security.md` §1.2, short names as in `research/generation-methods.md` §0: **code**, **mem**,
**api**, **hook**, **signal**, **packet**, **identity**, **naming**, **clock**, **state**, **share**) and what it
does not, a form in Lync's terms, measured cost, facts, options, and a one-line outcome.

**Labels.** **verified**: I ran it or read the source or the API dump. **documented**: official docs. **reported**:
third party. **unverified**: inference or not checked. Design text cited by file and section is the design's own
statement, not a platform fact.

**Tools.** Luau 0.742 built from `.data/projects/luau` (scratch build, not committed): `luau -O2` interpreted (the
Roblox client), `-O2 --codegen` native (the Roblox server when its scripts are native); `luau-compile --text` for
bytecode; the `luau` skill's API dump (Roblox 0.741.19) for members, security and capabilities. CLI timings are a
shared 2.1 GHz Xeon; they show scale, not Roblox device cost. Engine costs per `FireServer` are unmeasured
(`design/v5.md` §10).

**Probes** (`.data/docs/probes/refusals-rejudged/`, all by `r4_run.sh BUILD_DIR`): `r4_decoy_slots.luau` →
`.out` (R16), `r4_selfcheck.luau` → `.out` (R18), `r4_maxrate.luau` → `.out` and `r4_cooldown.luau` → `.out` (R35).

**Rules applied.** Lync acts on input only by dropping malformed input and by the drop a game declares (`policy`
`"drop"`, `validate`); it reports facts with exact triggers and numeric evidence; no clamping, rewriting or
throttling, no presets or tiers, no option covering several triggers. Every default is derived (inputs shown) or
marked chosen.

## Checklist

- [x] R8 per-client or per-server generated code
- [x] R16 per-viewer decoy slots outside the shared range; decoys only in `:newest()` rows
- [x] R18 hook and environment checks on the client
- [x] R19 client-side decoy filtering
- [ ] R35 constraint modifiers dropped from `checks`: `maxRate`, `planar`, `exempt`, `cooldown`
- [ ] Implications

## R8. Per-client or per-server generated code

**Earlier reason** (`research/client-security.md` §2.1, `research/client-security-build.md` §3.4, `design/v5-changes.md`
draft-2 table): "Clients have no compiler, and server `loadstring` can't reach clients as code";
"`LoadStringEnabled` is server-only and `NotScriptable`". **What it assumed:** that varying client code per client or
per server means *generating* code at run time. It did not consider selecting pre-built code per player, code that
varies through the data it reads, or one build per place.

**Platform facts, re-checked** (API dump 0.741.19 through the skill, **verified**; docs fetched 2026-10-15,
**documented**):
- `ServerScriptService.LoadStringEnabled`: `NotScriptable`, `NotReplicated`, read capability `Basic`. The docs:
  "Toggles whether or not the `loadstring` function can be used by server scripts. Defaults to false"
  ([ServerScriptService](https://create.roblox.com/docs/en-us/reference/engine/classes/ServerScriptService.md)).
- `Script.Source` and `ModuleScript.Source`: read and write capability `PluginOrOpenCloud`, so a server script can't
  write a script that then replicates.
- The only other code-loading members in the dump are `InsertService.LoadAssetWithBytecodeAsync`
  (`RobloxScriptSecurity`) and `SyncScriptBuilder` (`NotCreatable`). `Player.LoadString` is the deprecated
  string-by-key data call, not code.
- Remotes carry no code: "Functions included as arguments for a RemoteEvent or RemoteFunction will not be
  replicated across the client-server boundary" ([remote events](https://create.roblox.com/docs/scripting/events/remote)).
- `AssetService:CreatePlaceAsync` (capability `AssetCreateUpdate`) copies an existing template place, so it adds no
  new code either.

So no route exists by which a server picks, at run time, code that a client then runs. The premise holds.

**What each grain can vary, and which method already does it:**

| Grain | What can differ between clients | Method | Prices |
|---|---|---|---|
| per build | code shape: field order, offsets, tag constants, traps | M1–M3, M15a | hard-coded and **share** tools, per release |
| per place | the whole build: one `lync build` per place of a universe, players teleported between places | none needed (below) | as per build, between the places of one game |
| per server | values read by fixed code: permutation seed, runtime-path layouts and tag constants | `v5.md` §4.5, M14 | hard-coded tools across servers |
| per session | values in the first `WELCOME`; an index into a build-time pool | M8, M6 | **packet**-only key readers (M8); nothing recurring (M6) |
| per player | which pre-built module a client holds | M7 tag-only + M13 (`tagVariant`) | **share**; attribution per frame |

- **"Per-client code"** is M7: N pre-built variant modules, one cloned into each player's `PlayerGui`. With
  round-robin assignment and N ≥ concurrent players, every player in a server holds a different variant (M7, M13).
  It is selection, not generation, and costs what M7 states (tag-only: N modules of one u32 each, and one XOR per
  frame, within noise in `tagbind.out`).
- **"Per-server code"** on the server alone: server `loadstring` could build decoders per server, but server code
  never reaches clients (`ServerScriptService` is not replicated), and client encoders can't follow a layout their
  code doesn't know. So it changes no byte a client sees, and prices nothing. Per-server *values* are M14 (runtime
  path) and the permutation (both paths).
- **Per place** is the one form R8 adds that M6, M7, M13 and M14 don't cover. A universe whose lobby teleports
  players into match places can build each match place in its own `lync build` run. Once `generation-methods.md`
  implication 1 is adopted (a private `rotationSeed` drawn from OS entropy per run), each run has its own field
  order, offsets and tag constants. Nothing crosses places: a teleport opens a new connection with its own `HELLO`,
  whose build id names that place's build. It needs no Lync option, no wire change and no run-time code. Its price
  is one build and one Open Cloud publish per place (`client-security-build.md` §1.8). It prices the classes M1
  prices, between places instead of between releases, and a tool that re-derives layouts per load (**code**,
  **mem**) pays nothing extra. Unlike M7's upstream scope, it composes with weaving (M16).

**Changes / fixed.** Nothing in Lync. Seed-0 golden frames, the schema hash (computed at seed 0) and types are
unchanged, since every per-place build is an ordinary build. The docs line, for the "Generation" page: "A game with
several places can build each place separately. Each build draws its own rotation seed, so layouts and tag
constants differ between places. Lync needs no setting for this."

**Cost.** Zero at run time: each place runs an ordinary build, so there is nothing to measure. Build and publish
time, once per place.

**Facts.** None added. A client holding another place's shard can't reach that place's server in the same session.
A mismatch would be `MISMATCH`, with `schemaMismatch` evidence `seedDiffers` 1 (`v5.md` §4.6), as today.

**Options.** None.

**Outcome: kept refused,** for code generated per client or per server at run time. The reason is the platform,
not cost: no member lets a server deliver code to a client (verified in the dump above). M7 with M13 resolves the
per-player form, M6 and M8 the per-session form, and M14 the per-server form. Per-place builds need only the docs
line above.

## R16. Per-viewer decoy slots outside the shared range; decoys only in `:newest()` rows

**Earlier reason** (`reviews/v5-design-2.md` M4 proposed both; `design/v5-changes.md` draft-3 table, M4): "Not
adopted: per-viewer slots outside the shared range, since a separate range would itself mark decoys". The
`:newest()`-only option has no recorded reason; the design chose per-viewer chunk copies (`v5-integrity.md` §8).
**What it assumed:** that the only alternative to the shared pool is a separate range, and that the pool marks
nothing. Neither was tested.

**What slot schemes protect.** Decoys price **state** readers that act on what they read, and **api** drivers that
fire at every key they find (`decoy-challenge-facts.md` §4.1). A slot scheme decides whether one client, from slot
numbers alone, can sort its own records into decoys and real ones. It does not touch **share** (two accounts
comparing key sets, R15) or placement, which is the game's (`v5-integrity.md` §8).

### What one viewer can learn from slots (measured)

`r4_decoy_slots.luau` models one collection (`maxRecords` 1024; real records arriving as a Poisson stream, each
living EXP(20 s); slots reusable 2 s after a remove and drawn uniformly among free slots, `v5-collections.md` §2) and
one viewer who sees every real record and its own decoy (`maxPerViewer` 1, each living EXP(5 s), replaced at the
next 20 Hz tick). The viewer's statistic: for each add in slot s, the time since it last saw s removed. The table
gives the best balanced accuracy of the rule "gap below G means decoy", over G from 0.5 to 600 s (`r4_decoy_slots.out`,
7,200 s simulated per line, about 1,000–1,500 decoy adds and 22,000–327,000 real adds per line):

| Scheme | 64 live (6% of slots) | 800 live (78%) | 940 live (92%) |
|---|---|---|---|
| `range`: decoy slots ≥ `maxRecords` (R16 as proposed) | 1.000 (and exact by slot number alone) | 1.000 | 1.000 |
| `pool0`: the design's pool, reused with no delay | 1.000 (every decoy gap < 1.99 s, no real one) | 1.000 | 1.000 |
| `pool2`: the pool with the 2 s reuse delay | 0.999 at G = 2.5 s | 0.934 | 0.646 |
| `shared`: one allocator for decoys and real records | 0.507 | 0.507 | 0.506 |

- **The range form marks every decoy exactly.** `maxRecords` is in the shared schema and the hash input
  (`v5.md` §4.7: options include `maxRecords`), so a client knows the shared range. The earlier reason holds.
- **The adopted pool marks them too.** `v5-integrity.md` §8 has viewer A's j-th decoy and viewer B's j-th decoy
  share pool slot j, and "real allocation never uses pool slots", so slot j changes only when every viewer has
  released it. The design doesn't say whether pool slots wait the 2 s reuse delay. Without it, a reuse under 2 s is
  an exact mark, because real slots never do that (`v5-collections.md` §2). With it, a reuse at about 2 s is still a
  near-exact mark wherever free slots are many, because real reuses are spread over minutes. A second tell needs no
  timing: a fixed pool slot never holds a real record, and a viewer who sees every real add sees it.
- **One allocator leaves the statistic at chance** (0.506–0.507): a decoy's slot is drawn exactly as a real
  record's.

### Form: per-viewer decoy slots inside the shared range, from the one allocator

- A decoy add takes its slot from the same free list as a real `set`: uniform among free slots, server `Random`,
  held as allocated until its remove plus 2 s, as for real records. No real record can take it meanwhile. Each
  viewer's decoys hold their own slots, and no slot is shared between viewers.
- **Slot budget.** Decoys hold at most `Players.MaxPlayers` × `maxPerViewer` slots per collection. `maxRecords` must
  cover live records, those removed in the last 2 s, and that product. This replaces "the pool takes `maxPerViewer`
  slots out of `maxRecords`" in the `maxPerViewer` row.
- **No free slot.** When no free slot is left, the decoy add is not made this tick and the server counter
  `decoysUnplaced` (per collection) counts it. The behaviour's next result is diffed as usual, so the add is retried
  at the next tick. A real `set` that finds no free slot throws `recordLimit` as today, and its known causes gain
  "decoys holding slots under a `maxRecords` that doesn't cover `MaxPlayers` × `maxPerViewer`".
- **Generations.** Both ends count adds per slot (`v5-collections.md` §2). With shared slots, a viewer that saw a
  decoy add in slot s and one that didn't would count differently, and one of them would drop the next real
  record's rows as older. So this form needs `interest-rewind.md` §3's fix, which carries `gen:u2` in every add and
  has the client store it instead of counting. A decoy add advances the slot's server-wide count and carries it.
  Other viewers then see a gap in that slot's generations, which `interest` produces anyway; it says that some add
  happened that this viewer was not sent, and nothing about which of its own records are decoys.
- **Wire.** Two bits per add (the generation fix, shared with `interest`), and ws = ⌈log2 `maxRecords`⌉ bits per
  slot field at the larger `maxRecords`. For a 64-record collection at 100 players and `maxPerViewer` 1, the pool
  needs 65 slots plus the reuse delay (7 bits), and this form needs at least 165 plus the reuse delay (8 bits). That
  is 1 bit more per slot field in every add, update, remove and row of that collection: about 12 B per state tick
  per viewer on the 100-player shooter's 1,190 B of rows, +1% (derived, `v5-collections.md` §5).
- **Fixed:** the schema hash (a game that raises `maxRecords` changes it, as any option change does), golden
  frames (G1–G11 hold no collection chunk, `v5.md` §4.10), types, `held(seen)` in slot order
  (`decoy-challenge-facts.md` §1).
- **Server CPU.** One allocator draw per decoy add, the operation a real `set` already does. Memory: none beyond the
  slot table.

### `:newest()`-only decoys

**What it would buy.** No per-viewer re-encode of reliable chunks. The per-viewer copy costs 19.3 µs native per
re-encode at one decoy (`probes/security-costs/RESULTS.md` claim 6, the full k search). Re-encoding at every flush
in which the partition changed (60/s) is 1.2 ms/s per decoy viewer, and 116 ms/s, 11.6% of a core, for 100 decoy
viewers (derived; claim 6 notes its encoder runs at about 2× the build's ns per value, so the build would sit near
half that).

**What it would cost in protection.** A decoy whose reliable fields never change, beside real records whose
reliable fields do, is a tell. Collections with no `:newest()` field could have no decoys.

**Form: re-encode only where a decoy has rows.** A viewer's copy of a changed shared chunk is re-encoded only in a
flush where that viewer's decoys have adds or updates in it. In every other flush the viewer gets the shared chunk
as viewers without decoys do, and stays in `FireAllClients` for that flush if nothing else is per viewer. A decoy's
remove is written into the viewer's copy of the remove chunk, a list of slots that isn't column-coded
(`v5-collections.md` §3).
- **No mark.** The reference encoder picks the fewest bits, with ties to the lower mode and k (`v5.md` §4.3), and is
  deterministic. So a copied chunk is the minimal encoding of the real rows, and a re-encoded one is the minimal
  encoding of the real and decoy rows: a client re-costing columns finds both minimal. The re-encode must use the
  full k search. Claim 6's cheaper "shared chunk's k" form gives non-minimal encodings (+4 B at 16 decoys, +152 B at
  256), and that marks a chunk as holding rows other viewers didn't get. That form is refused.
- **Cost.** Re-encodes per decoy viewer = the flushes where its decoys have reliable rows. A behaviour that moves
  only `:newest()` fields and replaces its decoy every 5 s pays one re-encode per add: 0.2/s × 19.3 µs = 3.9 µs/s
  per viewer, 0.39 ms/s for 100 viewers, against 116 ms/s today (derived from claim 6). A behaviour that moves
  reliable fields every flush pays what it pays today.
- So the `:newest()`-only restriction adds nothing a game can't get by writing a behaviour that moves only
  `:newest()` fields. No option.

**Facts and counters.** No new fact: slot choice and re-encoding change no trigger. New counter `decoysUnplaced`
(server, per collection). New known cause of `recordLimit` (above).

**Options.** Unchanged names; `maxPerViewer`'s cost row is restated:

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `maxPerViewer` | integer | records | 1–256 | 1 (unchanged) | per viewer with decoys: one full-k-search re-encode of each changed chunk in flushes where its decoys have adds or updates there (19.3 µs native per re-encode at 1 decoy, claim 6); a behaviour call and diff per viewer per state tick (0.21–0.32 µs native); up to `MaxPlayers` × `maxPerViewer` slots of `maxRecords` |

**Outcome: adopt narrowed:** per-viewer decoy slots *inside* the shared range, drawn from the one allocator (this
replaces the pool, whose slot reuse marks decoys with 0.65–1.00 balanced accuracy), plus "re-encode only where a
decoy has rows" with the full k search. The separate range stays refused (an exact mark). `:newest()`-only stays
refused as a mode: the re-encode rule gives its saving to any behaviour that moves only `:newest()` fields.

## R18. Hook and environment checks on the client

**Earlier reason** (`client-security.md` §5; `design/v5-changes.md` draft-2 table, 3.5 "they price nothing, at any
cost"): "the standard tools already pass them without extra work (spies wrap hooks in `newcclosure` by default and
hook in place), so they price nothing, and no generation changes the engine functions they inspect. Adonis ships its
equivalent off for false positives; `getfenv` forms deoptimise every script and are barred from the Creator Store."

**What it assumed, item by item.**
- *Checks inspect engine functions* (`FireServer`, `__namecall`, builtins). That is true of every check
  `client-security.md` §5 listed. For those the reason holds: an engine function is a C function, `newcclosure`
  makes a hook report `[C]` and line −1 like the original (`client-security.md` §1.2, §2.2), and generation can't
  change engine functions.
- *The same holds for Lync's own functions.* It doesn't. Lync's closures are Lua functions that Lync creates, in
  tables Lync can freeze, so a `newcclosure` hook put in place of one *differs* from the original (`[C]` instead of
  Lync's source), and a replaced table entry differs by identity. What the check expects is a build product (lines)
  or a load-time value inside Lync's own module, never a baseline taken from engine state that an auto-executed
  script could poison first (`client-security.md` §1.1).
- *Adonis's false positives.* Adonis checks engine and environment state that Roblox changes (`client-security.md`
  §5). A check of Lync's own frozen tables depends on nothing Roblox ships.
- *`getfenv`.* Not needed: the form below uses `debug.info(f, ...)` on function values, `rawget`, `rawequal` and
  `table.isfrozen`.

**VM facts the form rests on** (`r4_selfcheck.out`, **verified** on Luau 0.742 unless marked):
- `rawequal` and `rawget` compile to `FASTCALL2` (builtins 51 and 50), so while Lync's environment is safe an
  in-place hook of either can't change what Lync's check sees (`client-security.md` §2.2: fast calls go to the
  builtin by id). `table.isfrozen` and `debug.info` compile to `GETIMPORT` + `CALLFB`, an ordinary call, so an
  in-place hook of either is seen by the check.
- `table.isfrozen` returns the table's one `readonly` flag, the flag `table.freeze` sets
  (`VM/src/ltablib.cpp` `tfreeze`, `tisfrozen`). An unmodified client can't clear it: freezing is irreversible, and
  writes to a frozen table raise, `rawset` included (the skill's references, Luau 0.740; the probe's write raises).
- `debug.info(f, "sl")` of a function value gives the defining chunk's source and line, identical at `-O0`, `-O1`
  and `-O2`. Level-based walks are not (inlining, `security-tooling.md` §2), so the form never uses levels. A C
  function gives `[C]` and −1.
- **Unverified:** what `debug.info` reports for a Lua function after an executor hooks it in place. sUNC requires
  that "The hook should not have more upvalues than the function you want to hook"
  ([docs.sunc.io hookfunction](https://docs.sunc.io/Closures/hookfunction), documented), which implies the target
  closure object is rewritten. If so, `debug.info` on the original reference reports the hook's chunk. No executor
  was run.

**What it protects.**
- **hook** by entry replacement: a hook installed by writing a new function into Lync's tables. This needs the
  table unfrozen (`setreadonly`/`makewriteable`, `client-security.md` §1.2). The result is kind 4 while the table
  stays unfrozen, and kind 3 after it is re-frozen.
- **hook** in place on Lync's closures, if the executor's in-place hook changes what `debug.info` reports (above,
  unverified): kind 1 (source) or 2 (line).
- With no honest causes (below), any count is a fact about the client's own state. Like the caller probe it is
  client-stated (`v5-integrity.md` §4).

**What it does not protect.**
- **mem**: the counts live in Lync's state and can be zeroed before `REPORT` is encoded, as for every `REPORT` count.
- **hook** on `debug.info` or `table.isfrozen` themselves (ordinary calls, above): one spoof that reports the
  original's values passes kinds 1, 2 and 4 in every Lync game. That spoof is identical across games and builds:
  generation varies which items and lines are checked, never the primitives the check must call. Kind 3 needs, in
  addition, the environment-safety class (`setsafeenv`, `client-security.md` §1.2), which turns fast calls back
  into hookable calls.
- **naming** (`debug.setinfo`, chunk names) makes a Lua hook report any source and line.
- Hooks that leave Lync's functions alone: on engine functions (`FireServer`), at the **packet** level, or values
  changed above Lync's API (**api**). Server authority stays the defence there (`security-tooling.md` §9).
- Transient hooks installed and removed between two passes.

**Form** (client runtime; generated path and runtime path):
- **Frozen API tables.** Lync freezes every table it hands to game code that holds a Lync closure: the namespace
  table, each view, and each method table views reach through a metatable. Developer cost: game code that writes
  fields into them raises "attempt to modify a readonly table" at the write.
- **The item list.** The build emits, into the client shard, one list of (table, key, closure, expected line) for
  every entry of those tables holding a Lync closure. `manifest.json` names each item by its 1-based index. The
  runtime path's modules build the same list at load, reading lines with `debug.info(f, "l")` inside their own
  module before `require` returns. The expected source of every item is `debug.info(1, "s")`, read by the module
  that defines the closure.
- **One item checks four things,** in this order, and stops at the first that fails: kind 3, `rawequal(rawget(t, k),
  f)` is false; kind 4, `table.isfrozen(t)` is false; kind 1, `debug.info(f, "s")` differs from the expected source;
  kind 2, `debug.info(f, "l")` differs from the expected line.
- **Schedule.** One pass over the list per second, spread over flushes: each flush checks the next ⌈|list| × Δt⌉
  items, where Δt is the time since the previous flush's check, capped at |list|. A constant, chosen: a hook that
  persists is found within 1 s; no faster schedule finds a transient one.
- **Report.** `REPORT` gains three EG0 fields, `selfCheckFailures` (failing items since the last `REPORT`),
  `selfCheckItem` (index of the first, 0 if none) and `selfCheckKind` (1–4, 0 if none). Under R26's adopted rule, a
  `REPORT` with a non-zero `selfCheckFailures` is pending reliable data, so a persistent failure makes at most one
  forced `REPORT` per second.
- **Build check.** Before writing shards, the build runs the emitted check in the CLI against the emitted shard;
  an item that fails there is a build error (it would be a Lync emission bug).
- **Fixed:** seed-0 golden frames (`REPORT` has no golden vector, `v5.md` §4.10), the schema hash, types, every
  other wire byte. Protocol version: `REPORT`'s field list grows (milestone 5).

**Cost** (`r4_selfcheck.out`, best of 7, 3 runs; the client is interpreted):

| Per item, interpreted | ns |
|---|---|
| kind 3 alone (`rawequal(rawget(t, k), f)`) | 31.7–33.8 |
| kinds 3 and 4 | 48.7–51.4 (78.6 in one noisy run) |
| kinds 1 and 2 (`debug.info(f, "sl")`, two compares) | 77.1–84.9 |
| a whole pass, 202 items, kinds 3–4 | 7.8–9.1 µs |
| a whole pass, 202 items, kinds 1–4 | 21.9–24.7 µs |

So 22–25 µs of client CPU a second for 200 views on the CLI, plus up to one forced `REPORT` a second (6–10 B today, `r2_costs.out`, plus the three new fields:
EG0 of count 1, index 200 and kind 4 is 3 + 15 + 5 = 23 bits, 3 B; derived), and only while an item fails. Server: three more EG0 fields to decode in a `REPORT`. Bytecode: the
list, about four values per item.

**Fact.**

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `reportedSelfCheck` | a `REPORT` with `selfCheckFailures` > 0 | none | `reported` (count), `item` (index in the build's list; `manifest.json` names it), `kind` (1 source differs, 2 line differs, 3 entry is another value, 4 table not frozen); all client-stated | kinds 3 and 4: none (a frozen table can't be written or unfrozen by game code, plugins or the command bar; verified in the VM); kinds 1 and 2: a Lync emission bug, which the build check removes before release |

**Options.** None. The schedule is a constant (chosen: one pass per second). Its cost, 22–25 µs/s on the CLI for
200 views, is 14–16% of the 154 µs/s that tagging the busy model's 70 upstream frames costs a client
(`generation-methods.md` M14, 2.2 µs per 64 B frame interpreted), and it scales with the list, not with traffic.

**Engine-function and environment checks** (the refused list in `client-security.md` §5: `[C]` tests on engine
functions, identity of `FireServer`, executor globals, `getfenv` walks) stay refused for the recorded reason, which
holds for them: they inspect functions generation can't change, which `newcclosure` makes look unchanged, and one
bypass covers every Lync game.

**Outcome: adopt narrowed:** self-checks of Lync's own frozen tables and closures only (kinds 1–4,
`reportedSelfCheck`). Kinds 3 and 4 have VM-verified semantics and no honest cause. The detection rate of kinds
1 and 2 depends on executor internals, which are unverified here. Checks of engine functions and the environment
stay refused.

## R19. Client-side decoy filtering

**Earlier reason** (`anticheat-design.md` §0 item 5, §2.2, refuse list; `design/v5-changes.md` draft-2 table): "Any
flag in memory is a filter for the cheat." The research's own wording: "The typed client API therefore **cannot**
hide decoys. Any filter in Lync's client would be a filter in memory for the cheat to read." **What it assumed:**
that the filter is a flag identical for every player. With generation it need not be: the build could vary where
the mark lives (per build), and a per-session or per-player key could decide which slots are decoys (for example,
a keyed hash of the slot and add count), so no constant bit exists.

**What filtering would buy.** Honest client code would never see decoys, so placement would stop mattering and
`decoyInteraction`'s known causes 1–3 (rendered placement, fast camera turns, in-flight removes;
`decoy-challenge-facts.md` §4.2) would disappear. That is a real gain for developers. Those causes are measurable
today: a fast turn can show a "behind" decoy for about rtt + 1/`state.rate` + D, 0.25 s at 100 ms round trip
(derived there).

**What it would protect, by class, against today's design:**

| Class | Today (decoys look real to every reader) | With a client filter in Lync |
|---|---|---|
| **api** readers (`Net.c:get`, `added`) that aim or collect from what the API returns | priced: they see decoys and act on them (`decoyReferenced`, `decoyInteraction`) | not priced: the filtered API never returns decoys, so these tools never touch one |
| **state** / **mem** readers of Lync's decoded tables | priced | priced only until the tool reads the filter's input from the same process |
| **code** readers | nothing marks decoys | the filter's code is in the shard |
| **share** | key-set comparison (R15) | the same |

- **The filter is defeated by a comparison that needs no key.** Wherever a decoy is filtered, Lync holds it before
  the filter (it was decoded) and doesn't return it after. A tool with **mem** and **api** compares what Lync's
  tables hold with what Lync's API returns, and the difference is the decoy set. Generation can vary where the mark
  lives and how it is keyed, but not that difference, because the API's names are fixed by game code. Per-session
  or per-player keys are read in the same pass as the session key (`generation-methods.md` M6's argument), so they
  add no recurring work.
- **It removes coverage where tools are most common.** API drivers through `require` are the most common route
  (`client-security.md` §1.4, A4, field evidence 2026-06). Today their target selectors meet decoys; with a filter
  they never would.
- **Decoding without holding** doesn't escape the comparison: a client that drops decoy rows inside the decoder
  still has to know which rows to drop, which is the same input in memory.

**Form considered and rejected for the developer's need.** The need, placing decoys without breaking honest
rendering, is met on the server side today. `decoyInteraction` carries `sentAgo`, `removedAgo` and
`heldAtPerceived`, which separate known causes 2–3 from a tool's choice (`decoy-challenge-facts.md` §2), and
`decoyOutsideInterest` keeps placements inside the interest test (`interest-rewind.md` §6.1). A Studio-only mark
sent to a test client would make the live and Studio wire differ. It is not proposed.

**Cost.** Not the reason: none measured, none needed.

**Facts, options.** None.

**Outcome: kept refused.** The reason is protection, not cost: a client filter moves decoys' coverage away from
API-driven readers, and one comparison of Lync's tables with its API defeats it, which no generation can vary.

<!-- items -->
