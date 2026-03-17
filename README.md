<h1 align="center">Lync</h1>
<p align="center">Buffer networking for Roblox. Delta compression, XOR framing, built-in security.</p>
<p align="center">
  <a href="https://github.com/Axp3cter/Lync/releases/latest">Releases</a> ·
  <a href="#example">Example</a> ·
  <a href="#benchmarks">Benchmarks</a> ·
  <a href="#limits--configuration">Limits</a>
</p>

## Install

**Wally (Luau)**

```toml
[dependencies]
Lync = "axp3cter/lync@1.4.3"
```

**npm (roblox-ts)**

```bash
npm install @axpecter/lync
```

```typescript
import Lync from "@axpecter/lync";
```

Or grab the `.rbxm` from [releases](https://github.com/Axp3cter/Lync/releases/latest) and drop it in `ReplicatedStorage`.

> [!IMPORTANT]
> Define everything before calling `Lync.start()`. Packets, queries, namespaces, all of it.

## Example

**Shared**

```luau
local Lync = require(game.ReplicatedStorage.Lync)

local Net = {}

Net.State = Lync.definePacket("State", {
    value = Lync.deltaStruct({
        position = Lync.vec3,
        health   = Lync.quantizedFloat(0, 100, 0.5),
        shield   = Lync.quantizedFloat(0, 100, 0.5),
        status   = Lync.enum("idle", "moving", "attacking", "dead"),
        alive    = Lync.bool,
    }),
})

Net.Hit = Lync.definePacket("Hit", {
    value = Lync.struct({
        targetId = Lync.u16,
        damage   = Lync.quantizedFloat(0, 200, 0.1),
        headshot = Lync.bool,
    }),
    rateLimit = { maxPerSecond = 30, burstAllowance = 5 },
    validate = function(data, player)
        if data.damage > 200 then return false, "damage" end
        return true
    end,
})

Net.Chat = Lync.definePacket("Chat", {
    value = Lync.struct({ msg = Lync.boundedString(200), channel = Lync.u8 }),
})

Net.Ping = Lync.defineQuery("Ping", {
    request  = Lync.nothing,
    response = Lync.f64,
    timeout  = 3,
})

return table.freeze(Net)
```

**Server**

```luau
local Lync    = require(game.ReplicatedStorage.Lync)
local Net     = require(game.ReplicatedStorage.Net)
local Players = game:GetService("Players")

local alive = Lync.createGroup("alive")

Lync.onSend(function(data, name)
    print("[out]", name)
    return data
end)

Lync.onDrop(function(player, reason, name)
    warn(player.Name, "dropped", name, reason)
end)

Lync.start()

Players.PlayerAdded:Connect(function(player)
    alive:add(player)
end)

game:GetService("RunService").Heartbeat:Connect(function()
    Net.State:send({
        position = Vector3.new(0, 5, 0),
        health   = 100,
        shield   = 50,
        status   = "idle",
        alive    = true,
    }, alive)
end)

Net.Hit:listen(function(data, player)
    local target = Players:GetPlayerByUserId(data.targetId)
    if not target then return end

    alive:remove(target)
    Net.Chat:send({ msg = player.Name .. " eliminated " .. target.Name, channel = 0 }, Lync.all)
    Net.State:send({
        position = Vector3.zero,
        health   = 0,
        shield   = 0,
        status   = "dead",
        alive    = false,
    }, Lync.except(target))
end)

Net.Ping:listen(function()
    return os.clock()
end)
```

**Client**

```luau
local Lync = require(game.ReplicatedStorage.Lync)
local Net  = require(game.ReplicatedStorage.Net)

Lync.start()

local scope = Lync.scope()

scope:listen(Net.State, function(state)
    local character = game.Players.LocalPlayer.Character
    if not character then return end
    character:PivotTo(CFrame.new(state.position))
end)

scope:listen(Net.Chat, function(data)
    print("[chat]", data.msg)
end)

Net.Hit:send({ targetId = 123, damage = 45.5, headshot = true })

local serverTime = Net.Ping:request(nil)
if serverTime then
    print("server clock:", serverTime)
end
```

## Lifecycle

| | What it does |
|:---------|:------------|
| `Lync.start()` | Sets up transport. Server creates remotes, client connects. Call once after all definitions. |
| `Lync.VERSION` | `"1.4.3"` |

## Packets

`Lync.definePacket(name, config)` returns a Packet.

| Config | Type | Required | What it does |
|:-------|:-----|:--------:|:-------------|
| `value` | Codec | Yes | How to serialize the payload. |
| `unreliable` | boolean | No | Sends over UnreliableRemoteEvent. Default `false`. Cant use with delta codecs. |
| `rateLimit` | `{ maxPerSecond, burstAllowance? }` | No | Server-side token bucket. Burst defaults to maxPerSecond if you dont set it. |
| `validate` | `(data, player) → (bool, string?)` | No | Server-side. Return `false, "reason"` to drop. Runs after NaN scan. |
| `maxPayloadBytes` | number | No | Server-side. Max bytes a single batch of this packet can consume. Fires `onDrop` with reason `"size"` if exceeded. |

**Server, single `send` with targets:**

```luau
packet:send(data, player)              -- one player
packet:send(data, Lync.all)            -- everyone
packet:send(data, Lync.except(player)) -- everyone except one
packet:send(data, Lync.except(p1, p2)) -- everyone except multiple
packet:send(data, { p1, p2 })          -- list of players
packet:send(data, group)               -- group object
```

**Client:**

```luau
packet:send(data)  -- send to server
```

**Shared (both contexts):**

| Method | What it does |
|:-------|:------------|
| `packet:listen(fn(data, sender))` | Sender is `Player` on server, `nil` on client. Returns a Connection. |
| `packet:once(fn(data, sender))` | Auto-disconnects after one fire. |
| `packet:wait()` | Returns `(data, sender)`. |
| `packet:disconnectAll()` | Kills all listeners on this packet. |

## Queries

`Lync.defineQuery(name, config)` returns a Query. Basically RemoteFunctions but built on RemoteEvents. Returns `nil` if the other side times out or errors.

| Config | Type | Required | What it does |
|:-------|:-----|:--------:|:-------------|
| `request` | Codec | Yes | How to serialize the request. |
| `response` | Codec | Yes | How to serialize the response. |
| `timeout` | number | No | Seconds before giving up. Default `5`. |
| `rateLimit` | `{ maxPerSecond, burstAllowance? }` | No | Server-side token bucket on incoming requests. |
| `validate` | `(data, player) → (bool, string?)` | No | Server-side validation on incoming requests. |

| Method | Where | What it does |
|:-------|:------|:-------------|
| `query:listen(fn)` | Both | Register a handler. Server gets `fn(request, player) → response`. Client gets `fn(request) → response`. |
| `query:request(data)` | Client | Send request to server, yield until response or timeout. |
| `query:requestFrom(player, data)` | Server | Send request to a specific client, yield until response or timeout. |
| `query:requestAll(data)` | Server | Send request to all players. Returns `{ [Player]: response? }`. |
| `query:requestList(players, data)` | Server | Send request to a list of players. Returns `{ [Player]: response? }`. |
| `query:requestGroup(group, data)` | Server | Send request to all players in a group. Returns `{ [Player]: response? }`. |

## Namespaces

`Lync.defineNamespace(name, config)` returns a Namespace. Takes a `packets` table and/or a `queries` table. All names get auto-prefixed with `"YourNamespace."` so nothing collides.

Access packets and queries by their short name on the returned object: `ns.PacketName`, `ns.QueryName`. Or use the typed sub-tables: `ns.packets.PacketName`, `ns.queries.QueryName`.

| Method | What it does |
|:-------|:------------|
| `ns:listenAll(fn(name, data, sender))` | Listens to every packet in the namespace. `name` is the short name without prefix. Returns a Connection. |
| `ns:onSend(fn(data, name, player) → data?)` | Send middleware that only runs for this namespace. Returns a remover. |
| `ns:onReceive(fn(data, name, player) → data?)` | Receive middleware that only runs for this namespace. Returns a remover. |
| `ns:disconnectAll()` | Kills all listeners made through `listenAll`. |
| `ns:destroy()` | Kills listeners and removes scoped middleware. Full cleanup. |
| `ns:packetNames()` | Sorted list of packet short names. |
| `ns:queryNames()` | Sorted list of query short names. |
| `ns.packets` | Frozen table mapping short name → Packet object. |
| `ns.queries` | Frozen table mapping short name → Query object. |

## Connection

Returned by `packet:listen()`, `packet:once()`, `query:listen()`, and `ns:listenAll()`.

| | What it does |
|:-------|:------------|
| `connection.connected` | `boolean` |
| `connection:disconnect()` | Stops the listener. |

## Scope

Batches connections for lifecycle-aligned cleanup.

```luau
local scope = Lync.scope()

scope:listen(packetA, fnA)
scope:listen(packetB, fnB)
scope:listenAll(namespace, fnC)

scope:destroy()  -- disconnects everything
```

| Method | What it does |
|:-------|:------------|
| `scope:listen(source, fn)` | Calls `source:listen(fn)` and tracks the connection. |
| `scope:once(source, fn)` | Calls `source:once(fn)` and tracks the connection. |
| `scope:listenAll(namespace, fn)` | Calls `namespace:listenAll(fn)` and tracks the connection. |
| `scope:add(connection)` | Also accepts RBXScriptConnection. |
| `scope:destroy()` | Safe to call multiple times. |

## Groups

Named player sets. Members get removed automatically on `PlayerRemoving`. `Lync.createGroup(name)` returns a Group object.

```luau
local vips = Lync.createGroup("vips")

vips:add(player)
vips:remove(player)
vips:has(player)

packet:send(data, vips)
```

| Method | Returns | What it does |
|:-------|:--------|:-------------|
| `group:add(player)` | `boolean` | `true` if added, `false` if already in. |
| `group:remove(player)` | `boolean` | `true` if removed, `false` if wasnt in there. |
| `group:has(player)` | `boolean` | Whether the player is in the group. |
| `group:count()` | `number` | Number of members. |
| `group:getSet()` | `{ [Player]: true }` | Snapshot of the internal set. |
| `group:forEach(fn)` | `()` | Calls `fn(player)` for each member. |
| `group:destroy()` | `()` | Removes the group and all memberships. |

## Middleware

Global intercept on all packets. Handlers run in the order you registered them. Return `Lync.DROP` from a handler to drop the packet. Return the data to pass it through.

```luau
Lync.onSend(function(data, name, player)
    if shouldDrop(data) then
        return Lync.DROP
    end
    data.timestamp = os.clock()
    return data
end)
```

| Function | What it does |
|:---------|:------------|
| `Lync.onSend(fn(data, name, player) → data \| Lync.DROP)` | Runs before a packet goes out. Returns a remover function. |
| `Lync.onReceive(fn(data, name, player) → data \| Lync.DROP)` | Runs when a packet comes in. Returns a remover function. |
| `Lync.onDrop(fn(player, reason, name, data))` | Fires when a packet gets rejected. Returns a remover function. Supports multiple handlers. Reason is `"nan"`, `"rate"`, `"validate"`, `"size"`, or whatever string your validate function returned. |
| `Lync.DROP` | Frozen sentinel. Return from middleware to drop the packet. |

Packets that fail validation are dropped individually. Other packets in the same frame from the same player are unaffected.

## Target Descriptors

Used as the second argument to `packet:send()` on the server.

| Target | What it does |
|:-------|:------------|
| `player` | Send to one player. |
| `Lync.all` | Send to all connected players. |
| `Lync.except(player, ...)` | Send to everyone except the specified players. |
| `{ p1, p2, ... }` | Send to a list of players. |
| `group` | Send to all members of a Group object. |

## Types

### Primitives

| Type | Bytes | Range |
|:-----|------:|:------|
| `Lync.u8` | 1 | 0 to 255 |
| `Lync.u16` | 2 | 0 to 65,535 |
| `Lync.u32` | 4 | 0 to 4,294,967,295 |
| `Lync.i8` | 1 | -128 to 127 |
| `Lync.i16` | 2 | -32,768 to 32,767 |
| `Lync.i32` | 4 | -2,147,483,648 to 2,147,483,647 |
| `Lync.f16` | 2 | ±65,504, roughly 3 digits of precision |
| `Lync.f32` | 4 | IEEE 754 single |
| `Lync.f64` | 8 | IEEE 754 double |
| `Lync.bool` | 1 | true/false. Gets packed into bitfields when inside structs. |

### Datatypes

| Type | Bytes | What it is |
|:-----|------:|:-----------|
| `Lync.string` | varint + N | Varint length prefix then raw bytes. |
| `Lync.vec2` | 8 | 2x f32. |
| `Lync.vec3` | 12 | 3x f32. |
| `Lync.cframe` | 24 | Position as 3x f32, rotation as axis-angle 3x f32. |
| `Lync.color3` | 3 | RGB 0-255 per channel, clamped. |
| `Lync.inst` | 2 | Instance ref through sidecar array. Requires refs on read, throws without them. |
| `Lync.buff` | varint + N | Varint length prefix then raw bytes. |
| `Lync.udim` | 8 | Scale f32 + Offset i32. |
| `Lync.udim2` | 16 | 2x UDim (X then Y). |
| `Lync.numberRange` | 8 | Min f32 + Max f32. |
| `Lync.rect` | 16 | Min.X f32 + Min.Y f32 + Max.X f32 + Max.Y f32. |
| `Lync.vec2int16` | 4 | 2x i16. |
| `Lync.vec3int16` | 6 | 3x i16. |
| `Lync.region3` | 24 | Min Vec3 + Max Vec3 as 6x f32. |
| `Lync.region3int16` | 12 | Min Vec3int16 + Max Vec3int16 as 6x i16. |
| `Lync.ray` | 24 | Origin Vec3 + Direction Vec3 as 6x f32. |
| `Lync.numberSequence` | varint + N×12 | Varint count then (time f32 + value f32 + envelope f32) per keypoint. |
| `Lync.colorSequence` | varint + N×7 | Varint count then (time f32 + R u8 + G u8 + B u8) per keypoint. |
| `Lync.boundedString(maxLength)` | varint + N | Same wire format as `Lync.string` but rejects on read if length exceeds `maxLength`. |

### Composites

| Constructor | What it does |
|:------------|:------------|
| `Lync.struct({ key = codec })` | Named fields. Bools get packed into bitfields automatically. |
| `Lync.array(codec, maxCount?)` | Variable length list with varint count. Optional `maxCount` rejects on read if exceeded. |
| `Lync.map(keyCodec, valueCodec, maxCount?)` | Key-value pairs with varint count. Optional `maxCount` rejects on read if exceeded. |
| `Lync.optional(codec)` | 1 byte flag, value only if present. |
| `Lync.tuple(codec, codec, ...)` | Ordered positional values, no keys. |
| `Lync.tagged(tagField, { name = codec })` | Discriminated union with a u8 variant tag. Puts `tagField` into the decoded table so you know which variant it is. |

### Delta

Reliable only. Lync will error if you try to use these with `unreliable = true`.

| Constructor | What it does |
|:------------|:------------|
| `Lync.deltaStruct({ key = codec })` | First frame sends everything. After that only dirty fields get sent via bitmask. If nothing changed it costs 1 byte. |
| `Lync.deltaArray(codec, maxCount?)` | Same idea but for arrays. Dirty elements get sent with varint indices. Optional `maxCount` rejects on read if exceeded. |
| `Lync.deltaMap(keyCodec, valueCodec, maxCount?)` | Delta compression for key-value maps. Sends only upserted and removed entries after the first frame. Optional `maxCount` rejects on read if exceeded. |

### Meta

| Constructor | What it does |
|:------------|:------------|
| `Lync.enum(value, value, ...)` | u8 index, up to 256 variants. |
| `Lync.quantizedFloat(min, max, precision)` | Fixed-point compression. Picks u8/u16/u32 based on your range and precision. |
| `Lync.quantizedVec3(min, max, precision)` | Same thing but for all 3 components. |
| `Lync.bitfield({ key = spec })` | Sub-byte packing, 1 to 32 bits total. Spec is `{ type = "bool" }` or `{ type = "uint", width = N }` or `{ type = "int", width = N }`. |
| `Lync.custom(size, write, read)` | User-defined fixed-size codec. `write` is `(b, offset, value) → ()`, `read` is `(b, offset) → value`. Plugs into struct/array/delta specialization automatically. |
| `Lync.nothing` | Zero bytes. Reads nil. Good for fire-and-forget signals. |
| `Lync.unknown` | Skips serialization entirely, goes through Roblox's sidecar. Requires refs array on read (same as `Lync.inst`). Use when you dont have a codec for the value. |
| `Lync.auto` | Self-describing. Writes a u8 type tag then the value. Handles nil, bool, all number types, string, vec2, vec3, color3, cframe, buffer, udim, udim2, numberRange, rect, vec2int16, vec3int16, region3, region3int16, ray, numberSequence, colorSequence. |

## Benchmarks

### Lync Tests

1,000 packets/frame, 10 seconds, one player.

| Scenario | Without Lync | With Lync | FPS |
|:---------|------------:|---------:|----:|
| Static booleans (1B) | 480 Kbps | **2.34 Kbps** | 60.00 |
| Static entities (34B) | 16,320 Kbps | **2.62 Kbps** | 60.00 |
| Moving entities | 16,320 Kbps | **3.14 Kbps** | 60.00 |
| Chaotic entities | 16,320 Kbps | **4.76 Kbps** | 59.99 |

### Cross-Library Comparison

Same data shapes and methodology as [Blink's benchmark suite](https://github.com/1Axen/blink/blob/main/benchmark/Benchmarks.md). 1,000 fires/frame, 10 seconds, same data every frame. Kbps scaled by 60/FPS.

**Entities** (100x struct of 6x u8, fired 1000 times/frame)

| Tool (FPS) | Median | P0 | P80 | P90 | P95 | P100 |
|:-----------|-------:|---:|----:|----:|----:|-----:|
| roblox | 16.00 | 16.00 | 15.00 | 15.00 | 15.00 | 15.00 |
| **lync** | **60.00** | 61.00 | 60.00 | 60.00 | 60.00 | 59.00 |
| blink | 42.00 | 45.00 | 42.00 | 42.00 | 42.00 | 42.00 |
| zap | 39.00 | 40.00 | 38.00 | 38.00 | 38.00 | 38.00 |
| bytenet | 32.00 | 34.00 | 32.00 | 32.00 | 32.00 | 31.00 |

| Tool (Kbps) | Median | P0 | P80 | P90 | P95 | P100 |
|:------------|-------:|---:|----:|----:|----:|-----:|
| roblox | 559,364 | 559,364 | 676,715 | 676,715 | 676,715 | 784,081 |
| **lync** | **3.61** | 3.53 | 3.63 | 3.64 | 3.64 | 4.64 |
| blink | 41.81 | 26.30 | 42.40 | 42.48 | 42.48 | 42.62 |
| zap | 41.71 | 25.46 | 42.19 | 42.32 | 42.32 | 42.93 |
| bytenet | 41.64 | 22.84 | 42.36 | 42.82 | 42.82 | 43.24 |

**Booleans** (1000x bool, fired 1000 times/frame)

| Tool (FPS) | Median | P0 | P80 | P90 | P95 | P100 |
|:-----------|-------:|---:|----:|----:|----:|-----:|
| roblox | 21.00 | 22.00 | 20.00 | 19.00 | 19.00 | 19.00 |
| **lync** | **60.00** | 61.00 | 60.00 | 60.00 | 60.00 | 59.00 |
| blink | 97.00 | 98.00 | 97.00 | 96.00 | 96.00 | 96.00 |
| zap | 52.00 | 53.00 | 51.00 | 51.00 | 51.00 | 49.00 |
| bytenet | 35.00 | 37.00 | 35.00 | 35.00 | 35.00 | 34.00 |

| Tool (Kbps) | Median | P0 | P80 | P90 | P95 | P100 |
|:------------|-------:|---:|----:|----:|----:|-----:|
| roblox | 353,107 | 196,826 | 690,747 | 842,240 | 842,240 | 1,124,176 |
| **lync** | **4.31** | 3.85 | 4.36 | 4.38 | 4.38 | 4.44 |
| blink | 7.91 | 7.41 | 7.93 | 7.99 | 7.99 | 8.00 |
| zap | 8.10 | 5.75 | 8.17 | 8.22 | 8.22 | 8.27 |
| bytenet | 8.11 | 5.07 | 8.35 | 8.46 | 8.46 | 8.47 |

> [!NOTE]
> Lync benchmarks run on Ryzen 7 7800X3D, 32GB DDR5-4800. Other tool numbers are from [Blink's published benchmarks](https://github.com/1Axen/blink/blob/main/benchmark/Benchmarks.md) (v0.17.1, Ryzen 9 7900X, 34GB DDR5-4800). Different CPUs so FPS numbers arent directly comparable but bandwidth numbers are since Kbps is scaled by 60/FPS. Lync hits the 60 FPS frame cap in both tests.

## Limits & Configuration

Call these before `Lync.start()`.

| What | Default | How to change | Notes |
|:-----|--------:|:--------------|:------|
| Packet types | 255 | Cant change | u8 on the wire. Each query eats 2 IDs. |
| Buffer per channel per frame | 256 KB | `Lync.setChannelMaxSize(n)` | 4 KB to 1 MB. |
| Concurrent queries | 65,536 | Cant change | u16 correlation IDs. Freed on response or timeout. `Lync.queryPendingCount()` returns in-flight count. |
| NaN/inf scan depth | 16 | `Lync.setValidationDepth(n)` | 4 to 32. |
| Channel pool | 16 | `Lync.setPoolSize(n)` | 2 to 128. Extra gets GCd. |
| Namespaces | 64 | Cant change | |
| Delta + unreliable | Nope | Cant change | Errors at define time. |

## License

MIT
