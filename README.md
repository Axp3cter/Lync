<h1 align="center">Lync</h1>
<p align="center">Buffer networking for Roblox.</p>
<p align="center">
  <a href="https://github.com/Axp3cter/Lync/releases/latest">Releases</a> ·
  <a href="#install">Install</a> ·
  <a href="#example">Example</a> ·
  <a href="#api">API</a> ·
  <a href="#codecs">Codecs</a> ·
  <a href="#benchmarks">Benchmarks</a>
</p>

Packets, queries, groups, validation, and rate limiting — all batched into one buffer per player per frame. No code generation.

## Install

**Wally**

```toml
[dependencies]
Lync = "axp3cter/lync@2.2.0"
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

**Shared** — `ReplicatedStorage.Net`

```luau
local Lync = require(game.ReplicatedStorage.Lync)

return table.freeze({
    State = Lync.packet("State", Lync.deltaStruct({
        position = Lync.vec3,
        health   = Lync.float(0, 100, 0.5),
        status   = Lync.enum("idle", "moving", "attacking", "dead"),
        alive    = Lync.bool,
    })),

    Hit = Lync.packet("Hit", Lync.struct({
        targetId = Lync.int(0, 65535),
        damage   = Lync.float(0, 200, 0.1),
    }), {
        rateLimit = { maxPerSecond = 30, burst = 5 },
        validate  = function(data) return data.damage <= 200, "damage" end,
    }),

    Ping = Lync.query("Ping", Lync.nothing, Lync.f64, { timeout = 3 }),
})
```

**Server**

```luau
local Lync    = require(game.ReplicatedStorage.Lync)
local Net     = require(game.ReplicatedStorage.Net)
local Players = game:GetService("Players")

local alive = Lync.group("alive")
Players.PlayerAdded:Connect(function(p) alive:add(p) end)

Net.Hit:on(function(data, sender) -- ... end)
Net.Ping:handle(function() return os.clock() end)

Lync.start()

game:GetService("RunService").Heartbeat:Connect(function()
    Net.State:send(getState(), alive)
end)
```

**Client**

```luau
local Lync = require(game.ReplicatedStorage.Lync)
local Net  = require(game.ReplicatedStorage.Net)

Lync.start()

local scope = Lync.scope()
scope:on(Net.State, function(state) -- ... end)

Net.Hit:send({ targetId = 123, damage = 45 })
local serverTime = Net.Ping:request(nil)
```

## API

### Lifecycle

| Function | Description |
|:---|:---|
| `Lync.configure(opts)` | Set options. Must precede `start()`. |
| `Lync.start()` | Initialize transport. Call once. |
| `Lync.isStarted()` | `true` after `start()`. |
| `Lync.flush()` | Force an immediate send. |
| `Lync.flushRate(hz)` | 1–60. Default 60. |

### Configure options

| Option | Default | Range | Description |
|:---|---:|:---|:---|
| `channelMaxSize` | 262144 | 4 KB – 1 MB | Max buffer bytes per frame. |
| `validationDepth` | 16 | 4–32 | Max recursion depth for input validation. |
| `poolSize` | 16 | 2–128 | Reusable channel-state pool. |
| `bandwidthLimit` | none | — | `{ softLimit, maxStrikes }` per-player throttle. |
| `globalRateLimit` | none | — | `{ maxPerSecond }` across all packets per player. |
| `stats` | `false` | — | Enables `:stats()` and `Lync.stats.player()`. |

### Packets

`Lync.packet(name, codec, options?)`

```luau
-- Server
packet:send(data, player)
packet:send(data, Lync.all)
packet:send(data, Lync.except(p1, p2))
packet:send(data, { p1, p2, p3 })
packet:send(data, group)

-- Client
packet:send(data)

-- Both
packet:on(function(data, sender, timestamp?) end)  -- returns Connection
packet:once(fn)
packet:wait()                                       -- yields, returns data, sender, timestamp?
packet:name()
packet:stats()                                      -- requires stats=true
```

| Option | Type | Description |
|:---|:---|:---|
| `unreliable` | boolean | Use `UnreliableRemoteEvent`. Disallowed with delta codecs. |
| `rateLimit` | `RateLimitConfig` | Server-side per-player limit. |
| `validate` | `(data, player) → (bool, string?)` | Drop on `false`. |
| `maxPayloadBytes` | number | Reject oversize incoming payloads. |
| `timestamp` | `"frame"` / `"offset"` / `"full"` | Append 1B / 2B / 8B timestamp. Read as third arg. |

### Queries

`Lync.query(name, requestCodec, responseCodec, options?)`

Request-response on top of two packet IDs.

```luau
-- Server
query:handle(function(data, player) return response end)
query:request(data, player)             -- → response?
query:request(data, target)             -- → { [Player]: response? }

-- Client
query:handle(function(data) return response end)
query:request(data)                     -- yields, → response? (nil on timeout)
```

| Option | Default | Description |
|:---|:---|:---|
| `timeout` | 5 | Seconds before yielding `nil`. |
| `rateLimit` | `{ maxPerSecond = 30 }` | Server-side. |
| `validate` | none | `(data, player) → (bool, string?)` |

### Groups

`Lync.group(name)` — named player set. Members auto-removed on `PlayerRemoving`. Iterable: `for player in group do`.

| Method | Returns | Description |
|:---|:---|:---|
| `group:add(p)` / `:remove(p)` | boolean | `true` if changed. |
| `group:has(p)` | boolean | Membership. |
| `group:count()` | number | |
| `group:destroy()` | — | Clear and free name. |

### Scope

`Lync.scope()` — batches connections for cleanup.

```luau
local scope = Lync.scope()
scope:on(packet, fn)
scope:once(packet, fn)
scope:add(rbxConnection)
scope:destroy()
```

### Targets

Server-side `:send` second arg.

| Target | Description |
|:---|:---|
| `Player` | One player. |
| `Lync.all` | All connected. |
| `Lync.except(...)` | Everyone except given players or groups. |
| `{ p1, p2 }` | Array of players. |
| `group` | All members. |

### Middleware

```luau
Lync.onSend(function(data, name, player)    return data end)  -- return Lync.DROP to discard
Lync.onReceive(function(data, name, player) return data end)
Lync.onDrop(function(player, reason, name, data) end)
```

All return a `Connection`.

### Connection

| | |
|:---|:---|
| `c.connected` | boolean |
| `c:disconnect()` | Idempotent. |

### Stats

`Lync.configure({ stats = true })`.

| Function | Description |
|:---|:---|
| `Lync.stats.player(p)` | `{ bytesSent, bytesReceived }`. Server only. |
| `Lync.stats.reset()` | Zero all counters. |
| `packet:stats()` | `{ bytesSent, bytesReceived, fires, recvFires, drops }` |

### Debug

| Function | Description |
|:---|:---|
| `Lync.debug.pending()` | In-flight query requests. |
| `Lync.debug.registrations()` | Frozen array of `{ name, id, kind, isUnreliable }`. |

## Codecs

### Numbers

| Codec | Bytes | Notes |
|:---|---:|:---|
| `int(min, max)` | 1 / 2 / 4 | Picks smallest u8/u16/u32/i8/i16/i32. |
| `f16` / `f32` / `f64` | 2 / 4 / 8 | f16: ±65504, ~3 digits. |
| `float(min, max, precision)` | 1–4 | Quantized. Clamped. |
| `bool` | 1 | Auto-bitpacked inside `struct` and `array`. |

### Strings & buffers

| Codec | Notes |
|:---|:---|
| `string` | Variable length. Binary-safe. |
| `string(maxLength)` | Bounded. Rejects on read if exceeded. |
| `buff` | Variable-length buffer. |

### Roblox types

| Codec | Bytes |
|:---|---:|
| `vec2` / `vec3` | 8 / 12 |
| `cframe` | 24 |
| `color3` | 3 |
| `inst` | 2 |
| `udim` / `udim2` | 8 / 16 |
| `numberRange` | 8 |
| `rect` | 16 |
| `ray` | 24 |
| `vec2int16` / `vec3int16` | 4 / 6 |
| `region3` / `region3int16` | 24 / 12 |
| `numberSequence` / `colorSequence` | variable |

### Quantized variants

Call as a function for compression.

| Codec | Bytes | Notes |
|:---|---:|:---|
| `vec2(min, max, precision)` | 2–8 | Per-component. |
| `vec3(min, max, precision)` | 3–12 | Per-component. |
| `cframe()` | 16 | Smallest-three quaternion. ≤0.16° rotation error. |

### Composites

| Codec | Notes |
|:---|:---|
| `struct({k = c})` | Named fields. Bools auto-bitpacked. |
| `array(c, max?)` | List. Bool arrays bitpacked. |
| `map(k, v, max?)` | Key-value pairs. |
| `optional(c)` | 1B nil flag + value. |
| `tuple(...)` | Positional. |
| `tagged(field, {name = c})` | Discriminated union. 1B tag. ≤256 variants. |

### Delta — reliable only

Sends 1 byte when unchanged.

| Codec |
|:---|
| `deltaStruct(schema)` |
| `deltaArray(c, max?)` |
| `deltaMap(k, v, max?)` |

### Meta

| Codec | Notes |
|:---|:---|
| `enum(...)` | String enum. ≤256 variants. 1B. |
| `bitfield(schema)` | 1–32 bits. Sub-byte packing. |
| `custom(size, write, read, typeCheck?)` | User-defined fixed-size. |
| `nothing` | 0 bytes. Reads `nil`. |
| `unknown` | Bypass serialization. Use with `validate`. |
| `auto` | Self-describing. nil/bool/numbers/strings/buffers/Roblox types. |

## Rate limiting

Per-packet, pick one mode:

```luau
{ maxPerSecond = N, burst = M }   -- token bucket
{ cooldown = seconds }             -- cooldown
```

Global per-player: `Lync.configure({ globalRateLimit = { maxPerSecond = N } })`.

## Limits

| | |
|:---|---:|
| Packet + query IDs | 127 |
| Buffer per frame | 1 MB max |
| In-flight queries | 65,536 |
| Enum / tagged variants | 256 |
| Bitfield total bits | 32 |

## Benchmarks

`rojo serve bench.project.json` with one server + one client.

CPU benches auto-tune iter count to ~50 ms per case so timings are comparable across operations of wildly different cost.

### Codec throughput

| Codec | Encode | Decode | RT/s |
|:---|---:|---:|---:|
| `bool` | 53 ns | 28 ns | 12.4 M |
| `int(0, 255)` | 40 ns | 25 ns | 15.3 M |
| `int(0, 65535)` | 40 ns | 25 ns | 15.4 M |
| `f16` | 60 ns | 42 ns | 9.8 M |
| `f32` | 40 ns | 27 ns | 14.9 M |
| `f64` | 41 ns | 24 ns | 15.5 M |
| `string` (10 chars) | 48 ns | 71 ns | 8.5 M |
| `string` (1000 chars) | 72 ns | 243 ns | 3.2 M |
| `vec3` | 53 ns | 27 ns | 12.5 M |
| `vec3` quantized | 133 ns | 83 ns | 4.6 M |
| `cframe` | 86 ns | 146 ns | 4.3 M |
| `cframe()` | 118 ns | 168 ns | 3.5 M |
| entity struct (6 fields) | 231 ns | 408 ns | 1.6 M |
| 100× entities | 14.8 µs | 34.4 µs | 20 K |
| 1000× bools (bitpacked) | 4.2 µs | 5.9 µs | 99 K |

### Wire sizes

| Codec | Bytes |
|:---|---:|
| entity struct (6 fields, lossless) | 34 |
| entity compact (quantized) | 13 |
| 100× entities | 601 |
| 1000× bools (bitpacked) | 127 |
| bitfield flags | 2 |
| `tuple(u8, vec3, bool)` | 14 |

### Delta savings

| Codec | Full | Unchanged |
|:---|---:|---:|
| `deltaStruct` (entity) | 35 B | 1 B |
| `deltaStruct` (compact) | 14 B | 1 B |
| `deltaArray` (100× entity) | 602 B | 1 B |
| `deltaArray` (1000× bool) | 128 B | 1 B |
| `deltaMap` (string → u8) | 19 B | 1 B |

### Cross-library comparison

Same methodology as [Blink](https://github.com/1Axen/blink/blob/main/benchmark/Benchmarks.md): 1000 fires/frame, identical data, 10 s. Other-tool numbers from Blink v0.17.1.

> [!NOTE]
> Lync batches all sends into one buffer per frame and bitpacks bools (1000 = 127 B vs ~1002 B). Delta compression isn't exercised here.

**100× struct(6× u8) entities**

| Tool | FPS | Kbps |
|:---|---:|---:|
| roblox | 16 | 559,364 |
| **lync** | **60** | **3.47** |
| blink | 42 | 41.81 |
| zap | 39 | 41.71 |
| bytenet | 32 | 41.64 |

**1000× bool**

| Tool | FPS | Kbps |
|:---|---:|---:|
| roblox | 21 | 353,107 |
| **lync** | **60** | **2.33** |
| blink | 97 | 7.91 |
| zap | 52 | 8.10 |
| bytenet | 35 | 8.11 |

## License

MIT
