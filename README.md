<h1 align="center">Lync</h1>
<p align="center">Buffer networking for Roblox.</p>
<p align="center">
  <a href="https://github.com/Axp3cter/Lync/releases/latest">Releases</a> ·
  <a href="#install">Install</a> ·
  <a href="#example">Example</a> ·
  <a href="#codecs">Codecs</a> ·
  <a href="#benchmarks">Benchmarks</a>
</p>

Lync batches all sends into a single buffer per player per frame, applies XOR compression across frames, validates and rate-limits every incoming payload, and does it all without code generation.

## Install

**Wally**

```toml
[dependencies]
Lync = "axp3cter/lync@2.1.0"
```

**npm (roblox-ts)**

```bash
npm install @axpecter/lync
```

```typescript
import Lync from "@axpecter/lync";
```

Or grab the `.rbxm` from [Releases](https://github.com/Axp3cter/Lync/releases/latest).

> [!IMPORTANT]
> Define all packets, queries, and groups before calling `Lync.start()`.

## Example

**Shared** (`ReplicatedStorage.Net`)

```luau
local Lync = require(game.ReplicatedStorage.Lync)

local Net = {}

Net.State = Lync.packet("State", Lync.deltaStruct({
    position = Lync.vec3,
    health   = Lync.float(0, 100, 0.5),
    shield   = Lync.float(0, 100, 0.5),
    status   = Lync.enum("idle", "moving", "attacking", "dead"),
    alive    = Lync.bool,
}))

Net.Hit = Lync.packet("Hit", Lync.struct({
    targetId = Lync.int(0, 65535),
    damage   = Lync.float(0, 200, 0.1),
    headshot = Lync.bool,
}), {
    rateLimit = { maxPerSecond = 30, burst = 5 },
    validate = function(data, player)
        if data.damage > 200 then return false, "damage" end
        return true
    end,
})

Net.Chat = Lync.packet("Chat", Lync.struct({
    msg     = Lync.string(200),
    channel = Lync.int(0, 255),
}))

Net.Ping = Lync.query("Ping", Lync.nothing, Lync.f64, { timeout = 3 })

return table.freeze(Net)
```

**Server**

```luau
local Lync    = require(game.ReplicatedStorage.Lync)
local Net     = require(game.ReplicatedStorage.Net)
local Players = game:GetService("Players")

local alive = Lync.group("alive")

Lync.onDrop(function(player, reason, name)
    warn(player.Name, "dropped", name, reason)
end)

Lync.start()

Players.PlayerAdded:Connect(function(player) alive:add(player) end)

game:GetService("RunService").Heartbeat:Connect(function()
    Net.State:send({
        position = Vector3.new(0, 5, 0),
        health   = 100,
        shield   = 50,
        status   = "idle",
        alive    = true,
    }, alive)
end)

Net.Hit:on(function(data, player)
    local target = Players:GetPlayerByUserId(data.targetId)
    if not target then return end
    alive:remove(target)
    Net.Chat:send({ msg = player.Name .. " eliminated " .. target.Name, channel = 0 }, Lync.all)
end)

Net.Ping:handle(function(_, player) return os.clock() end)
```

**Client**

```luau
local Lync = require(game.ReplicatedStorage.Lync)
local Net  = require(game.ReplicatedStorage.Net)

Lync.start()

local scope = Lync.scope()

scope:on(Net.State, function(state)
    local character = game.Players.LocalPlayer.Character
    if not character then return end
    character:PivotTo(CFrame.new(state.position))
end)

scope:on(Net.Chat, function(data) print("[chat]", data.msg) end)

Net.Hit:send({ targetId = 123, damage = 45.5, headshot = true })

local serverTime = Net.Ping:request(nil)
if serverTime then print("server clock:", serverTime) end
```

## Packets

`Lync.packet(name, codec, options?)`

### Options

| Field | Type | Default | Description |
|:------|:-----|:--------|:------------|
| `unreliable` | `boolean` | `false` | Send over `UnreliableRemoteEvent`. Cannot use with delta codecs. |
| `rateLimit` | `RateLimitConfig` | none | Server-side rate limiting. |
| `validate` | `(data, player) → (bool, string?)` | none | Server-side validation. Return `false, "reason"` to drop. |
| `maxPayloadBytes` | `number` | none | Max bytes per payload. |
| `timestamp` | `"frame"`, `"offset"`, or `"full"` | none | Appends a timestamp. `"frame"` = 1B counter. `"offset"` = 2B ms. `"full"` = 8B clock. Received as third argument. |

### Sending

```luau
-- Server
packet:send(data, player)
packet:send(data, Lync.all)
packet:send(data, Lync.except(p1, p2))
packet:send(data, { p1, p2, p3 })
packet:send(data, group)

-- Client
packet:send(data)
```

### Receiving

| Method | Description |
|:-------|:------------|
| `packet:on(fn)` | `fn(data, sender, timestamp?)`. Returns a Connection. |
| `packet:once(fn)` | Fires once, then disconnects. |
| `packet:wait()` | Yields until next fire. Returns `data, sender, timestamp?`. |

## Queries

`Lync.query(name, requestCodec, responseCodec, options?)`

Request-response built on packets. Returns `nil` on timeout.

### Options

| Field | Type | Default | Description |
|:------|:-----|:--------|:------------|
| `timeout` | `number` | 5 | Seconds before yielding `nil`. |
| `rateLimit` | `RateLimitConfig` | `{ maxPerSecond = 30 }` | Server-side rate limiting. |
| `validate` | `(data, player) → (bool, string?)` | none | Server-side validation. |

### Methods

| Method | Context | Description |
|:-------|:--------|:------------|
| `query:handle(fn)` | Both | Register handler. Server: `fn(request, player) → response`. Client: `fn(request) → response`. |
| `query:request(data)` | Client | Send to server, yield for response. |
| `query:request(data, player)` | Server | Send to one client. |
| `query:request(data, target)` | Server | Send to multiple. Returns `{ [Player]: response? }`. |

## Groups

`Lync.group(name)`

Named player sets. Members auto-removed on `PlayerRemoving`. Iterable with `for player in group do`.

| Method | Returns | Description |
|:-------|:--------|:------------|
| `group:add(player)` | `boolean` | `true` if added. |
| `group:remove(player)` | `boolean` | `true` if removed. |
| `group:has(player)` | `boolean` | Membership check. |
| `group:count()` | `number` | Member count. |
| `group:destroy()` | — | Clears members, frees name. |

## Scope

`Lync.scope()`

Batches connections for cleanup.

```luau
local scope = Lync.scope()
scope:on(packetA, fnA)
scope:on(packetB, fnB)
scope:add(someRBXScriptConnection)
scope:destroy()  -- disconnects everything
```

| Method | Description |
|:-------|:------------|
| `scope:on(source, fn)` | Connect and track. |
| `scope:once(source, fn)` | Connect once and track. |
| `scope:add(connection)` | Track an existing connection. |
| `scope:destroy()` | Disconnect all. Safe to call multiple times. |

## Connection

Returned by `packet:on()`, `packet:once()`, `query:handle()`, and middleware functions.

| Field / Method | Description |
|:---------------|:------------|
| `connection.connected` | `boolean` |
| `connection:disconnect()` | Stops the listener. Safe mid-fire, safe to call multiple times. |

## Middleware

```luau
Lync.onSend(function(data, name, player)
    return data  -- or return Lync.DROP to discard
end)

Lync.onReceive(function(data, name, player)
    return data
end)

Lync.onDrop(function(player, reason, name, data)
    warn(player.Name, "dropped", name, reason)
end)
```

All three return a Connection.

## Targets

Server-side second argument to `packet:send()`.

| Target | Description |
|:-------|:------------|
| `player` | Single player. |
| `Lync.all` | All connected players. |
| `Lync.except(...)` | Everyone except specified players or groups. |
| `{ p1, p2, ... }` | Array of players. |
| `group` | All members of a group. |

## Codecs

### Numbers

`Lync.int(min, max)` picks the smallest wire type for your range.

| Codec | Bytes | Description |
|:------|------:|:------------|
| `Lync.int(0, 255)` | 1 | u8 |
| `Lync.int(0, 65535)` | 2 | u16 |
| `Lync.int(0, 4294967295)` | 4 | u32 |
| `Lync.int(-128, 127)` | 1 | i8 |
| `Lync.int(-32768, 32767)` | 2 | i16 |
| `Lync.int(-2147483648, 2147483647)` | 4 | i32 |
| `Lync.f16` | 2 | Half-precision float. ~3 digits. ±65504. |
| `Lync.f32` | 4 | Single-precision float. |
| `Lync.f64` | 8 | Double-precision float. |
| `Lync.bool` | 1 | Bitpacked inside structs and arrays (8 per byte). |
| `Lync.float(min, max, precision)` | 1–4 | Quantized float. Clamped to range. |

### Strings & Buffers

| Codec | Description |
|:------|:------------|
| `Lync.string` | Variable length. Binary-safe. |
| `Lync.string(maxLength)` | Same, but rejects on read if length exceeds `maxLength`. |
| `Lync.buff` | Variable-length buffer. |

### Roblox Types

| Codec | Bytes |
|:------|------:|
| `Lync.vec2` | 8 |
| `Lync.vec3` | 12 |
| `Lync.cframe` | 24 |
| `Lync.color3` | 3 |
| `Lync.inst` | 2 |
| `Lync.udim` | 8 |
| `Lync.udim2` | 16 |
| `Lync.numberRange` | 8 |
| `Lync.rect` | 16 |
| `Lync.ray` | 24 |
| `Lync.vec2int16` | 4 |
| `Lync.vec3int16` | 6 |
| `Lync.region3` | 24 |
| `Lync.region3int16` | 12 |
| `Lync.numberSequence` | variable |
| `Lync.colorSequence` | variable |

### Quantized Variants

Call the codec to get a quantized version.

| Codec | Bytes | Description |
|:------|------:|:------------|
| `Lync.vec2(min, max, precision)` | 2–8 | Per-component quantization. |
| `Lync.vec3(min, max, precision)` | 3–12 | Per-component quantization. |
| `Lync.cframe()` | 16 | Compressed rotation. ≤0.16° angular error. Saves 8B vs lossless. |

### Composites

| Codec | Description |
|:------|:------------|
| `Lync.struct({ key = codec })` | Named fields. Bools are automatically bitpacked. |
| `Lync.array(codec, maxCount?)` | Variable-length list. Bool arrays are bitpacked. |
| `Lync.map(keyCodec, valueCodec, maxCount?)` | Key-value pairs. |
| `Lync.optional(codec)` | 1-byte nil flag + value if present. |
| `Lync.tuple(...)` | Ordered positional values. |
| `Lync.tagged(tagField, { name = codec })` | Discriminated union with 1-byte tag. |

### Delta

Only works with reliable transport. Sends 1 byte when data hasn't changed.

| Codec | Description |
|:------|:------------|
| `Lync.deltaStruct(schema)` | Delta-compressed struct. |
| `Lync.deltaArray(codec, maxCount?)` | Delta-compressed array. |
| `Lync.deltaMap(keyCodec, valueCodec, maxCount?)` | Delta-compressed map. |

### Meta

| Codec | Description |
|:------|:------------|
| `Lync.enum(...)` | String enum. Up to 256 variants. 1 byte. |
| `Lync.bitfield(schema)` | Sub-byte packing. 1–32 bits. |
| `Lync.custom(size, write, read)` | User-defined fixed-size codec. |
| `Lync.nothing` | Zero bytes. Reads `nil`. |
| `Lync.unknown` | Bypasses serialization entirely. Use with `validate`. |
| `Lync.auto` | Self-describing. Supports nil, bool, numbers, strings, buffers, and Roblox types. |

## Rate Limiting

Two modes (pick one per packet):

**Token bucket:** `{ maxPerSecond = N, burst = M }`

**Cooldown:** `{ cooldown = seconds }`

Global limit across all packets: `Lync.configure({ globalRateLimit = { maxPerSecond = N } })`

## Configuration

`Lync.configure(options)` — call before `Lync.start()`.

| Option | Default | Description |
|:-------|--------:|:------------|
| `channelMaxSize` | 262,144 | Max buffer bytes per frame (4,096–1,048,576). |
| `bandwidthLimit` | none | `{ softLimit, maxStrikes }`. Per-player bandwidth throttle. |
| `globalRateLimit` | none | `{ maxPerSecond }`. Global per-player rate limit. |
| `stats` | `false` | Enables `packet:stats()` and `Lync.stats.player()`. |

### Lifecycle

| Function | Description |
|:---------|:------------|
| `Lync.configure(options)` | Set options before start. |
| `Lync.start()` | Initialize transport. Call once after all definitions. |
| `Lync.flush()` | Force an immediate send. |
| `Lync.flushRate(hz)` | Set flush rate. 1–60. Default 60. |

### Stats

Enable with `Lync.configure({ stats = true })`.

| Function | Description |
|:---------|:------------|
| `packet:stats()` | `{ bytesSent, bytesReceived, fires, recvFires, drops }` |
| `Lync.stats.player(player)` | `{ bytesSent, bytesReceived }` — server only. |
| `Lync.stats.reset()` | Zeros all counters. |

## Limits

| Constraint | Limit |
|:-----------|------:|
| Packet + query registrations | 127 |
| Buffer per frame | 256 KB default, 1 MB max |
| Concurrent query requests | 65,536 |
| Enum variants | 256 |
| Bitfield bits | 32 |
| Tagged variants | 256 |

## Benchmarks

Run `rojo serve bench.project.json` with one server + one client.

### Wire Sizes

| Codec | Bytes |
|:------|------:|
| `bool` | 1 |
| `int(0, 255)` | 1 |
| `int(0, 65535)` | 2 |
| `f16` | 2 |
| `f32` | 4 |
| `f64` | 8 |
| `string` (5 chars) | 6 |
| `string` (1000 chars) | 1002 |
| `vec3` | 12 |
| `vec3(0, 100, 1)` | 3 |
| `cframe` | 24 |
| `cframe()` | 16 |
| `color3` | 3 |
| entity struct (6 fields) | 34 |
| entity compact (quantized) | 13 |
| bitfield | 2 |
| 100× entities | 601 |
| 1000× bools (bitpacked) | 127 |

### Codec Throughput

100k iterations, isolated CPU. No networking.

| Codec | Encode | Decode | Round-trips/sec |
|:------|-------:|-------:|----------------:|
| `bool` | 44ns | 29ns | 13.9M |
| `int(0, 255)` | 42ns | 28ns | 14.4M |
| `f32` | 41ns | 25ns | 15.0M |
| `f64` | 41ns | 26ns | 14.8M |
| `string` (10 chars) | 46ns | 60ns | 9.4M |
| `string` (1000 chars) | 76ns | 238ns | 3.2M |
| `vec3` | 53ns | 27ns | 12.4M |
| `cframe` | 92ns | 144ns | 4.2M |
| `cframe()` | 123ns | 170ns | 3.4M |
| entity struct | 239ns | 395ns | 1.6M |
| 100× entities | 15.2µs | 34.1µs | 20K |
| 1000× bools | 4.3µs | 5.1µs | 107K |

### Delta Savings

| Codec | Full | Unchanged | Savings |
|:------|-----:|----------:|--------:|
| `deltaStruct` (entity) | 35B | 1B | 97% |
| `deltaStruct` (compact) | 14B | 1B | 93% |
| `deltaArray` (100× entity) | 602B | 1B | 100% |
| `deltaArray` (1000× bool) | 128B | 1B | 99% |
| `deltaMap` (string → u8) | 19B | 1B | 95% |

### Network Throughput

1000 fires/frame, 8 seconds, one player.

| Packet | FPS | Kbps |
|:-------|----:|-----:|
| booleans | 60 | 2.5 |
| entity struct | 60 | 2.3 |
| entity compact | 60 | 2.4 |
| bitfield flags | 60 | 2.4 |
| cframe lossless | 60 | 2.5 |
| cframe compressed | 60 | 2.3 |

### Cross-Library Comparison

Same methodology as [Blink's benchmarks](https://github.com/1Axen/blink/blob/main/benchmark/Benchmarks.md): 1,000 fires/frame, same data every frame, 10 seconds.

Other tool numbers from [Blink v0.17.1](https://github.com/1Axen/blink/blob/main/benchmark/Benchmarks.md) (2025-04-30).

> [!NOTE]
> Lync batches all sends into one buffer per frame. Other tools fire one RemoteEvent per send. Lync also includes server-side validation and bool bitpacking (1000 bools = 127B vs ~1002B). Delta compression is not exercised here — see [Delta Savings](#delta-savings).

#### Entities — 100× struct(6× u8)

| Tool | FPS | Kbps |
|:-----|----:|-----:|
| roblox | 16 | 559,364 |
| **lync** | **60** | **3.68** |
| blink | 42 | 41.81 |
| zap | 39 | 41.71 |
| bytenet | 32 | 41.64 |

#### Booleans — 1000× bool

| Tool | FPS | Kbps |
|:-----|----:|-----:|
| roblox | 21 | 353,107 |
| **lync** | **60** | **2.49** |
| blink | 97 | 7.91 |
| zap | 52 | 8.10 |
| bytenet | 35 | 8.11 |

## License

MIT
