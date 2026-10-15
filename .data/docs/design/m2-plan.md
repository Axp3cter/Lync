# Milestone 2 build plan

2026-10-15. Builds `v5.md` §10 item 2 (events and requests, runtime path) on design draft 3.2 and the finished
milestone 1. This is a plan: rules are cited, not restated. Where it fixes something the design leaves to
implementation (files, signatures, seams, test tools), the plan is authoritative for milestone 2. Repo layout,
commands, style and test conventions are `m1-plan.md` §1 and §4, unchanged.

## 1. What milestone 2 adds

A working runtime path: `Lync.server(schema)` and `Lync.client(schema)` exchange events and requests over one
remote pair (`v5.md` §4.1), with the frame format, sequences, tag, replay window and permutation (§4.1–§4.6),
flushing and both schedulers (§5.1), requests (§5.2), joining (§5.3), `limit` (§5.4), the inbound pipeline (§6.1),
facts, counters, console and configuration (§7). It is proven in one Lune process that hosts a server and several
clients over a simulated network, with an adversarial client (§6).

## 2. Seams: one process, both sides

The runtime never touches a Roblox service directly. Everything it needs from the engine comes through a `Host`
record, so a test can build a server runtime and many client runtimes in one process. A runtime holds all its
state; no module keeps runtime state at module level.

`src/host/host.luau` (types only)

```luau
export type Lane = number            -- 0 reliable, 1 unreliable (the fact evidence encoding, v5 §7.3)
export type Connection = { disconnect: (self: Connection) -> () }
export type Transport = {
	open: () -> (),                                          -- server: create the remotes; client: start watching for them
	ready: () -> boolean,                                    -- client: both remotes found; server: true after open
	send: (player: Player?, lane: Lane, frame: buffer, instances: { Instance? }?) -> (),   -- player nil on a client
	broadcast: (lane: Lane, frame: buffer, instances: { Instance? }?) -> (),              -- server: FireAllClients
	onReceive: (handler: (player: Player?, lane: Lane, ...unknown) -> ()) -> (),          -- raw remote arguments
}
export type Host = {
	side: "server" | "client",
	now: () -> number,                    -- Workspace:GetServerTimeNow()
	clock: () -> number,                  -- os.clock(): buckets, timeouts, windows
	entropy32: () -> number,              -- Random.new():NextInteger(0, 2^32 - 1); keys and seeds
	spawn: (f: (...any) -> (), ...any) -> thread,                                -- task.spawn
	report: (message: string) -> (),      -- a native report: task.spawn(error, message, 0) (v5 §7.2)
	warn: (template: string, context: { [string]: any }) -> (),                -- a console line (v5 §7.4)
	onStep: (f: (dt: number) -> ()) -> () -> (),                                -- RunService.PostSimulation; returns disconnect
	onClose: (f: () -> ()) -> (),                                               -- game:BindToClose (server)
	players: () -> { Player },
	onPlayerAdded: (f: (Player) -> ()) -> () -> (),
	onPlayerRemoving: (f: (Player) -> ()) -> () -> (),
	localPlayer: Player?,                                                       -- client only
	transport: Transport,
}
```

- **Roblox.** `src/host/roblox.luau` exports `Roblox.host(side: "server" | "client"): Host.Host`. The server
  creates `ReplicatedStorage.Lync` with `Reliable` (`RemoteEvent`) and `Unreliable` (`UnreliableRemoteEvent`) on
  `open`. The client finds them through `ChildAdded` and never yields. `warn` uses `LogService:Warn(template,
  context)`, or the same constant text through `warn` until Studio confirms the grouping (§7). `onReceive` passes
  `OnServerEvent`/`OnClientEvent` arguments through untouched.
- **Simulated.** `test/support/world.luau` builds hosts with a virtual clock, a fake roster (players are frozen
  tables with `UserId`, `Name` and a `Kick` that records the call, cast to `Player`) and transports joined by the
  network model of §6.1. `spawn` runs the function at once on a coroutine; `report` and `warn` record output for
  the test to claim (`m1-plan.md` §4).
- **Test seam.** `Runtime.new`'s `options.pin` fixes the integrity key and the permutation seed (`v5.md` §8). Only
  tests and the adversarial client use it.

## 3. Modules

The layers are `v5.md` §2, plus `host` beside `diag` at the bottom. A file requires only its own layer or earlier
ones. New files are listed with their public interface; private helpers are the builder's.

### 3.1 Milestone 1 interfaces adopted first

`m1-plan.md` §6.2 is applied to `src/codec/` before anything uses it: the `root` parameter, `Rows.collect`,
`Chunk` with `beginChunk`/`endChunk`, `misses`, and `Run.decode` taking a `Chunk`. Milestone 1's golden tests and
properties must still pass unchanged.

### 3.2 `diag` additions

`src/diag/codes.luau` and `docs/codes/` gain every milestone 2 code, each with its registry page:
- facts: the 17 milestone 2 reasons of `v5.md` §7.3;
- outcomes: `timeout`, `rejected`, `unanswered`, `left`, `shutdown`;
- faults: `validatorError`, `validatorYielded`, `schemaMismatch` (client), `decoderRaised`;
- caller: `wrongSide`, `configureRange`, `unknownTarget`.

Each fact's page fixes its evidence field order, which `Facts.record` uses.

`src/diag/facts.luau` (requires `./codes`, `../host/host`)
```luau
export type Fact = { reason: Codes.Code, player: Player?, namespace: string?, definition: string?,
	count: number, first: number, last: number, evidence: { [string]: number } }      -- frozen when delivered
export type State
Facts.new(host: Host.Host, console: Console.State): State
Facts.record(s: State, reason: Codes.Code, player: Player?, namespace: string?, definition: string?,
	e1: number?, e2: number?, e3: number?, e4: number?, e5: number?)   -- evidence in the registry's order; no allocation
Facts.observe(s: State, f: (Fact) -> ()): Host.Connection
Facts.sweep(s: State, now: number)                                   -- once per flush: closes windows, emits, suppressed
Facts.forget(s: State, player: Player)
Facts.configure(s: State, window: number, perPlayer: number, server: number)
```

Coalescing, caps and `suppressed` follow `v5.md` §7.3. Delivery calls `host.spawn(f, fact)` per observer.

`src/diag/counters.luau`
```luau
export type State
Counters.new(): State
Counters.slot(s: State, name: string): number                        -- once per counter name, at plan or join time
Counters.add(s: State, slot: number, player: Player?, n: number)
Counters.snapshot(s: State, player: Player?): { [string]: any }     -- frozen; v5 §7.4's fields
Counters.forget(s: State, player: Player)
```

`src/diag/console.luau`
```luau
export type State
Console.new(host: Host.Host): State
Console.fact(s: State, reason: Codes.Code, player: Player?, definition: string?, now: number)
Console.sweep(s: State, now: number)
Console.enable(s: State, enabled: boolean)
```

The rules are `v5.md` §7.4: at most 2 lines per code per window, and a client prints only local facts.

### 3.3 `transport` (frames; pure functions)

`src/transport/seq.luau`
```luau
Seq.extend(newest: number, seq12: number): number          -- v5 §4.4: the full value nearest newest
```

`src/transport/header.luau`
```luau
export type Ack = { seq: number, received: number }         -- received bit i: seq − 1 − i (v5 §4.1)
Header.writeDownReliable(w: Bits.Writer, mode: number, tick: number)   -- mode 0 unchanged, 1 plus one, 2 full u16
Header.readDownReliable(r: Bits.Reader): (number?, number, number)    -- mode, tick (when mode 2), rule
Header.writeDownUnreliable(w: Bits.Writer, seq: number?, tick8: number)   -- seq nil: event frame; else state frame
Header.readDownUnreliable(r: Bits.Reader): (boolean?, number, number, number)   -- isState, seq, tick8, rule
Header.writeUp(w: Bits.Writer, lane: Host.Lane, seq: number?, ack: Ack?)   -- seq on the unreliable lane only
Header.readUp(r: Bits.Reader, lane: Host.Lane): (number?, Ack?, number)   -- seq, ack, rule
```

`src/transport/toc.luau`
```luau
export type Segment = { ns: number, count: number }
Toc.write(w: Bits.Writer, lists: { { Segment } })           -- the lists the frame kind has, in v5 §4.1 order
Toc.read(r: Bits.Reader, listCount: number, out: { { Segment } }): number   -- rule; checks rule 6's toc conditions
```

`src/transport/control.luau`
```luau
export type Hello = { version: number, seed: number, hashLow: number, hashHigh: number, name: string }
export type First = { epoch: number, stateRate: number, keyLow: number, keyHigh: number, cover: number,
	permutationSeed: number, probeOneIn: number, probeMaxPerSecond: number, beacon: number }
export type Welcome = { index: number, first: First? }
export type Rate = { epoch: number, stateRate: number }
export type Report = { probes: number, identitySucceeded: number, sourceUnlisted: number, refusedFrames: number }
Control.HELLO, WELCOME, MISMATCH, REKEY, REKEY_ACK, REPORT, BEACON, RATE: number   -- 0–7 (v5 §4.6)
Control.write(w: Bits.Writer, kind: number, rows: { any })     -- one control chunk: type, count − 1, rows
Control.read(r: Bits.Reader, firstWelcome: boolean, out: { any }): (number?, number)   -- kind, rule
```

`Control.read` must be told whether the next `WELCOME` is the connection's first, because only that one carries
`First`.

`src/transport/frame.luau`
```luau
export type Chunk = { ns: number, list: number, bits: buffer, bitLength: number, tail: buffer, instances: { Instance } }
-- list: 1 state, 2 run, 3 remove, 4 rows (index into the frame kind's toc lists)
Frame.chunk(ns: number, list: number, w: Bits.Writer, instances: { Instance }): Chunk   -- w holds one chunk, written from bit 0
Frame.fits(kind: string, chunks: { Chunk }, first: number): number                    -- last index that fits one frame
Frame.down(kind: string, mode: number, tick: number, seq: number?, chunks: { Chunk }, first: number,
	last: number): (buffer, { Instance })      -- kind "reliable" | "event" | "state"; aligned chunks, tails reversed
Frame.up(lane: Host.Lane, seq: number?, ack: Header.Ack?, chunks: { Chunk }): (buffer, { Instance })  -- untagged body
Frame.open(buf: buffer, down: boolean, lane: Host.Lane): (Bits.Reader?, number)       -- reader with stop before the tag
```

- Downstream chunks are byte-aligned and copied; upstream chunks are bit-copied with no alignment, as in `v5.md`
  §4.1–§4.2.
- `Bits.copy(w: Bits.Writer, from: buffer, bitLength: number)` is added to `src/wire/bits.luau` for this.
- The frame size limits are `v5.md` §4.9's, and `Frame.fits` applies them.

`src/transport/tag.luau`
```luau
Tag.compute(key: buffer, count: number, lane: Host.Lane, frame: buffer, length: number, instanceCount: number,
	cover: number): number                                  -- v5 §4.5 input layout; HalfSipHash-1-3, low 16 bits
Tag.append(frame: buffer, tag: number): buffer
Tag.read(frame: buffer): number                              -- the last two bytes, little-endian
```

### 3.4 `session`

`src/session/permutation.luau`
```luau
Permutation.build(seed: number, hashLow: number, space: number, count: number): ({ number }, { number })
	-- forward (canonical id + 1 -> wire id), inverse; seed 0 is the identity (v5 §4.5)
```

`src/session/replay.luau`
```luau
export type Window
Replay.new(): Window
Replay.status(w: Window, full: number): number              -- 0 new, 1 seen, 2 older than the window (v5 §4.5)
Replay.accept(w: Window, full: number)                      -- after the tag verifies
Replay.newest(w: Window): number
```

`src/session/buckets.luau`
```luau
export type Bucket = { rate: number, capacity: number, tokens: number, at: number }
Buckets.new(rate: number, capacity: number, now: number): Bucket   -- starts full (v5 §5.4)
Buckets.take(b: Bucket, n: number, now: number): boolean           -- refills continuously, then takes n if present
Buckets.peek(b: Bucket, now: number): number
```

`src/session/connection.luau` keeps one peer's state: the key, count and expected count, the pending `REKEY`,
the welcomed namespaces and their permutations, the upstream seq and replay window, the last reliable tick sent,
holds, the 16 slots each way with epochs, inbound buckets and `limit` buckets. Its interface is internal to
unit F.

`src/session/handshake.luau`: `HELLO`/`WELCOME`/`MISMATCH`/`RATE`/`REKEY` flows (§4.5–§4.6), the server-wide
namespace registry (indices by first use, the 10 s `HELLO` wait), the untagged-`HELLO` rule, and control
messages taking effect as they are decoded.

`src/session/requests.luau`: slots, epochs, timeouts, the check order and `slotConflict` cases, `lateAnswers`, and
detecting a throwing `handle` by thread status (§5.2).

`src/session/inbound.luau`
```luau
Inbound.receive(rt: Runtime, player: Player?, lane: Host.Lane, ...: unknown)
	-- server: v5 §6.1 steps 1–7; client: shape, decode (§4.8), delivery; one pcall per frame (decoderRaised)
```

### 3.5 `sched`

`src/sched/ticks.luau`: T and its `tick8`, the epoch and `RATE` changes (§5.1, §4.1 ticks).

`src/sched/outbox.luau`
```luau
Outbox.fire(rt: Runtime, def: Ir.Definition, target: Targets.Target?, value: any)   -- encodes now (errors at the caller)
Outbox.ask(rt: Runtime, def: Ir.Definition, player: Player?, value: any, slot: number, epoch: number)
Outbox.answer(rt: Runtime, def: Ir.Definition, player: Player?, slot: number, epoch: number, outcome: number, value: any)
Outbox.control(rt: Runtime, player: Player?, kind: number, row: any)
Outbox.flush(rt: Runtime)          -- resolves targets once, builds runs in call order, shares chunks, decides
                                   -- FireAllClients from targets and tick headers, holds un-welcomed players (v5 §4.2, §5.3)
```

Encoding at `fire` time, rather than at flush, puts a caller error at the caller's line (§7.1). The encoded row
waits for its run in a per-flush writer.

`src/sched/scheduler.luau`
```luau
Scheduler.start(rt: Runtime)       -- connects host.onStep: server every step; client when ≥ 1/60 s has accumulated
Scheduler.mode(rt: Runtime, mode: "automatic" | "manual")
Scheduler.flush(rt: Runtime)       -- Lync.flush(): idempotent, safe in handlers
```

`missedFlush`, `BindToClose` and flushing for a leaving player follow `v5.md` §5.1.

### 3.6 `api`

`src/api/runtime.luau`
```luau
export type Options = { pin: { key: buffer?, permutationSeed: number? }? }
export type Runtime
Runtime.new(side: "server" | "client", host: Host.Host, options: Options?): Runtime
Runtime.view(rt: Runtime, schema: any): any               -- the side's view (Lync.server / Lync.client)
Runtime.flush(rt: Runtime)
Runtime.scheduler(rt: Runtime, mode: "automatic" | "manual")
Runtime.configure(rt: Runtime, options: { [string]: any })   -- v5 §7.5; configureRange at the caller
Runtime.observe(rt: Runtime, f: (Facts.Fact) -> ()): Host.Connection
Runtime.counters(rt: Runtime, player: Player?): { [string]: any }
Runtime.tick(rt: Runtime): number
Runtime.close(rt: Runtime)                                    -- what BindToClose runs
```

`src/api/views.luau`: one view per side per namespace, per `v5.md` §3.5. Definitions expose `fire`, `connect`,
`invoke`, `handle`, `validate`; collections are milestone 4 and expose nothing yet. A metatable miss throws
`wrongSide`. Views match `src/types.luau`'s view types, and `test/types/` gains a game-script check against them.

`src/api/targets.luau`: `Lync.all`, `Lync.except(target)` (the same object for the same argument), and
`Lync.group(players?)` with `add`, `remove`, `has`, `size`, `players`, `destroy`; leavers are removed (§3.5).

`src/init.luau` adds `Lync.server`, `Lync.client`, `Lync.flush`, `Lync.scheduler`, `Lync.configure`,
`Lync.observe`, `Lync.counters`, `Lync.tick`, `Lync.all`, `Lync.except` and `Lync.group`. Each delegates to a
default runtime, created on first use with `Roblox.host(side)` (side from `RunService:IsServer()`).

## 4. Builder units

| Unit | Owns | Must not touch | Starts |
|---|---|---|---|
| **D: frames and wire integrity** | `src/codec/*` (the §3.1 changes only), `src/wire/bits.luau` (`Bits.copy` only), `src/transport/*`, `src/session/{permutation,replay}.luau`, `test/transport/*`, `test/session/{permutation,replay}.spec.luau`, `test/golden/*` | `src/diag`, `src/host`, `src/sched`, `src/api`, other `src/session` files | at once; §3.1 first |
| **E: seams and diagnostics runtime** | `src/host/*`, `src/diag/*`, `docs/codes/*`, `src/session/buckets.luau`, `test/support/{world,net}.luau`, `test/host/*`, `test/diag/*` | `src/codec`, `src/wire`, `src/transport`, `src/sched`, `src/api` | at once, in parallel with D |
| **F: session, scheduler and API** | the remaining `src/session/*`, `src/sched/*`, `src/api/*`, `src/init.luau`, `test/session/*` (not D's), `test/sched/*`, `test/api/*`, `test/world/*`, `test/types/views*` | the other units' files | when D's transport and E's facts, host types and world pass their own tests |

The interfaces of §2–§3 are fixed. A unit that needs one changed asks the lead, and the change is made here first.
E builds `world.luau` against `Runtime.new`'s signature with a stub endpoint, and F plugs in the real runtime.

**Unit D: done when**
- The §3.1 interfaces are in, and every milestone 1 test passes.
- G5 and G7 (`v5.md` §4.10) and the new G10 and G11 (§5 here) are reproduced byte for byte by `Header`, `Toc`,
  `Control`, `Frame` and `Tag`. The helpers in `test/support/frame.luau` are kept only where a test still needs
  one.
- Property tests pass:
  - every header, toc and control row round-trips;
  - `Frame.down` and `Frame.up` round-trip random chunk lists (shared chunks decode the same in every frame they're
    copied into);
  - the frame size limits split exactly at `v5.md` §4.9's constants;
  - the tag verifies at count e and fails at any other count or any changed covered byte;
  - `Seq.extend` handles wraparound;
  - the replay window gives the RFC 4303 results for in-order, reordered, duplicate and too-old sequences;
  - `Permutation.build` is a bijection, seed 0 is the identity, and it matches a fixed vector for seed
    `0x12345678` over 5 ids (recorded in the golden index).
- Mutation tests pass: every §4.8 rule a frame can break (1–9) returns its rule, never raises.

**Unit E: done when**
- `Roblox.host` type-checks against `Host.Host`.
- The simulated world's network model (§6.1) passes its own tests:
  - latency and jitter distributions;
  - reliable order is kept under stalls;
  - unreliable loss, duplication and reorder rates within 1% of their settings over 10^5 frames;
  - the 1000 B unreliable drop;
  - virtual time is deterministic for a given seed.
- Facts:
  - coalescing gives the first occurrence at once and the count and last evidence at window close;
  - both caps hold, and occurrences past them are counted per player and reason, then emitted as `suppressed`;
  - memory per player is bounded, and freed on `forget`;
  - observers run in their own threads, so a throwing observer produces one native report and nothing else.
- Console: at most 2 lines per code per window over 100 players, with constant text; a client prints local facts
  only.
- Counters snapshot `v5.md` §7.4's fields.
- `Buckets` start full and refill continuously.
- Every new code has a registry page, and the registry lint passes.

**Unit F: done when**
- The world suites of §6 pass: every honest scenario raises no fact, and every attack raises exactly its fact.
- Flows covered, end to end:
  - events on both lanes, both directions;
  - `FireAllClients` used exactly when §4.2 allows;
  - a request each way, with all five outcomes;
  - `limit` on both sides, including order per definition;
  - joining with holds on both sides, and a `WELCOME` before the sends it releases;
  - `MISMATCH`;
  - `REKEY`;
  - `RATE` after a late `configure`;
  - the manual scheduler and `missedFlush`;
  - `BindToClose` and leaving.
- Validators:
  - `false` is counted, and an ask answered `rejected`;
  - a throw gives one native report per window plus a counter;
  - a yield is reported as `validatorYielded`.
- Caller errors (`wrongSide`, `configureRange`, `valueRefused` with `data` and `reply` roots) are asserted by code
  and position.
- Type check is clean on both solvers; the view type check passes.
- `bench/inbound.bench.luau` measures the server's per-message cost after decode, interpreted and native, for
  comparison with `v5.md` §6.1's 39 ns native.

## 5. New golden frames

Built by `.data/docs/probes/design-3/golden_m2.luau` (`golden_m2.out`), under `v5.md` §4.10's conditions. Unit D
adds them to `test/golden/index.json` with `milestone: 2`.

| # | What | Bytes |
|---|---|---|
| G10 | down reliable, a client's first reliable frame (`'11'`, T = 0), holding the connection's first `WELCOME` for `arena` (index 1): epoch 1000.5, `stateRate` 20, key `00 … 07`, `tag.cover` 1024, permutation seed 0, the three milestone 5 fields 0 | `03 00 d4 01 29 00 00 00 00 00 a2 47 20 0a 20 40 60 80 a0 c0 e0 00 80 00 00 00 00 00 00 00` |
| G11 | down reliable, tick unchanged, one `MISMATCH` | `ea 0a` |

G5 (ack-only) and G7 (`HELLO`) are milestone 2 frames from `v5.md` §4.10. Milestone 2 sends no state frames, so a
client never sends G5's ack; `Header.writeUp` must still reproduce it.

## 6. The simulated world

### 6.1 Network model

Per client link and direction, seeded, on the virtual clock (`world:step(dt)` delivers what is due, then runs every
runtime's `onStep`):

| Parameter | Unit | Default (honest model) | Meaning |
|---|---|---|---|
| `latency` | s | 0.05 | one-way base delay |
| `jitter` | s | 0.02 | uniform extra delay, per frame; on the unreliable lane it reorders |
| `loss` | fraction | 0.05 | unreliable frames dropped independently |
| `burst` | `{ enter, leave }` per frame | `{ 0, 1 }` (off) | Gilbert–Elliott bad state with 100% unreliable loss |
| `duplicate` | fraction | 0 | unreliable frames delivered twice |
| `stall` | `{ chance per s, seconds }` | `{ 0.05, 0.3 }` | the reliable lane holds every frame for that long, then releases them in order (retransmission) |
| `fps` | Hz | 60 | the client's step rate; 240 tests the 1/60 s flush cap |
| `unreliableLimit` | B | 1000 | larger unreliable frames are dropped silently, as the engine does |

`FireAllClients` delivers one buffer to every client and counts as one call. The world records every call, so tests
can assert call counts.

### 6.2 Honest suites: never a fact

Ten honest clients for 120 virtual seconds, firing every definition of the `arena` schema at random within each
definition's `limit`, invoking `buy` both ways, joining and leaving at random. They run under:
- the honest model;
- `fps = 240`;
- `burst` on;
- a stall no longer than the inbound byte burst covers.

Each run must produce **no fact** and no `[Lync]` output. Each honest cause in `v5.md` §7.3 then gets its own run,
in which only that fact may appear:
- `duplicate = 0.01` gives `replayed` with `seen = 1`;
- a 5 s stall with a heavy sender gives `overBudget`;
- a stall longer than the slack with a client at its `limit` gives `overLimit`;
- a client firing past `limit` gives a local `sendDropped`;
- a join while sending heavily gives `sendDropped` from the hold.

### 6.3 Attacks: exactly their fact

The adversarial client is a world client with the test seam's pinned key (it "extracted the key"). It can call
`send` on its link with any arguments, and can also run an honest Lync client to reuse its encoder. Each attack must
produce its fact for that player, with the listed evidence, and nothing else:

| Attack | Fact (evidence) |
|---|---|
| a call with two buffers, a string, a table or extra arguments | `malformed` (rule 1) |
| random bytes, before and after `WELCOME` | `tagMismatch` |
| replaying a captured reliable frame | `tagMismatch` |
| dropping one of its own Lync frames before sending (a blocked call) | `frameGap` (`skipped` 1) |
| 8 random frames in a row | `desync` (`rekeySent` 1), then `REKEY`; the honest stream resumes on the new key |
| replaying a captured unreliable frame, inside and beyond the window | `replayed` (`seen` 1, then 0) |
| more frames or bytes than the inbound buckets | `overBudget` |
| tagged frames with: non-zero padding; a count past its maximum; an unknown id; a reliable event, ask or control chunk in an unreliable frame; an unreliable event in a reliable frame; a namespace never welcomed; `REKEY-ACK` with no `REKEY`; `BEACON` with beacons off; an unreferenced or repeated instance entry; a reliable frame over 16,384 B | `malformed` (rules 4, 2, 7, 7, 7, 7, 7, 7, 9, 8) |
| a frame whose decode raises (a stubbed decoder, test-only) | `decoderRaised`, plus one native report |
| an ack naming a state seq never sent | `impossibleAck` |
| a second `HELLO` for `arena`, with the same and with another hash | `repeatedHello` (`hashChanged` 0, then 1) |
| a `HELLO` with another hash, seed or version, or an unknown name | `schemaMismatch` (and `MISMATCH`) |
| an answer for a free slot; for another request; an ask on a slot in flight with its epoch | `slotConflict` (`case` 1, 2, 3) |
| `chat` past its `limit`, bypassing the client throttle | `overLimit`; an ask is answered `rejected` |
| a Roblox enum value the server lacks; `nil` for a required instance; an instance of the wrong class | `unresolved` (`what` 1, 2, 3); an ask is answered `rejected` |

The honest clients sharing the world raise no fact during any attack.

## 7. Studio measurements

Each item of `v5.md` §10 that milestone 2 touches is a named constant or a host seam, so a measurement changes one
line. They are measured with a manual Studio kit, `studio/` (a Rojo project mapping `src` and probe scripts that
print results), and recorded under `.data/docs/probes/studio/`. CI never depends on them.

| Measurement | Used for | Until measured |
|---|---|---|
| whether a remote fired at `PostSimulation` leaves in that frame | the flush point | `host.onStep` is `PostSimulation` |
| the engine's reliable payload limit | the 16,384 B split | the split stays at 16,384 B |
| whether the 1000 B unreliable limit counts only the buffer | the unreliable frame size | 1000 B including header, toc and tag |
| reliable retransmission timing | the `limit` slack | 2 s × `perSecond` |
| unreliable duplication and reorder depth | the replay window, 12-bit sequences | 64 frames; honest duplication is a documented cause of `replayed` |
| client-to-server call throttle (about 500 per s per remote type) | the client's flush cap | 60 Hz automatic flushes |
| whether reliable events fired before a listener connects are queued | an unsolicited `WELCOME` | `WELCOME` only answers `HELLO` |
| whether `LogService:Warn` groups by template in the Error Report, and its cost | console lines | the same constant text through `warn` |
| the cost of `warn`, `debug.profilebegin` and the raise | console and `profile` | `profile` defaults to false; nothing raises on hot paths |
| that a `task.spawn(error, …)` error shows natively, with a traceback | native reports | as documented in `[diagnostics §1.4]` |
| `FireAllClients` on `UnreliableRemoteEvent` with instance arrays | broadcasts | per-player sends whenever a frame carries instances |

The last row is conservative on purpose: until Studio confirms that broadcast instance arrays arrive intact, a
frame that carries instances is never broadcast.

## 8. Not in milestone 2

None of the following may appear in `src/`:
- **Milestone 4, collections.** State, remove and rows chunks; state frames and acks (milestone 2 always writes
  ack `'0'` and never an ack-only frame); slots, notify, catch-up, scheduling and budgets of rows;
  `state.budget`/`state.floor` beyond accepting and range-checking them; the collection API.
- **Milestone 3, the compiler.** Generated shards, codegen, the CLI and `lync.toml`. The runtime path is the only
  path, at build seed 0.
- **Milestone 5, client-side integrity.** Producing `REPORT` and `BEACON`, the caller probe, traps, reachability,
  early answers, decoys, canaries, and nonzero build seeds. The server decodes a `REPORT` and ignores it; a
  `BEACON` is malformed while beacons are off.
- **Milestones 6 and 7.** Tooling, the inspector, the profiler adapter, and every extension.
