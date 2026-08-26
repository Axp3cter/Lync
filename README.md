<h1 align="center">Lync</h1>

<p align="center">Typed buffer networking for Roblox: packets, queries, and replicated sets.</p>

Declare your traffic once as a schema and require it on both sides.
Lync packs every value into bit-level buffers and batches everything queued into one frame per
client on flush, so a burst of fires costs a single send.
The Luau types fall out of the schema, so nothing is annotated and nothing is generated.

| Primitive | Carries | Send | Receive |
| --- | --- | --- | --- |
| `packet` | events | `fireServer` / `fireClient` | `onServer` / `onClient` |
| `query` | a request and its reply | `request` | respond from `onServer` / `onClient` |
| `set` (`replicate`) | server-owned records | `add` / `update` / `remove` / `clear` | `onAdded` / `onChanged` / `onRemoved` |

---

## Install

For wally, add Lync to `wally.toml`.

```toml
[dependencies]
Lync = "axp3cter/lync@3.0.0"
```

For roblox-ts, install from npm.

```bash
npm install @axpecter/lync
```

Or take `lync.rbxm` from the latest release and drop it into `ReplicatedStorage`.

---

## Quickstart

One shared module holds the schema.
Each side requires it, adds its handlers, and calls `start`.

```lua
-- Net.luau (shared)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)

return Lync.define("arena", {
    Fighters = Lync.replicate(Lync.struct({
        name = Lync.str(1, 20),
        score = Lync.int(0, 1000000):monotonic(),
        pos = Lync.vec3(Lync.quant(-512, 512, 0.1)):newest(10),
    })),

    Strike = Lync.packet(Lync.struct({
        at = Lync.vec3(Lync.quant(-512, 512, 0.1)),
    })),

    Sell = Lync.query(
        Lync.struct({ item = Lync.enum({ "sword", "shield" }) }),
        Lync.struct({ earned = Lync.int(0, 1000000), balance = Lync.int(0, 1000000) })
    ),
})
```

```lua
-- server
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Lync = require(ReplicatedStorage.Packages.Lync)
local Net = require(ReplicatedStorage.Net)

Net.Strike:onServer(function(strike, player)
    local fighter = Net.Fighters:get(player.UserId)
    if fighter then
        Net.Fighters:update(player.UserId, { score = fighter.score + 10 })
    end
end)

Net.Sell:onServer(function(order, player)
    return { earned = 25, balance = 100 }
end)

Players.PlayerAdded:Connect(function(player)
    Net.Fighters:add(player.UserId, {
        name = player.DisplayName,
        score = 0,
        pos = Vector3.zero,
    })
end)

Players.PlayerRemoving:Connect(function(player)
    Net.Fighters:remove(player.UserId)
end)

Lync.start()
RunService.PostSimulation:Connect(function()
    Lync.flush()
end)
```

```lua
-- client
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Lync = require(ReplicatedStorage.Packages.Lync)
local Net = require(ReplicatedStorage.Net)

Net.Fighters:onChanged(function(id, record, old)
    updateBoard(id, record.score)
end)

Lync.start()
RunService.PostSimulation:Connect(function()
    Lync.flush()
end)

Net.Strike:fireServer({ at = aim() })

local ok, receipt = Net.Sell:request({ item = "sword" })
print(if ok then receipt.balance else receipt)
```

| Lifecycle | |
| --- | --- |
| `Lync.start()` | Seals definitions and responders. Call once per side, after every definition. A second call throws. Listeners and set callbacks attach anytime. |
| `Lync.flush()` | Sends everything buffered since the last flush. Nothing sends without it. Empty flushes are free, so flushing from two places is fine. It also takes a byte budget, a namespace, or both. |
| `Lync.close()` | One final flush, resolves outstanding requests as `shutdown`, releases the transports. Traffic after it throws. |

Traffic methods throw before `start`, and declaration methods throw after it.
Traffic queued for a second that no flush drains throws, naming the definition.

---

## Codecs

A codec describes how one value validates, encodes, and decodes.

```lua
local Health = Lync.int(0, 100)        -- 7 bits on the wire, where an f32 is 32
local Stepped = Health:validate(function(hp)
    return if hp % 5 == 0 then nil else "not a step of five"
end)

print(Health == Stepped)               -- false, because a modifier returns a new codec

-- Hit is a packet declared from Health, and 150 is outside the range Health carries.
Net.Hit:fireServer(150)                -- throws on this line rather than on the wire
```

A value out of range throws on the way out and drops on the way in.

### Numbers

| Codec | Type | Notes |
| --- | --- | --- |
| `int(min, max)` | `number` | A bounded whole number. |
| `quant(min, max, step)` | `number` | Rounds values onto a grid. |
| `angle(degrees)` | `number` | Degrees, cyclic, wrapping at 360. |
| `f32()` `f64()` | `number` | Floating point, roughly 7 and 15 digits. Reach for `quant` when the loss should be yours to pick. |
| `vlq()` `vli()` | `number` | Unbounded integers exact to 2^53. `vlq` is unsigned, `vli` signed. |
| `bool()` | `boolean` | A single flag. Reach for `bitfield` past one. |

### Strings and bytes

| Codec | Type | Notes |
| --- | --- | --- |
| `str(min, max)` | `string` | Byte length bounded by `min, max`. |
| `str.alphabet(symbols, min, max)` | `string` | Every character drawn from the symbol set, and the smaller the set the fewer the bits. |
| `str.alphanum` `.base32` `.base64` `.digits` `.hex` | `string` | Ready presets over `alphabet`, each `(min, max)`. `digits` keeps leading zeros. |
| `buffer(min, max)` | `buffer` | Opaque bytes, bounded like `str`. Also how you relay bytes you never open. |

A bounded quantity rides `int`, `quant`, or `vlq` instead: fewer bits and a number in hand.

### Roblox

| Codec | Type | Notes |
| --- | --- | --- |
| `vec2(c?)` `vec3(c?)` | `Vector2` `Vector3` | `f32` per component, or hand each component the codec `c`. |
| `vec3.unit(degrees)` | `Vector3` | A direction at the precision. Any nonzero vector normalizes at encode. |
| `vec3.bounded(max, step)` | `Vector3` | A direction plus a quantized magnitude. |
| `cframe(position, rotation)` | `CFrame` | A position codec paired with a rotation codec. |
| `rotation.none()` `.axis(axis, degrees)` `.direction(degrees)` `.quat(degrees)` | `CFrame` | Zero, one, two, or three degrees of freedom. |
| `color3()` `.rgb565()` `.palette(t)` | `Color3` | Full floats, one 16-bit word, or an index into the table `t`. |
| `inst(class?)` | `Instance?` | Always optional. A receiver that cannot see it gets nil, and a wrong `class` fails the decode. |

UDim2, Region3, Ray, and the rest go over with `:as`.

### Composites

| Codec | Type | Notes |
| --- | --- | --- |
| `struct({ k = c })` | `{ k: ... }` | Named fields. A field the struct does not declare throws on encode. |
| `array(c, min, max)` | `{ T }` | An ordered list, count bounded by `min, max`. |
| `map(k, v, min, max)` | `{ [K]: V }` | A dictionary, bounded the same way. |
| `optional(c)` | `T?` | May be absent. |
| `tagged(field, { k = c })` | union | One struct codec per variant, and the chosen name rides in `field`. |
| `enum({ "a", "b" })` | `string` | One of a fixed set of names. |
| `bitfield({ "a", "b" })` | `{ a: boolean, ... }` | Packed flags, one bit each. |

### Modifiers

| Modifier | Scope | Effect |
| --- | --- | --- |
| `:validate(fn)` | any | Checks an invariant on decode. `fn(value, ctx)` returns nil to pass, a reason string to drop. |
| `:as(to, from)` | any | Maps the wire type to and from your domain type. `to` lifts after decode, `from` lowers before encode. |
| `:monotonic()` | set fields | Marks a value that only climbs, so its deltas cost less. A decreasing update throws. |
| `:newest(hz?)` | set fields | Only the latest matters, and `hz` caps the rate. |

A set marker placed inside a packet or query codec throws at `start()`.

---

## Packets

```lua
-- Inside a define, beside the other definitions.
Move = Lync.packet(Lync.vec3(Lync.quant(-512, 512, 0.1))):unreliable(),
Aim  = Lync.packet(Lync.rotation.quat(0.2)):newest(20):timestamped(),
```

| Side | Method | Behavior |
| --- | --- | --- |
| server | `fireClient(recipient, payload)` | Sends to the recipient's clients. Encodes once however many receive it. |
| server | `onServer(fn)` | `fn(payload, player, sent?)`. Any number of listeners. |
| client | `fireServer(payload)` | Sends to the server. |
| client | `onClient(fn)` | `fn(payload, sent?)`. Any number of listeners. |

`recipient`, and a set's `audience`, take any of these.

| Recipient | Meaning |
| --- | --- |
| `Lync.all` | Every client. |
| `Player` | That client. |
| `{ Player }` | The listed clients. |
| `Group` | Its members at send time. |
| `Lync.except(t)` | Everyone but `t`, a player, list, or group. |

Delivery is reliable and ordered by default.
The first two modifiers below are alternatives, and `:timestamped()` stacks with either.

| Modifier | Effect |
| --- | --- |
| `:unreliable()` | Lossy and unordered, and every fire still goes out. Its schema must fit the unreliable cap, checked at `start()`. |
| `:newest(hz?)` | Lossy, latest wins. Stale arrivals and unchanged values send nothing, and `hz` caps the rate. |
| `:timestamped()` | Stamps the send time as `sent`, an instant on the shared clock, so `Workspace:GetServerTimeNow() - sent` is how old the payload is. |

Firing a packet nobody listens for is reported, and throws in Studio.
Listeners may yield, and one that throws does not stop the others.

---

## Queries

```lua
Net.Sell:onServer(function(order, player)
    return { earned = 25, balance = 100 }
end)

local ok, res, data = Net.Sell:request({ item = "sword" })
if ok then
    print(res.balance)
else
    print(res, data.elapsed) -- "timeout", 10
end
```

A query goes either direction and no ending raises.
A reply, a deadline, and a counterparty that never answered all arrive the same way, as an outcome.
Misuse raises the way it does everywhere else on this surface, which is a call made before `start`
or the form that belongs to the other machine.

| Side | Method | Behavior |
| --- | --- | --- |
| client | `request(value, timeout?)` | Asks the server and yields for the reply. Timeout defaults to 10 s. |
| server | `request(client, value, fn, timeout?)` | Asks one client, and `fn(ok, res, data)` runs on completion. Never yields. |
| server | `onServer(fn)` | The lone responder `fn(value, player)` returns the reply. |
| client | `onClient(fn)` | The lone responder `fn(value)` returns the reply. |

Four outcome codes: `timeout` when the deadline passes, `unanswered` when the other side registered
no responder, `leave` when the counterparty leaves mid-request, and `shutdown` when `close` runs
first.
One responder per direction, registered before `start`.
A domain failure like insufficient funds is a value in your response codec, not an outcome.

---

## Validation

Inbound checking has two stages, and a rejection at the first is a drop.

| Stage | Runs | Question |
| --- | --- | --- |
| decode | the schema and `:validate` | Is it valid and acceptable? Bounds, ranges, tags, then your `fn(value, ctx)` returning nil or a reason. |
| handler | your code | Is the action allowed? Ownership and game rules, which Lync leaves to you. |

```lua
Damage = Lync.int(0, 500):validate(function(amount, ctx)
    -- ctx.player  the authenticated sender
    -- ctx.now     receipt time
    -- ctx.last    when this sender last sent this definition, nil the first time
    if ctx.last ~= nil and ctx.now - ctx.last < 0.1 then return "faster than 10 Hz" end
    return nil
end)
```

Lync stamps `last` on every arrival, accepted or not, so a flood of junk cannot reset a sender's
clock.
The table is reused between calls, so copy anything you keep.

A rejected payload is dropped before your code ever sees it and logged as one warning.
A rejected request is answered by nothing, so the requester times out.
Your reason passes through verbatim. Lync's own names the field path, what it expected, and what
arrived.

---

## Sets

```lua
-- Inside a define, beside the other definitions.
Players = Lync.replicate(Lync.struct({
    hp   = Lync.int(0, 100),
    team = Lync.enum({ "red", "blue" }),
    pos  = Lync.vec3(Lync.quant(-1024, 1024, 0.05)):newest(),
})):keyBy("team"),
```

```lua
Net.Players:add(id, { hp = 100, team = "red", pos = Vector3.zero })   -- server
Net.Players:update(id, { hp = 80 })                                   -- only hp is sent
Net.Players:onChanged(function(id, record, old) end)                  -- both sides
```

The server owns the set, and each client holds exactly the records its audiences allow.
Without `keyBy` the whole set goes to every client.
`keyBy(field)` splits records by that field's value, and `audience(key, recipient)` gives each key
its viewers, using the same recipients a packet fires with.

```lua
Net.Players:audience("red", redTeam)        -- a group, resolved at send time
Net.Players:update(id, { team = "blue" })   -- migrates atomically inside this flush
-- viewers of "red" alone   -> onRemoved(id, "removed")
-- viewers of "blue" alone  -> onAdded(id, record)
-- viewers of both keys     -> onChanged(id, record, old)
```

| Server | Behavior |
| --- | --- |
| `add(id, record)` | Adds the full record. Throws if the id is live. |
| `update(id, fields)` | Changes only the named fields. `Lync.none` clears an optional one. Throws if the id is absent. |
| `remove(id)` | Deletes the record. Throws if the id is absent. |
| `clear()` | Deletes everything. |
| `audience(key, recipient)` | Sets who sees a key's records. Keyed sets only. |

| Both sides | Behavior |
| --- | --- |
| `get(id)` | Reads the live record, nil when absent. Borrowed, so read it and copy what you keep. Development builds freeze it, so a write throws where you made it. |
| `#set`, iteration | Count and walk the local view. |
| `onAdded(fn)` | `fn(id, record)` on first sight: an add, a late join, a visibility gain. |
| `onChanged(fn)` | `fn(id, record, old)`. The net record after a flush, against the record before it. |
| `onRemoved(fn)` | `fn(id, cause)` with cause `"removed"` or `"cleared"`. A record that left your audience reads as `"removed"`, because a cause on the wire would announce a record past the audience that was the only thing meant to know of it. |

```lua
Net.Players:update(id, { hp = 90 })
Net.Players:update(id, { hp = 60 })
-- one flush: hp ships once, onChanged sees 60 against the 100 it held before

Net.Players:add(other, record)
Net.Players:remove(other)
-- one flush: nothing ships at all
```

Only changed fields go out, and only to viewers.
`:newest()` fields send unreliably instead, latest wins.
Ids are integers exact to 2^53, so UserIds work as they are, Studio's negative test ids included.

---

## Namespaces and groups

```lua
Lync.define("arena", defs)   -- isolated traffic, own cadence, and the return is pure data
Lync.flush()                 -- every namespace, default budget
Lync.flush(8192)             -- every namespace, 8 KB of state per client this flush
Lync.flush("arena", 8192)    -- one namespace, on its own cadence
```

`maxBytes` caps state bytes per client for that flush and the rest waits for the next one.
Under 1024 throws, almost always a frame's delta time wired straight into flush.
The budget throttles state replication only, so packets, requests, and responses always send in
full.
Give latency-critical traffic its own namespace, so a burst of state never delays it.

| Group | Behavior |
| --- | --- |
| `Lync.group()` | A mutable membership set that goes anywhere a recipient does. |
| `add` `remove` `has` | Manage membership. `#group` and iteration cover the set. |
| `destroy()` | Empties it and releases it. Any later use throws. |

A group thins out as players leave, and audiences store the group itself, so mutating it moves
every audience and future fire that names it.

---

## Errors

| Class | Examples | Behavior |
| --- | --- | --- |
| Programmer error | A call on the wrong side, a second responder, a second `start`, an `update` on a missing id, an encode out of bounds | Throws on the spot. |
| Dropped input | A validate reason, a payload the schema turns away | A log warning. Never trusted, never thrown, never answered. |
| Environmental | A listener or responder that throws | Reported with its stack trace. One never stalls the rest. |
| Transport | Timeout, a leaver, shutdown | An outcome code handed back to the caller. Never thrown. |

Every `on*` returns a connection, and `:disconnect()` stops it.
When a player leaves, each pending request touching them resolves as `leave`, and Lync releases
everything keyed to them.

---

## Logging

`warn` is something Lync dropped and moved past, a discarded payload most of all.
`error` is a fault it contained.
`debug` is Studio only.

```lua
Lync.onLog(function(kind, message, data)
    -- data.file     always
    -- data.line     always
    -- data.player   set exactly when the record is about a client's input
    -- a drop also carries the definition and the diagnosis
    if data.player ~= nil then flagSuspicious(data.player, data) end
end)
```

| Item | Behavior |
| --- | --- |
| `Lync.onLog(fn)` | `fn(kind, message, data)`, every record. Branch on `kind` and `data`. |
| `Lync.console` | The default printer, itself a connection. Disconnect it to format records yourself. |
| `Lync.stats(name)` | A frozen snapshot of a namespace's counters. Monotonic, so two snapshots diff into exact rates. An unknown name throws, as `flush` does. |
| `handle:describe()` | The schema as readable text, worded the way drop reports are. |

Wording can shift between releases, so match on `data`, never on the message.

---

## Types

Handlers, records, and replies come out typed from the schema alone.

```lua
local Types = require(ReplicatedStorage.Packages.Lync.Types)

local Fighter = Lync.struct({
    name = Lync.str(1, 20),
    score = Lync.int(0, 1000000),
    tag = Lync.optional(Lync.str(0, 8)),
})

type Fighter = Types.Infer<typeof(Fighter)>   -- { name: string, score: number, tag: string? }

Net.Fighters:onChanged(function(id, record)
    local best = record.score + 1             -- a number, with nothing annotated
end)
```

`Schema` reads a table of codecs as the record it describes, and `Update` types the argument to
`set:update`.
All three live in the `Types` module beside `Lync`, not on `Lync` itself.

Everything else is on `Lync` directly, for signatures at module boundaries.

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
| audience key | untyped | `Set<T, K>`, so `audience` before `keyBy` is a compile error. |

Two entries, because the package is scoped. In `tsconfig.json`:

```json
"typeRoots": ["node_modules/@rbxts", "node_modules/@axpecter"]
```

And in your project file, beside `@rbxts`:

```json
"node_modules": {
    "$className": "Folder",
    "@rbxts": { "$path": "node_modules/@rbxts" },
    "@axpecter": { "$path": "node_modules/@axpecter" }
}
```

---

## Limits

| Limit | Value | When you hit it |
| --- | --- | --- |
| set fields | 64 | Nest the extras in a `struct`, which counts as one field. |
| `vlq` `vli` ids and integers | exact to 2^53 | Past it, carry the value as a `str` or a `buffer`. |
| request timeout | 10 s | Pass a timeout per call. |
| in-flight requests | 32768 per namespace | You are leaking requests, and the cap is a detector. |
| state budget | 32 KB/s per client | Raise it with `flush(maxBytes)`, or split the traffic into its own namespace. |
| unreliable schema maximum | just under 1 KB | Drop `:unreliable()`, or narrow the codec until it fits. Checked at `start()`. |
| one frame | 1 MB | A loop that fires and never flushes. The throw names the namespace and the size it reached. |

---

## License

MIT
