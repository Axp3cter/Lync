# Lync v4.0.3: inventory

Everything v4 offers, from API to docs, tests, bench and tooling, as the reference for the v5 rewrite.
The v4 tree is archived at `.data/versions/one`; paths below are relative to it. The goals for v5 are
in [v5-goals.md](v5-goals.md).

**Sources.** Every file was read in full, except two test areas covered by name and require lines only:
the second half of `test/units`, and the first half beyond its module mapping. The suite was run once
under Lune 0.10.5: 781 declarations passed, 0 failed, in 45.7 s. Line references like `Session:287`
mean `src/runtime/Session.luau` line 287.

**Contents:** 1 Summary · 2 Public API · 3 Codecs · 4 Logging and errors · 5 Limits · 6 Wire protocol ·
7 Internals · 8 Docs · 9 Tests · 10 Bench · 11 Tooling, CI, release · 12 Defects and mismatches

## 1. Summary

Typed buffer networking for Roblox, in Luau and roblox-ts. A schema is declared once in a module both
sides require. Lync packs every value to the bit from that schema, infers handler types from it, and
batches everything per client per flush.

It offers three primitives in named namespaces:
- **packets:** one-way messages;
- **queries:** a request with one reply;
- **sets:** server-owned records replicated to audiences.

Size: about 17k lines of `src` in 70 modules, about 25k lines of tests, 1.2k lines of bench, and
19k lines of vendored typedefs.

## 2. Public API

The exported table is frozen and holds 38 names (`src/init.luau`).

### 2.1 Lifecycle

| Call | Behaviour |
|---|---|
| `define(name, defs)` | Registers a namespace. Returns the same table, frozen. Name is a non-empty string with no `;` or `=`, used once. Each value must be a packet, query or set that is not already in a namespace. Throws after `start`. |
| `start()` | Once per side. Seals definitions, compiles every namespace (legality, layout, descriptor, hash), creates or finds remotes, and on a client sends the handshake. A second call throws. |
| `flush()` | Sends everything queued, in every namespace. The set-state budget is `max(32768 × seconds since last flush, 1024)` bytes per client. |
| `flush(budget)` / `flush(name, budget?)` | An explicit budget (floor 1024, else throws), and/or one namespace only. Connecting `flush` straight to a signal throws, because the frame time arrives as the budget. |
| `close()` | Flushes, ends open requests with `"shutdown"`, and destroys remotes. A second call does nothing. Sending after `close` throws. |

Ordering rules:
- Require every module that calls `define` before `start`.
- Register query responders before `start`; packet and set listeners may attach at any time.
- Every send happens after `start`.

### 2.2 Packets

- **Declaration:** `packet(codec)`, with optional modifiers:
  - `:unreliable()`: lossy and unordered, every fire sent;
  - `:newest(hz?)`: lossy, latest value per recipient at flush, equal values skipped, `hz` caps the
    send rate per recipient, recipients matched by identity;
  - `:timestamped()`: adds `sent`, on the `GetServerTimeNow` clock, to listener arguments.
- **Combinations:** `unreliable` and `newest` are mutually exclusive. `timestamped` combines with
  either.
- **Size limit:** a lossy packet's worst case must fit 1000 bytes, header included. It is checked at
  `start`.
- **Sending:** `fireServer(value)` from a client; `fireClient(recipient, value)` from the server.
- **Listening:** `onServer(fn(value, player, sent?))` and `onClient(fn(value, sent?))` return a
  Connection. Each listener runs on its own pooled thread and may yield; one that throws is logged
  while the others still run.
- **Wrong side:** registering for the wrong side warns and attaches nothing, so one shared module can
  wire both sides.
- **Nothing listening:** a packet that arrives with no listener warns, once per definition for
  client-sent packets.
- **Empty payloads:** a packet of `empty()` fires with no value; its listener receives `nil` first.
- **Order:** reliable packets keep order within a namespace, across definitions. Within one flush the
  order is replies, then requests, then packets, then set changes.
- **Joining clients:** packets to a client that has not finished joining are dropped.

### 2.3 Queries

- **Declaration:** `query(requestCodec, replyCodec)`.
- **Responders:** one per side, registered before `start`. `onServer(fn(value, player) -> reply)` or
  `onClient(fn(value) -> reply)`. Each request runs the responder on its own thread, so it may yield.
- **Client request:** `request(value, timeout?)` yields and returns `ok, reply` or
  `false, code, { definition, elapsed }`.
- **Server request:** `request(player, value, fn(ok, reply, detail), timeout?)` asks one player and
  calls `fn` exactly once.
- **Timeouts:** the default is 10 s and must be positive and finite. A request never throws once sent.
- **Outcome codes:**
  - `timeout`: also what the asker sees when the other side's validation dropped the request;
  - `unanswered`: no responder, the responder threw or returned an out-of-codec reply, the client was
    still joining, or the client has 64 responders running;
  - `leave`;
  - `shutdown`.
- **Who may answer:** only the asked player's reply counts.

### 2.4 Sets

- **Declaration:** `replicate(struct)` with optional `:keyBy(field)`. A key field must be `bool`,
  `int`, `enum`, `vlq`, `vli` or `str`, and not `optional`, `:newest` or `:as`.
- **Writes, server only, after `start`:**
  - `add(id, record)`: throws if the id is in use;
  - `update(id, fields)`: changes only the fields given; `Lync.none` clears an optional field; an
    unchanged value sends nothing;
  - `remove(id)`;
  - `clear()`;
  - `audience(key, recipient)`: keyed sets only.
- **Write checking:** values are checked at the call; a refused update changes nothing.
- **Ids:** whole numbers with magnitude below 2^53, unique across the set. A negative id is fine.
- **Reads, both sides:**
  - `get(id)` returns the live internal record (borrowed, must not be mutated);
  - `#set` / `size()`;
  - `for id, record in set` / `entries()`.
- **Listeners:**
  - `onAdded(fn(id, record))` fires on an add, a join, or gaining sight through an audience change;
  - `onChanged(fn(id, record, old))`;
  - `onRemoved(fn(id, cause))` with cause `"removed"` or `"cleared"`.
- **Coalescing within a flush:**
  - update then update gives one change;
  - add then remove gives nothing;
  - add then update gives one add with the later value.
- **Callback order** per flush: removals, then arrivals, then changes.
- **Audience rule:**
  - an unkeyed set goes to every client;
  - a keyed set goes to whoever its key's audience names;
  - a key with no audience goes to nobody.
- **Audience changes:**
  - a reassignment sends `onRemoved` to clients that lose sight and `onAdded` to those that gain it;
  - group membership is followed at each flush;
  - a key-field change moves the record in the same flush: the loser gets removed, the gainer gets
    added, a holder of both keys gets changed.
- **Late joiners** and clients gaining sight receive current state in one `onAdded`; history is not
  replayed.
- **Newest fields** (`:newest(hz?)` on a record's own field):
  - sent unreliably and rate capped;
  - one record of the field must fit 1000 bytes;
  - `onChanged` may fire twice when a flush moves both a newest field and a reliable field.
- **Validation:** `:validate` anywhere in a set record is refused, because the server is the trust
  boundary.

### 2.5 Recipients and groups

- **Recipients:** `Lync.all`, a player, a list of players, a group, or `Lync.except(player | list |
  group)`. They are resolved at flush, so `except(group)` follows live membership.
- **Groups:** `group()` gives `add`, `remove` (both idempotent), `has`, `#group` / `size()`,
  `for _, player in group` / `players()`, and `destroy()`, after which any use throws.
- **Leaving players** are removed from every group automatically.
- **Joining clients:** packets are dropped, server requests end `unanswered`, and set records arrive
  as current state once joined.

### 2.6 Encoding without the network

- `encode(codec, value)` returns `buffer, refs?`: an exact-size buffer, plus the instances in order
  when the codec holds `inst`. It throws on a refused value.
- `decode(codec, bytes, refs?)` runs every `:validate` with an empty context (`player = nil`,
  `now = 0`, `last = nil`). It throws on bytes that do not decode or that have bytes left over.
- The bytes are documented as not a storage format across versions.

### 2.7 Types (Luau)

- **Exported from the main module:** `Codec<T>`, `Packet<T>`, `Query<Q, R>`, `Set<T>`, `Group`,
  `Connection`, `Recipient`, `All`, `Except`, `None`, `LogKind`, `LogData`, `Cause`, `OutcomeCode`,
  `OutcomeData`, `Outcome<R>`, `ValidateContext`.
- **Type functions** live in `Lync.Types`, since Luau cannot re-export a type function:
  - `Infer<C>`: the value a codec carries, read from a phantom `_T` field;
  - `Schema<F>`: a table of codecs as a record;
  - `Update<T, None>`: every field optional, with `None` allowed only on optional fields.
- **Internal typing:** heavy use of `any` (handles are `self: any`).

### 2.8 roblox-ts

- **Declarations:** `index.d.ts` is hand-written (265 lines). It mirrors the 38 names, with method
  calls, `size()`, `entries()`, `players()`, `LuaTuple` returns and `Map<K, V>` for map codecs.
- **Stronger than Luau:** `audience` is typed from the `keyBy` field, and is a compile error on
  unkeyed sets. `Lync.Infer`, `Schema` and `Update` are exposed directly.
- **Weaker than the runtime:**
  - `keyBy` accepts any boolean, number or string field, while the runtime refuses non-exact kinds;
  - `tagged` arms accept any object codec, while the runtime requires structs;
  - `inst<T>(className)` takes the type and the class name independently, so they can disagree.
- **Parity:** nothing compares `index.d.ts` to the Luau exports.

## 3. Codecs

A codec is a frozen table with a shared, unfrozen metatable of modifiers. Its fields are `kind`,
`params`, `children`, `validates`, `marker` and optionally `newestHz`, `lift` and `lower`. Children
are shared by reference. Constructor misuse throws a plain string without a position.

Costs below are as implemented, which differs from the docs in places (§12). `width(n)` is the bits
needed to hold `n`, computed via `frexp`.

| Codec | Carries | Wire cost and behaviour |
|---|---|---|
| `bool()` | boolean | 1 bit |
| `int(min, max)` | number | `width(max-min)` bits. Over 24 bits it takes whole bytes alone. Fractions refused. Over 2^53 steps refused at start. |
| `quant(min, max, step)` | number | `width(steps)` bits. Rounds to the nearest step. Values up to `min((max-min)·2^-20, step/2)` outside the bounds are clamped, not refused. |
| `angle(degrees)` | number | Grid of `360/degrees` points (`angle(1)` = 9 bits). Input reduced mod 360. `degrees` must divide 360, checked at start. |
| `f32()` / `f64()` | number | 4 / 8 bytes. Any number, including NaN and inf. |
| `vlq()` / `vli()` | number | 7-bit groups, 1 to 8 bytes. `vli` holds the sign in bit 0 of the first group. Range ±(2^53-1). Non-canonical encodings accepted on read. |
| `empty()` | nil | 0 bytes. Only as a whole packet or query payload. |
| `str(min, max)` | string | Count of `ceil(width(max-min)/8)` bytes (0 when min = max), then raw bytes. Inside a struct a count of up to 24 bits moves into the record's bit word. |
| `str.alphabet(symbols, min, max)` | string | Same count, then each symbol at `width(#symbols-1)` bits. Symbols are bytes, each used once. Padding must be zero. |
| `buffer(min, max)` | buffer | Same as `str`. |
| `struct(fields)` | record | Fields in sorted-name order, in four regions: presence bits and moved counts, then packable bit fields (up to 24 bits each), then fixed byte fields, then variable fields. Fixed nested structs dissolve into the parent. Undeclared fields refused. |
| `array(el, min, max)` | `{ T }` | Count, then a packed bit run if the element is one unchecked grid leaf, else byte-aligned elements. |
| `map(key, value, min, max)` | `{ [K]: V }` | Count, then keys in canonical order (by encoded bytes); the reader demands strictly ascending keys. `inst` keys refused. |
| `optional(codec)` | `T?` | Presence bit in the record word (or a 1-bit word at top level), then the value. Not allowed directly inside array, map, optional, vec or cframe. |
| `tagged(field, { name = struct })` | union | Tag in `ceil(width(#variants-1)/8)` whole bytes (0 for one variant), then the variant. Variants must be structs that do not declare `field`. |
| `enum(names)` | singleton union | `width(#names-1)` bits. Names sorted at construction, so the wire index is the sorted position. |
| `bitfield(names)` | `{ [name]: boolean }` | 1 bit per sorted name. |
| `vec2(c?)` / `vec3(c?)` | Vector2 / Vector3 | 2 or 3 × f32 by default. With a narrow component the leaves join the bit word. |
| `vec3.unit(degrees)` | Vector3 | Octahedral, 2 leaves of `width(floor(180/degrees))` bits: 16 bits at 1°. |
| `rotation.quat(degrees)` | CFrame | Smallest three: 2-bit tag + 3 × `width(floor(180/degrees))` bits. 29 bits at 0.5°. |
| `rotation.none()` | CFrame | 0 bits. |
| `cframe(position, rotation)` | CFrame | Each part laid out on its own, byte aligned. |
| `color3()` / `color3.rgb565()` | Color3 | 3 × f32 / 5-6-5 bits. |
| `inst(class?)` | Instance? | Varint slot (0 = nil) into a per-block sidecar array, sent as the remote's second argument. Class checked with `IsA` on both ends. An instance the receiver cannot see arrives nil. |

**Modifiers.** All three copy the codec and leave the original untouched.
- `:validate(fn(value, context) -> string?)`
  - Runs on arrival and in `decode`, never on send. Checks run in order and the first reason wins.
  - The context `{ player, now, last }` is reused, and `last` advances on every payload, including
    rejected ones.
  - A check declared before `:as` sees the wire type rebuilt through `lower`.
- `:as(lift, lower)`: lift and lower compose with any earlier pair.
- `:newest(hz?)`: only on a set's own fields; any other placement is refused at start or encode.

## 4. Logging and errors

**Four kinds of failure** (as documented):
- a caller's mistake throws at the call;
- dropped input is logged;
- a fault in user code (listener, responder) is logged with a traceback;
- transport failures become query outcomes.

**Log channel.** `onLog(fn(kind, message, data))` returns a Connection. `kind` is `"warn"` or
`"error"`. `data` always has `file` and `line`, plus `player`, `definition`, `code` and per-code
fields when present. One `data` table is shared by all listeners and is not frozen.

**Console.** `Lync.console` is a Connection, attached when the module is required. It prints every
record through `warn` as `[lync] file:line message`, whatever its kind.

**Internals.**
- `Log.refuse` and `Log.error` throw with level 0, so the error carries no position.
- `Log.reject(code, facts)` throws a frozen table that the boundary catches.
- Faults in listeners and responders are caught with `Log.call` and reported with a traceback. The
  record has only `file` and `line`: no definition and no player.
- Errors raised inside `onLog` listeners are not caught.

**Drop codes** (`kernel/Catalog`; a server-side drop is a warning, a client-side drop an error, with
exceptions in §12):

| Code | Meaning | Extra data |
|---|---|---|
| `drop.validate` | A `:validate` refused the value | `reason`, `path` (plus leaked `pathId`, `expectId`, `at`) |
| `drop.tag`, `drop.count`, `drop.varint`, `drop.pad`, `drop.map-order`, `drop.sidecar` | A value broke its codec's bounds | `path`, `expected`, `got` |
| `drop.bounds`, `drop.section`, `drop.defid` | A malformed frame; the rest of the frame is dropped | `said` or `expected`, `got` |
| `drop.hello` | The handshake remote carried something else | |
| `drop.unready` | More than 64 early frames while joining | |
| `drop.mismatch` | Schemas differ | `ours`, `theirs` (hash hex) |

**Rate limit.**
- **Limit:** 8 records per code per player per 10 s window, per namespace. The rest are counted.
- **Summary:** a summary carrying `suppressed` is emitted when a later drop of that code arrives after
  the window, or when the player leaves.
- **Server drops** are never limited.
- **"Nothing listens"** is warned once per definition for client senders.

## 5. Limits

The constants live in `wire/Protocol` unless noted.

| Limit | Value | Behaviour |
|---|---|---|
| Steps in `int`, `quant`, `angle` | below 2^53 | refused at start |
| `rotation.quat`, `vec3.unit` precision | leaves must not straddle 24 bits | refused at start; very fine `vec3.unit` silently falls back to 3 × f32 (§12) |
| Worst case of one payload, request, reply or record | 1,000,000 bytes (`MAX_FIRE`) | refused at start |
| Lossy packet block, newest set field | 1000 bytes (`UNRELIABLE_CAP`) | refused at start |
| Fields per set | 1 to 64 (`MAX_FIELDS`, one 64-bit dirty mask) | refused at start |
| One remote call | 1,000,000 bytes | a larger flush is split across calls, in order |
| Set state per flush | `BUDGET_RATE` 32768 B/s since last flush, floor `BUDGET_FLOOR` 1024 | the rest waits for later flushes; packets, requests and replies are never held |
| State section | `SECTION_BYTES` 1024 | state is budgeted a section at a time |
| Unflushed queue | `DETECTOR_WINDOW` 1 s | an error is logged naming the definition |
| Request timeout | `QUERY_TIMEOUT` 10 s, positive and finite | outcome `timeout`; a bad argument throws |
| Requests in flight | `QUERY_CAP` 32768 per namespace per machine | the next request throws |
| Running responders | `RESPONDER_CAP` 64 per client per namespace | further requests end `unanswered` |
| Early frames while joining | `EARLY_FRAMES` 64 | later ones dropped with `drop.unready` |
| Newest ordering window | `NEWEST_WINDOW` 32768 of a 16-bit sequence | older arrivals dropped |
| Timestamps | `STAMP_BITS` 24 at `STAMP_RATE` 1000/s, wraps every 4.66 h | read against arrival; client stamps clamped to [arrival - `STAMP_WINDOW` 60 s, arrival] |
| Drop records | `DROP_BURST` 8 per `DROP_WINDOW` 10 s per code per client | summarized |

## 6. Wire protocol

- **Remotes.** `ReplicatedStorage.LyncRemotes/<namespace>/` holds `handshake`, `reliable` and
  `unreliable` (an `UnreliableRemoteEvent`). Every fire carries `(buffer, sidecar?)`.
- **Handshake.**
  - **Hello:** client to server, 8 bytes: the 64-bit FNV-1a hash of the namespace descriptor.
  - **Verdict:** server to client, 9 bytes:
    - accept: byte 1 = 1, then an f64 epoch;
    - reject: byte 1 = 0, then the server's hash.
  - Only hashes are compared. The descriptor is never sent, so a mismatch cannot say what differs.
- **Descriptor.**
  - **Format:** `space;name=frame;…` in sorted order, with frames such as
    `packet[delivery,hz,timestamped](tree)`, `query(req)(resp)` and `set[key](record)`.
  - **Included:** each `validate` appears as a mark, so adding or removing one changes the hash.
  - **Excluded:** `lift` and `lower`, the bodies of validators, and any library or layout version.
- **Frames.**
  - A frame is concatenated blocks with no frame header.
  - Each block starts with a definition id of `width(count-1)` bits. Ids are given in sorted name
    order; a query takes two consecutive ids.
  - Block forms:
    - plain or running packets: a count in spare header bits;
    - timestamped: a 24-bit stamp;
    - newest: a 16-bit sequence;
    - request runs: a 16-bit first id, then varint deltas;
    - response runs: an id plus a 1-bit outcome;
    - set sections: a 2-bit kind, one of keyframe, delta, removal or clear;
    - set streams.
  - Ordering classes in a reliable frame: response, request, packet, establish, delta.
- **Encoding primitives.**
  - `Varint`: little-endian 7-bit groups, at most 8.
  - `Sequence`: a 16-bit ring with a half-window "newer" test.
  - `Clock`: 24-bit milliseconds, unwrapped to the nearest congruent instant.
  - `Bytes`: bit put/take, plus canonical byte ordering for map keys.

## 7. Internals

### 7.1 Layers

`scripts/Checks.luau` enforces import directions. Root files (`init`, `Types`) have no layer.

| Layer | May require | Holds |
|---|---|---|
| `kernel` | nothing | `Bits`, `Catalog`, `Explain`, `Heap`, `Listeners`, `Log`, `Threads` (coroutine pool), `Wide` (64-bit words as two bit32 halves) |
| `wire` | kernel | `Bytes`, `Clock`, `Protocol` (constants), `Sequence`, `Varint` |
| `codec` | kernel | constructors and modifiers, constructor legality |
| `shape` | codec, wire, kernel | the schema compiler |
| `channel` | wire, kernel | `Blocks`, `Group`, `Link`, `Outbox`, `Recipients`, `Transport` |
| `state` | shape, channel, wire, kernel | set replication |
| `runtime` | state, channel, shape, wire, kernel | `Session`, `Router`, `Dispatch`, `Handshake`, `Pending`, `Boundary`, `Handles` |
| `api` | all of the above | `Define`, `Lifecycle`, `Packet`, `Query`, `Set`, `Encoding` |

### 7.2 Schema compiler (`shape/`, 19 files, 5.4k lines)

**Pipeline.** Readers and writers are composed from closures at runtime; there is no generated source
and no `loadstring`.
1. A codec is read as a cell tree.
2. `Legality` refuses illegal schemas.
3. `Lower` produces an IR of 15 node kinds, each with `fixed`, `maxBytes` and interned path and
   expectation ids for error messages.
4. `Emit` builds `write(b, pos, value) -> pos` and `read(b, pos, ctx) -> (pos, value)` closures,
   choosing specialized variants at build time.
5. `Compile.build` assigns ids, builds block headers (`Frames`), and produces the descriptor and hash.

**Packing.**
- `Grid` quantizes leaves.
- `Regions` partitions struct fields.
- `Words` plans 4-, 2- and 1-byte windows, choosing the cheaper of two plans.
- `Joins` and `Folds` handle multi-leaf values.
- `Rotation` does the octahedral and smallest-three math.
- Leaves of up to 24 bits pack together; wider leaves take whole bytes.

**Validation.** Validators run on read only. The first failure is parked and raised after the whole
payload is read, so the frame can resume.

**State.**
- Scratch tables live in closure upvalues, so the closures are not re-entrant.
- Module-level state (`parkedPath`, `parkedReason`, `wrapped`, a rotation cache) makes behaviour
  order-dependent.
- `emit/Column` is set-column machinery used only by `state/Sections`.

### 7.3 Networking and replication (`runtime/`, `channel/`, `state/`)

**Session (744 lines), one per namespace.**
- Construction: `Compile.build`, then one `Sync` per set, then `Link`, `Boundary`, `Dispatch`,
  `Pending` and `Router`.
- `Roster` abstracts `Players` (`all`, `onRemoving`) so tests can inject a fake.
- `Handles` binds each definition handle to its session at start and replays listeners attached
  before it.
- Session also holds run assembly, the newest-packet engine, handshake glue, budget math and the
  "queued but never flushed" detector, which is `task.delay(1)` armed by fires and asks only.

**Sending.**
- Consecutive fires of one definition to one recipient on one lane form a run that shares a header
  with a count.
- A run is sealed into a refcounted `Block` tagged with an ordering class.
- Recipients are resolved against the set of admitted players when the run closes, which can be
  before the flush.
- `Link` keeps per-client queues: shared and divergent, each with a lossy variant.
- `Outbox` builds the frames:
  - reliable blocks are merged by class (response, request, packet, establish, delta), then by
    sequence, and split between blocks at 1,000,000 bytes;
  - lossy blocks are split at 1000 bytes, between blocks only;
  - `FireAllClients` is used only when no client has private blocks and no unadmitted player is
    present.

**Receiving.**
- The `Transport` relay calls `Session.arrived`. Before the verdict, up to 64 reliable frames are
  held and lossy frames are discarded.
- `Router.frame` reads the frame block by block.
- `Boundary.ran` runs decode and validation in a `pcall` and logs throttled drops.
- `Dispatch` runs listeners on pooled threads. A run of payloads shares one thread per listener.
- `Sync.settle` runs after every frame.

**Newest packets.**
- Values are held per recipient identity until flush.
- At flush: the `hz` gate, then encode, then skip if the bytes equal the last send.
- A 16-bit sequence ring per definition.
- Only stable recipients keep their entry across flushes: the server, `all`, a player, a live group.

**Timestamps.** 24-bit milliseconds against the namespace epoch, which the server sends in the
verdict.

**Queries.**
- `Pending` allocates ids with a cursor modulo 65536, capped at 32768 live.
- Deadlines sit in a min-heap swept during `flush`, so a timeout fires at flush granularity.
- Responders run on a pooled thread under `Log.call`. The reply goes to the asking player only, with
  a 1-bit outcome (1 = unanswered).

**Handshake.**
- **Server:** always sends a verdict, unthrottled. It admits a client only if the player is still in
  the roster, then seeds every set's catch-up.
- **Client:** on accept it starts sending and replays held frames. On reject it calls `Log.error`,
  which records and throws, and stays silent forever.

**Transport.**
- `ReplicatedStorage.LyncRemotes/<namespace>` holds the three remotes.
- The server parents the folder last, so clients see it complete.
- Clients `WaitForChild` with no deadline.
- `close` only disconnects; the remotes are never destroyed.

**Sets (`state/`, 11 files, 3.1k lines).**
- **Partitions:** one per key value, `{ store, dirt, streams }`. An unkeyed set has one partition
  assigned to `all`.
- **`Store`:**
  - columns (the wire's truth) and rows (the tables handed to callbacks);
  - slot allocation through a min-heap;
  - `prev` baselines for deltas;
  - `sent` marks and 2-bit generations for newest fields.
- **Writes:** validated by dry-encoding before any change.
- **Coalescing:**
  - add then remove cancels;
  - remove then add becomes a replace (a removal plus a keyframe);
  - update never changes a pending add.
- **Flush:**
  1. `resolved`: the audience diff gives gains (catch-up backlogs) and losses (removal or clear
     sections, unbudgeted).
  2. `shared`, two passes: clears and removals, then keyframes and deltas, then newest-field streams.
  3. `behind`: per-client catch-up keyframes within that client's remaining room.
- **Server baselines:** the server applies its own outgoing sections through `Apply` to commit them.
- **Client:** `Apply` keeps a net-effect table (arrived, changed, gone, replaced). Settle fans
  removed, then added, then changed, each sorted by id.
- **Budget:**
  - one budget for the whole namespace per flush, not per client;
  - the first section always goes;
  - the first refusal stops every later partition;
  - there is no carry-over: unsent state stays dirty and is re-encoded next flush.
- **Newest set fields:**
  - a full slot scan per flush;
  - an `hz` gate per field;
  - sections grouped when their slot runs are identical;
  - a u16 sequence and 2-bit generations against stale sections.
- **Clear:** one clear block per partition. Clients report `onRemoved(id, "cleared")` per record.

## 8. Docs

- **Site.** mkdocs-material, published to GitHub Pages by `docs.yml` on pushes touching `docs/`, built
  with `--strict`.
- **Pages.**
  - Home.
  - Guide: getting started, codecs, packets, recipients and groups, queries, sets, lifecycle,
    validation, errors and logging.
  - Reference: codecs, API, types, roblox-ts, limits.
  - Contribute.
- **Style.** Task-oriented, with tables per topic. The limits page lists every enforced limit with
  "at the limit / instead / set by" columns.
- **Verification.** No example is executed, and nothing checks the docs against code. Mismatches are
  in §12.

## 9. Tests

### 9.1 Runner

- **Invocation:** `lune run test/run.luau [seed] [filter]`.
- **Discovery:** the trees `units`, `rules` and `wire` run in that order, files sorted by name.
- **Declarations:** each file returns `Harness.case(name, fn)` and
  `Harness.property(name, source, fn(rng))`.
- **Filter:** a substring of the declaration name only. There is no file or tree filter, and a
  non-numeric first argument silently drops the filter.
- **Output:** plain text, a per-declaration time, no failure list at the end. Exit code 0 or 1.
- **Isolation:** modules are cached process-wide, so module state leaks between tests.
- **Environment:** tests see Lune's `task` and Roblox datatypes and a fake `workspace`. There is no
  `game`, `Players` or `RunService`.

| Tree | Files | Declarations | Properties | Time | Nature |
|---|---|---|---|---|---|
| `units` | 71 | 563 | 27 | 7.3 s | one file per module; several are two-machine integration tests |
| `rules` | 19 | 170 | 9 | 23.5 s | observable promises, mostly example-based, through `Session.new` and doubles |
| `wire` | 7 | 48 | 8 | 14.7 s | goldens, round trips, hostile decode, error catalogue |

### 9.2 Harness

- **Expect:**
  - `holds`, `equal` (structural; NaN equals NaN; `-0` differs from `0`; buffers compared byte by
    byte; datatypes by component), `near`, `alike`, `throws(fn, contains?)`;
  - failures are tagged tables, so a wrong claim is told apart from a crash;
  - values in messages are truncated to 48 characters.
- **Property engine:**
  - `Rng` is xoshiro128** seeded through SplitMix32, and records a tape of drawn words.
  - `Shrink` reduces the tape in the Hypothesis style (delete runs, zero runs, bisect words; budget
    1000 calls).
  - Budgets per source: `leaves` 5000, `kinds` 10000, `schemas` 4000, `encode` 10000, `decode` 15000,
    `model` 1000, `stateful` 300.
  - The seed is the run seed XOR a hash of the name.
  - There is no command to replay a tape. The printed message belongs to the unshrunk failure.
- **Generate** (1144 lines) produces:
  - codec shapes over 26 kinds (`empty` and `inst` are not generated);
  - values inside and outside the domain;
  - corrupted frames;
  - random namespaces;
  - fixed adversarial shapes.
- **Oracle:** a plain-table model of set replication (events per viewer per flush). It is used by
  `rules/Convergence`.
- **Other helpers:** `Replica` (rigs a server and clients on one wire), `Turns` (one value through a
  built codec), `Records` (captures log records), `Limbs` (64-bit multiply cross-check).

### 9.3 Fixtures

| File | Is | Used by |
|---|---|---|
| `Doubles` | fake transport (one delivery round per call, faults on the lossy lane) and fake roster (Folder stand-ins) | tests and bench |
| `Faithful` | a stricter engine-like wire: per-queue FIFO, listener waiting, 1000-byte lossy cap, reordering | `rules/Stateful` only |
| `Schemas` | 7 sample schemas with named cases | tests and bench |
| `Scenarios` | 12 scripted traffic scripts | Convergence and the frame goldens (not bench, despite its header) |
| `Stage` | scenario runner and frame dumper | the frame goldens only |
| `Golden` | hand-pinned descriptors, hashes, sizes and frame hex | `test/wire/Golden` |

### 9.4 What is covered

**Feature to rule file** (the units add module-level coverage):

| Feature | Covered by |
|---|---|
| Reliable packets | Delivery, Lifecycle, Log, Stateful, Costs, Budgets |
| `:unreliable()` | Delivery; Totality (cap only) |
| `:newest()` packets | Delivery, Costs, Stateful |
| `:timestamped()` | Delivery only: `sent` is a number. The clamp and the wrap are unit-only. |
| Queries | Requests, Lifecycle (`shutdown`), Stateful. The `timeout` outcome is never observed by any rule. |
| Set writes and views | Sets, Views, Records, Convergence (oracle), Stateful (model), Migration, Rejoin |
| `keyBy` and audiences | Views, Migration, Rejoin, Stateful (all, one, list, group, except) |
| Newest set fields | Records, Views |
| Budgets and catch-up | Budgets, Convergence (starved), Views, Stateful |
| Groups and recipients | Groups (empty, departed), Stateful |
| Handshake | the accept path only; mismatch and reject are unit-only |
| Logging and drop codes | Log, Requests, Delivery, Lifecycle; `wire/Catalogue` proves every code is reachable |
| Schema identity | Determinism, Describe, the goldens |
| Legality | Totality, Namespaces, Surface |
| `encode` / `decode` | Surface (that they exist); the wire tree (round trips, hostile decode) |
| Public `start` | never called by any test |

**Limits with no rule coverage:**
- the 64 running responders, the drop rate limit and the 60 s stamp clamp (unit-only, in
  `Hardening`);
- the 64 early frames (`wire/Catalogue` only);
- the newest window wraparound;
- the budget rate;
- the detector window;
- an exactly 64-field set (only 65 is tested);
- the 1 MB split for sets, catch-up or replies (packets only);
- the client-side request cap.

**Coverage measurement: none.** There is no line, branch or feature coverage, and no mapping from doc
claims to tests. Partial completeness guards exist:
- goldens must match the fixtures in both directions;
- every generated kind must be classified;
- every catalogue code must be reachable;
- the export table must match a hand-written list.

To know whether a feature is tested today, a contributor greps names across three trees, because name
prefixes (`set.`, `life.`) do not map to files.

**Source modules with no unit file:** `kernel/Explain` (not tested at all), `api/Lifecycle`,
`api/Query` (inside `Packet`), `wire/Protocol`.

### 9.5 TypeScript tests

- `test/Declaration.ts` checks inference and every constructor, using `Exact<A, B>` assertions.
- `test/Rejections.ts` holds 9 `@ts-expect-error` lines.
- `check` runs `tsc` over both files, then compiles `Declaration.ts` with roblox-ts.
- Nothing is executed.
- Not exercised: `describe`, `onClient`, group methods, `empty`, `Schema`, `Update`.

### 9.6 Pain points

- **Duplicated rigs:**
  - "two machines on a wire" is assembled by hand in at least 9 places (52 direct `Session.new` calls
    across tests and fixtures);
  - there are two models of set replication (Oracle and Stateful's inline model);
  - there are two wire doubles.
- **Overlap:**
  - rules and units repeat each other (wrong-side calls appear in 5 files; responder rules in 3);
  - Views restates what Convergence proves against the oracle.
- **Coupling:**
  - 91 of 97 test files require internal modules;
  - most `throws` checks match exact message prose;
  - several cases assert exact bytes.
- **Timing:**
  - real waits (`task.wait(0.03)` and similar);
  - a frame golden that holds only while flushes are under about 31 ms apart, since budgets read the
    real clock.
- **Size:** `rules/Stateful` is 1544 lines; `Generate` is 1144.
- **No self-tests:** `Shrink`, `Generate`, `Oracle`, `Replica`, `Stage`.
- **Goldens:**
  - there is no regeneration path;
  - a mismatch hides a differing byte past character 48.

## 10. Bench

**Runner.** `lune run bench/run.luau` runs 41 rows plus a floor row, against `Doubles` with no faults.

**Method.**
1. A warm batch of 200 ops.
2. Probe the op count until a batch takes at least 2 ms, then scale to a 10 ms batch.
3. Take 5 timed batches.
4. Report the minimum batch time as ns/op.

Allocation is the largest non-negative `gcinfo()` delta at 1 KB resolution, with no forced collection.
Wire bytes come from one fresh-state turn. The floor row is printed, not subtracted.

**Suites:**
- `Compile` (3): schema and namespace build;
- `Roundtrip` (14): encode and decode of 7 fixture cases;
- `Primitives` (8): varint, byte comparison, alphabet writer;
- `Throughput` (3): fire-flush-deliver loop, empty flush, raw remote;
- `Fanout` (3): broadcast to 1, 10 and 100 clients;
- `Deltas` (7): set field updates, coalescing, idle;
- `Replication` (3): a keyed set of 64 records, steady, storm, catch-up.

**Baselines and gating.**
- `Report` compares against `bench/baseline.json` with 3% noise.
- That file does not exist and nothing writes it, so the comparison never prints.
- Nothing gates on the results.
- Bench runs only in the release workflow, with its output discarded.

**Validity.**
- The Lune loader passes a custom environment, which deoptimizes modules and disables codegen. So
  `--!native` and `--!optimize 2` have no effect on the numbers, and the numbers are not Roblox's.
- Rows time server, client and the double's queue together.

## 11. Tooling, CI, release

**`scripts/run.luau` commands** (each step runs; exit 1 if any failed):

| Command | Runs |
|---|---|
| `setup` | `rokit install` |
| `verify` | toolchain probe, StyLua check, line width, layer edges, luau-lsp analysis of every tree, the test suite |
| `fmt` | StyLua over the authored trees |
| `analyze` | luau-lsp only |
| `test` | the suite |
| `bench` | the bench |
| `check` | `tsc`, then a roblox-ts compile of `Declaration.ts` in a throwaway project |
| `build` | `rojo build` to `build/Lync.rbxm` |

**Pins** (`rokit.toml`): luau-lsp 1.69.0, Lune 0.10.5, Rojo 7.7.0, StyLua 2.5.2, Wally 0.3.2. The
toolchain probe checks only luau-lsp, Lune and StyLua.

**Config.**
- `.luaurc`: strict, all lints as errors, aliases `bench`, `fixtures`, `lune`, `src`, `test`.
- StyLua: 4 spaces, 100 columns, sorted requires.
- VS Code: format on save, a ruler at 100, tasks for every command.

**CI and release.**
- `ci.yml` runs `verify`, then `check`, on pushes to main and on PRs.
- `release.yml` is manual: verify, check, bench, build, then a GitHub release with `Lync.rbxm`.
  Publishing to Wally and npm is done by hand.

**Packaging.**
- Wally `axp3cter/lync`, realm shared.
- npm `@axpecter/lync`, exporting `src/**/*.luau` and `index.d.ts`.
- The version is written in four places (`wally.toml`, `package.json`, README, the docs guide).
- There is no changelog.

**Typedefs.** 19k lines are vendored (luau-lsp's Roblox definitions, Lune's stubs) with no record of
provenance or how to regenerate them.

## 12. Defects and mismatches found

**Behaviour.**
1. Misuse errors carry no position (`error(message, 0)`).
2. A validator or `:as` transform that throws on read escapes uncaught. It is logged as `drop.bounds`
   and the rest of the frame is lost.
3. An error inside an `onLog` listener is not caught.
4. `vec3.unit` finer than about 1.07e-5° silently becomes 3 × f32 and stops normalizing.
5. A `:newest` marker on a set's record root is neither refused nor used, but it changes the hash.
6. The hash has no protocol or layout version: two builds with different layouts but the same schema
   text would shake hands.
7. The varint reader accepts non-canonical encodings. Every other bit path rejects non-zero padding.
8. A signed varint accepts `-2^53` while its comment says the limit is one short of it.
9. `Frames.running` adds a byte when the id width is a multiple of 8, including 0. The comment and its
   test's comment say otherwise.
10. `:validate(nil)` silently adds no check, and modifiers do not type-check their arguments.
11. Emitted closures share scratch, so a transform that re-enters the same codec corrupts it.

**Docs versus code.**

12. The `rotation.quat` precision floor is about 1.07e-5°, not "about 0.00002°".
13. `data.file` and `data.line` are not always the declaration site: some records carry an internal
    call site or `"Lync":1`, and faults carry the listener's own location.
14. `drop.hello` and `drop.unready` are warnings on clients, though the docs say client drops are
    errors.
15. `drop.validate` data leaks `pathId`, `expectId` and `at`.
16. Drop summaries are emitted on the next drop after the window or on leave, not when the window
    "reopens".
17. `quant` clamps values just outside its bounds rather than refusing them.
18. `index.d.ts` accepts `keyBy` on fields the runtime refuses at start.

**Tooling.**

19. Bench numbers come from deoptimized code, and there is no baseline or gate.
20. The layer check misses bare-directory requires and root files, and matches requires inside
    comments.
21. The engine seam (`Lifecycle.start`, the real `Transport`) is never executed by any test.

**Probable defects in networking and replication.** Found by reading; no test reaches any of them.

22. A flushing client may send newest set fields back to the server, which drops them as
    `drop.defid`. Tests flush only the server.
23. Server-side set listeners misfire. `onAdded` and `onRemoved` never fire on the server, and an add
    fires `onChanged` with `old` equal to the new record. The docs list these listeners for either
    side.
24. Server-form request callbacks are not isolated. A throw is blamed on the client's frame, or
    aborts `flush` or departure cleanup; a yield stalls frame reading.
25. An unreliable run can seal a block of up to about 1024 bytes, over the 1000-byte cap, and the
    lossy splitter cannot cut inside a block.
26. Query header bytes are not counted in run capacity, so the widest query can overshoot by 2 to 3
    bytes.
27. Newest packet values are held by reference. Mutating one after the fire makes every later
    `flush` throw.
28. A failed encode in `fire` or `ask` leaves the sidecar's instance refs uncleared.
29. Client timestamps taken before the verdict use a provisional epoch.
30. A newest timestamped packet is stamped at flush, not at fire as documented.
31. Generations restart after `clear`, so a late lossy section of an old record can apply to a new
    one.
32. A malformed recipient raises late: at run close or inside `flush`, not at `fireClient`.
33. Group membership is resolved when a run closes, not at flush as documented.
34. `start` is not atomic. A schema error in a later namespace leaves earlier ones open with no
    retry, and `flush` and `close` then index a missing session.
35. Hello replies are not throttled. Only the log is.

**More docs versus code.**

36. `close` does not destroy the remotes.
37. Set writes do not arm the "never flushed" detector.
38. Listeners for a run of payloads share one thread, not one thread each.
39. The budget is per namespace flush, not per client.
