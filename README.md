<h1 align="center">Lync</h1>

<p align="center">Typed buffer networking for Roblox: packets, queries, and replicated sets.</p>

Write the schema once. Both sides require it, the Luau types fall out of it, and every value packs
into bit level buffers that batch into one frame per client on flush.

```lua
-- Net.luau, required by both sides
return Lync.define("arena", {
    Fighters = Lync.replicate(Lync.struct({
        name  = Lync.str(1, 20),
        team  = Lync.enum({ "red", "blue" }),
        score = Lync.int(0, 1000000):monotonic(),
        pos   = Lync.vec3(Lync.quant(-512, 512, 0.1)):newest(10),
    })):keyBy("team"),

    Strike = Lync.packet(Lync.vec3(Lync.quant(-512, 512, 0.1))):unreliable(),

    Sell = Lync.query(
        Lync.struct({ item = Lync.enum({ "sword", "shield" }) }),
        Lync.struct({ earned = Lync.int(0, 1000000) })
    ),
})
```

```lua
-- server
Net.Strike:onServer(function(at, player) end)
Net.Sell:onServer(function(order, player) return { earned = 25 } end)
Net.Fighters:add(player.UserId, { name = "Ada", team = "red", score = 0, pos = Vector3.zero })

Lync.start()
RunService.PostSimulation:Connect(Lync.flush)
```

```lua
-- client
Net.Fighters:onChanged(function(id, record, old) board(id, record.score) end)

Lync.start()
RunService.PostSimulation:Connect(Lync.flush)

Net.Strike:fireServer(aim())
local ok, receipt = Net.Sell:request({ item = "sword" })
```

`record.score` is a `number` and `receipt.earned` is a `number`. Nothing was annotated and nothing
was generated.

---

## Install

```toml
[dependencies]
Lync = "axp3cter/lync@3.0.9"
```

```bash
npm install @axpecter/lync
```

Or drop `Lync.rbxm` from the latest release into `ReplicatedStorage`.

---

## Primitives

| | Carries | Send | Receive |
| --- | --- | --- | --- |
| `packet` | events | `fireServer` `fireClient` | `onServer` `onClient` |
| `query` | a request and its reply | `request` | `onServer` `onClient` |
| `replicate` | server owned records | `add` `update` `remove` `clear` | `onAdded` `onChanged` `onRemoved` |

---

## Codecs

A codec says how one value validates, encodes and decodes. Out of range throws on the way out and
drops on the way in.

```lua
local Health = Lync.int(0, 100)   -- 7 bits on the wire, where an f32 is 32
```

### Numbers

| | Type | |
| --- | --- | --- |
| `int(min, max)` | `number` | A bounded whole number. |
| `quant(min, max, step)` | `number` | Rounds onto a grid. |
| `angle(degrees)` | `number` | Cyclic, wrapping at a whole turn. |
| `f32()` `f64()` | `number` | Roughly 7 and 15 digits. Reach for `quant` to pick the loss yourself. |
| `vlq()` `vli()` | `number` | Unbounded integers exact to 2^53, unsigned and signed. |
| `bool()` | `boolean` | One flag. Reach for `bitfield` past one. |

### Text

| | Type | |
| --- | --- | --- |
| `str(min, max)` | `string` | Byte length bounded. |
| `str.alphabet(symbols, min, max)` | `string` | Every character from the set. Smaller set, fewer bits. |
| `str.alphanum` `.base32` `.base64` `.digits` `.hex` | `string` | Presets over `alphabet`, each `(min, max)`. |
| `buffer(min, max)` | `buffer` | Opaque bytes. Also how you relay bytes you never open. |

### Roblox

| | Type | |
| --- | --- | --- |
| `vec2(c?)` `vec3(c?)` | `Vector2` `Vector3` | `f32` per component, or hand each one a codec. |
| `vec3.unit(degrees)` | `Vector3` | A direction. Any nonzero vector normalizes at encode. |
| `vec3.bounded(max, step)` | `Vector3` | A direction plus a quantized magnitude. |
| `cframe(position, rotation)` | `CFrame` | A position codec paired with a rotation codec. |
| `rotation.none()` `.axis()` `.direction()` `.quat()` | `CFrame` | Zero, one, two, or three degrees of freedom. |
| `color3()` `.rgb565()` `.palette(t)` | `Color3` | Floats, one 16 bit word, or an index into `t`. |
| `inst(class?)` | `Instance?` | Always optional. A receiver that cannot see it gets nil. |

UDim2, Region3, Ray and the rest go over with `:as`.

### Composites

| | Type | |
| --- | --- | --- |
| `struct({ k = c })` | `{ k: ... }` | Named fields. An undeclared field throws on encode. |
| `array(c, min, max)` | `{ T }` | An ordered list, count bounded. |
| `map(k, v, min, max)` | `{ [K]: V }` | A dictionary, bounded the same way. |
| `optional(c)` | `T?` | May be absent. |
| `tagged(field, { k = c })` | union | One struct per variant, the chosen name rides in `field`. |
| `enum({ "a", "b" })` | `string` | One of a fixed set. |
| `bitfield({ "a", "b" })` | `{ a: boolean }` | Packed flags, one bit each. |
| `unknown(maxBytes)` | `any` | A shape you do not declare. Costs a tag per part, packs nothing. |

### Modifiers

| | Scope | |
| --- | --- | --- |
| `:validate(fn)` | any | `fn(value, ctx)` returns nil to pass or a reason to drop. |
| `:as(to, from)` | any | Maps the wire type to and from your own. |
| `:monotonic()` | set fields | Only climbs, so deltas cost less. A decrease throws. |
| `:newest(hz?)` | set fields | Only the latest matters, and `hz` caps the rate. |

A modifier answers a new codec. A set marker inside a packet or query throws at start.

---

## Packets

```lua
Move = Lync.packet(Lync.vec3()):unreliable(),
Aim  = Lync.packet(Lync.rotation.quat(0.2)):newest(20):timestamped(),
```

| | | |
| --- | --- | --- |
| server | `fireClient(to, payload)` | Encodes once however many receive it. |
| server | `onServer(fn)` | `fn(payload, player, sent?)`. Any number of listeners. |
| client | `fireServer(payload)` | |
| client | `onClient(fn)` | `fn(payload, sent?)`. Any number of listeners. |

Delivery is reliable and ordered by default. The first two below are alternatives, and
`:timestamped()` stacks with either.

| | |
| --- | --- |
| `:unreliable()` | Lossy and unordered, and every fire still goes out. Must fit the unreliable cap. |
| `:newest(hz?)` | Lossy, latest wins. Stale arrivals and unchanged values send nothing. |
| `:timestamped()` | Adds `sent`, an instant on the shared clock. |

`to`, and a set's `audience`, take any of these.

| | |
| --- | --- |
| `Lync.all` | Every client. |
| `Player` | That client. |
| `{ Player }` | The listed clients. |
| `Group` | Its members at send time. |
| `Lync.except(t)` | Everyone but `t`, a player, list, or group. |

Firing at nobody is reported and throws in Studio. Listeners may yield, and one that throws does
not stop the others.

---

## Queries

```lua
local ok, res, data = Net.Sell:request({ item = "sword" })
if ok then print(res.earned) else print(res, data.elapsed) end
```

No ending raises. A reply, a deadline, and a counterparty that never answered all arrive the same
way.

| | | |
| --- | --- | --- |
| client | `request(value, timeout?)` | Yields for the reply. Timeout defaults to 10 s. |
| server | `request(client, value, fn, timeout?)` | `fn(ok, res, data)` on completion. Never yields. |
| server | `onServer(fn)` | The lone responder. What it returns is the reply. |
| client | `onClient(fn)` | The lone responder. |

Four outcomes: `timeout`, `unanswered` when the other side registered none, `leave` when the
counterparty goes, and `shutdown` when `close` runs first. A domain failure like insufficient funds
is a value in your response codec, not an outcome.

---

## Sets

```lua
Net.Fighters:add(id, { name = "Ada", team = "red", score = 0, pos = Vector3.zero })
Net.Fighters:update(id, { score = 10 })   -- only score is sent
```

The server owns the set and each client holds exactly the records its audiences allow. Without
`keyBy` the whole set goes to everyone. `keyBy(field)` splits records by that field's value, and
`audience(key, to)` gives each key its viewers.

```lua
Net.Fighters:audience("red", redTeam)
Net.Fighters:update(id, { team = "blue" })   -- migrates atomically inside this flush
-- viewers of "red" alone   -> onRemoved(id, "removed")
-- viewers of "blue" alone  -> onAdded(id, record)
-- viewers of both keys     -> onChanged(id, record, old)
```

| Server | |
| --- | --- |
| `add(id, record)` | Throws if the id is live. |
| `update(id, fields)` | Only the named fields. `Lync.none` clears an optional one. |
| `remove(id)` `clear()` | Throws on an absent id. |
| `audience(key, to)` | Keyed sets only. |

| Both sides | |
| --- | --- |
| `get(id)` | The live record or nil. Borrowed, so copy what you keep. |
| `#set`, iteration | Count and walk the local view. |
| `onAdded(fn)` | `fn(id, record)` on first sight: an add, a late join, a visibility gain. |
| `onChanged(fn)` | `fn(id, record, old)`. The net record after a flush against the one before. |
| `onRemoved(fn)` | `fn(id, cause)` with `"removed"` or `"cleared"`. |

Only changed fields go out, and only to viewers. Two updates in one flush ship once. An add and a
remove in one flush ship nothing. Ids are exact to 2^53, so UserIds work as they are, Studio's
negative test ids included.

---

## Lifecycle

| | |
| --- | --- |
| `Lync.start()` | Seals definitions and responders. Once per side, after every definition. |
| `Lync.flush()` | Sends everything buffered. Nothing sends without it, and empty flushes are free. |
| `Lync.close()` | A final flush, resolves outstanding requests as `shutdown`, releases the transports. |
| `Lync.stats(name)` | A frozen snapshot of a namespace's counters. Monotonic, so two diff into rates. |

```lua
Lync.flush(8192)            -- every namespace, 8 KB of state per client
Lync.flush("arena", 8192)   -- one namespace, on its own cadence
```

The budget throttles state replication only, so packets, requests and responses always send in
full. Under 1024 throws. Give latency critical traffic its own namespace.

| | |
| --- | --- |
| `Lync.group()` | A mutable membership set that goes anywhere a recipient does. |
| `add` `remove` `has` | Manage membership. `#group` and iteration cover the set. |
| `destroy()` | Empties it and releases it. Any later use throws. |

A group thins out as players leave, and audiences store the group itself.

---

## Validation

Inbound checking has two stages, and a rejection at the first is a drop.

```lua
Damage = Lync.int(0, 500):validate(function(amount, ctx)
    -- ctx.player, ctx.now, ctx.last
    if ctx.last ~= nil and ctx.now - ctx.last < 0.1 then return "faster than 10 Hz" end
    return nil
end)
```

`last` is stamped on every arrival, accepted or not, so a flood of junk cannot reset a sender's
clock. The table is reused, so copy anything you keep. A rejected payload is dropped before your
code sees it and logged as one warning. A rejected request is answered by nothing, so the requester
times out.

---

## Errors and logging

| | |
| --- | --- |
| Programmer error | A call on the wrong side, a second responder, a second `start`. Throws on the spot. |
| Dropped input | A validate reason, a payload the schema turns away. A warning, never thrown. |
| Environmental | A listener or responder that throws. Reported with its trace, and never stalls the rest. |
| Transport | Timeout, a leaver, shutdown. An outcome code handed back, never thrown. |

Every `on*` returns a connection with `:disconnect()`. When a player leaves, each pending request
touching them resolves as `leave`.

```lua
Lync.onLog(function(kind, message, data)
    if data.player ~= nil then flagSuspicious(data.player, data) end
end)
```

`kind` is `warn` for something dropped, `error` for a fault contained, or `debug` in Studio only.
`data` always carries a file and a line. `Lync.console` is the default printer and is itself a
connection, so disconnect it to format records yourself. Match on `data`, never on the message.

---

## Types

Handlers, records and replies come out typed from the schema alone.

```lua
type Fighter = Types.Infer<typeof(Codec)>   -- { name: string, score: number, tag: string? }
```

`Infer` reads a codec, `Schema` reads a table of codecs as the record it describes, and `Update`
types the argument to a set update. All three live in the `Types` module beside `Lync`. Everything
else is on `Lync` directly, for signatures at module boundaries.

```lua
local codec: Lync.Codec<number>
local packet: Lync.Packet<Vector3>
local query: Lync.Query<Order, Receipt>
local set: Lync.Set<Fighter>
local group: Lync.Group
local conn: Lync.Connection
local to: Lync.Recipient           -- Lync.All | Player | { Player } | Group | Lync.Except
local kind: Lync.LogKind           -- "warn" | "error" | "debug"
local cause: Lync.Cause            -- "removed" | "cleared"
local code: Lync.OutcomeCode       -- "timeout" | "unanswered" | "leave" | "shutdown"
local ctx: Lync.ValidateContext    -- player, now, last
local log: Lync.LogData            -- file, line, player?, definition?
local why: Lync.OutcomeData        -- definition, elapsed?
local done: Lync.Outcome<Receipt>  -- a server request's completion callback
local snap: Lync.Stats             -- flushes, sentBytes, receivedBytes, drops, definitions
local row: Lync.DefinitionStats    -- one definition's line in that snapshot
local clear: Lync.None             -- the type of Lync.none
```

### roblox-ts

The same surface, with five differences.

| | Luau | roblox-ts |
| --- | --- | --- |
| calls | `set:add(id, r)` | `set.add(id, r)` |
| count | `#set` | `set.size()` |
| helpers | `Types.Infer<C>` | `Lync.Infer<C>` |
| instance class | `Lync.inst("Player")` | `Lync.inst<Player>()` |
| audience key | untyped | typed, so `audience` before `keyBy` is a compile error |

The package is scoped, so add both roots in `tsconfig.json` and both folders in your project file.

```json
"typeRoots": ["node_modules/@rbxts", "node_modules/@axpecter"]
```

---

## Limits

| | | |
| --- | --- | --- |
| set fields | 64 | Nest the extras in a `struct`, which counts as one field. |
| ids and integers | exact to 2^53 | Past it, carry the value as a `str` or a `buffer`. |
| request timeout | 10 s | Pass a timeout per call. |
| in flight requests | 32768 per namespace | You are leaking requests, and the cap is a detector. |
| state budget | 32 KB/s per client | Raise it with a flush budget, or split the traffic. |
| unreliable schema | just under 1 KB | Drop `:unreliable()`, or narrow the codec. Checked at start. |
| one frame | 1 MB | A loop that fires and never flushes. The throw names the size. |

---

## License

MIT
