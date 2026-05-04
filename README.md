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

Schemas, packets, queries, groups, validation, rate limiting. Every send batches into one buffer per player per frame; identical frames XOR to ones already in flight; delta codecs collapse unchanged state to a single byte. No code generation.

## Install

Wally — add to your `wally.toml`:

```toml
Lync = "axp3cter/lync@2.3.3"
```

npm (roblox-ts):

```bash
npm install @axpecter/lync
```

```typescript
import Lync from "@axpecter/lync";
```

**Important.** Define every packet, query, and group before `Lync.start()`. Definitions assign sequential 7-bit IDs that both peers must agree on; defining late on one side desyncs the wire.

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

Net.Hit:on(function(data, sender) end)
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
scope:on(Net.State, function(state) end)

Net.Hit:send({ targetId = 123, damage = 45 })
local serverTime = Net.Ping:request(nil)
```

## API

### Lifecycle

| Function | Description |
|:---|:---|
| `Lync.configure(opts)` | Apply options. Must precede `start()`. |
| `Lync.start()` | Initialize transport. Call once. |
| `Lync.isStarted()` | `true` after `start()`. |
| `Lync.flush()` | Force an immediate send. |
| `Lync.flushRate(hz)` | 1–60 Hz. Default 60. |
| `Lync.reset()` | Restore module state to post-require defaults. For tests / hot reload. |

### Configure options

| Option | Default | Range | Description |
|:---|---:|:---|:---|
| `channelMaxSize` | 262144 | 4 KB – 1 MB | Per-frame buffer cap. |
| `validationDepth` | 16 | 4–32 | Schema-walk recursion limit. |
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
packet:send(data, Lync.except(p1, group1))
packet:send(data, { p1, p2, p3 })
packet:send(data, group)

-- Client
packet:send(data)

-- Both sides
local conn = packet:on(function(data, sender, timestamp) end)
packet:once(fn)
local data, sender, timestamp = packet:wait()
packet:name()
packet:stats() -- requires stats=true
```

| Option | Type | Description |
|:---|:---|:---|
| `unreliable` | boolean | Use `UnreliableRemoteEvent`. Rejected with delta codecs (a dropped frame would desync the baseline). |
| `rateLimit` | `RateLimitConfig` | Server-side per-player. |
| `validate` | `(data, player) → (bool, string?)` | Drop on `false`. Reason is forwarded to `onDrop`. |
| `maxPayloadBytes` | number | Reject oversize incoming payloads early. |
| `timestamp` | `"frame"`, `"offset"`, `"full"` | Append 1B / 2B / 8B timestamp. Read as the third arg. |

### Queries

`Lync.query(name, requestCodec, responseCodec, options?)`

Request-response on top of two paired registrations. Single-target requests yield until reply or timeout; multi-target requests gather a partial map.

```luau
-- Server
query:handle(function(data, player) return response end)
local resp = query:request(data, player)        -- response?
local map  = query:request(data, group)         -- { [Player]: response? }

-- Client
query:handle(function(data) return response end)
local resp = query:request(data)                -- yields; nil on timeout
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
| `:add(p)` / `:remove(p)` | `boolean` | `true` if membership changed. |
| `:has(p)` | `boolean` | |
| `:count()` | `number` | |
| `:destroy()` | — | Clear members and free the name. |

### Scope

`Lync.scope()` — batches connections for a single `:destroy()`.

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
| `Lync.except(...)` | Everyone except given Players or Groups. |
| `{ p1, p2 }` | Array of players. |
| `group` | All members. |

### Middleware

```luau
-- Return Lync.DROP from onSend to discard a packet.
Lync.onSend(function(data, name, player) return data end)
Lync.onReceive(function(data, name, player) return data end)
Lync.onDrop(function(player, reason, name, data) end)
```

All return a `Connection`. A throwing hook surfaces to the caller and aborts the chain at that point.

### Connection

| | |
|:---|:---|
| `c.connected` | `boolean` |
| `c:disconnect()` | Idempotent. |

### Stats

Enable with `Lync.configure({ stats = true })`.

| Function | Description |
|:---|:---|
| `Lync.stats.player(p)` | `{ bytesSent, bytesReceived }`. Server only. |
| `Lync.stats.reset()` | Zero all counters. |
| `packet:stats()` | `{ bytesSent, bytesReceived, fires, recvFires, drops }`. Aggregated across the request + response registrations on queries. |

### Debug

| Function | Description |
|:---|:---|
| `Lync.debug.pending()` | In-flight query correlation IDs. |
| `Lync.debug.registrations()` | Frozen `{ name, id, kind, isUnreliable }` per registration. |

`capture` / `stop` / `dump` are reserved no-ops for capture/replay tooling.

## Codecs

### Numbers

| Codec | Bytes | Notes |
|:---|---:|:---|
| `int(min, max)` | 1 / 2 / 4 | Picks narrowest u8/u16/u32/i8/i16/i32. |
| `zint(min?, max?)` | 1 – 5 | Variable-length signed via zigzag varint. 1 byte for [-96, 95]. |
| `f16` / `f32` / `f64` | 2 / 4 / 8 | `f16` ≈ ±65504, ~3 digits. |
| `float(min, max, precision)` | 1 / 2 / 3 / 4 | Quantized; picks u8 / u16 / u24 / u32 wire form. |
| `bool` | 1 | Auto-bitpacked inside `struct` and `array`. |

### Strings & buffers

| Codec | Notes |
|:---|:---|
| `string` | Variable length. Binary-safe. |
| `string(maxLength)` | Bounded. Rejects on read if exceeded. |
| `buff` | Variable-length raw `buffer`. |

### Roblox types

| Codec | Bytes |
|:---|---:|
| `vec2` / `vec3` | 8 / 12 |
| `cframe` | 24 |
| `color3` | 3 |
| `inst` | 2 (sidecar ref index) |
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
| `vec2(min, max, precision)` | 2 / 4 / 6 / 8 | Per-component, narrowest fitting width. |
| `vec3(min, max, precision)` | 3 / 6 / 9 / 12 | Per-component, narrowest fitting width. |
| `cframe()` | 16 | Smallest-three quaternion. ≤ 0.16° rotation error. |

### Composites

| Codec | Notes |
|:---|:---|
| `struct({k = c})` | Named fields. Bools auto-bitpacked into a tail block. |
| `array(c, max?)` | List. Bool arrays bitpacked. Direct path for fixed-size elements. |
| `map(k, v, max?)` | Key-value pairs; keys sorted at encode for stable wire bytes. |
| `optional(c)` | 1B presence flag + value. |
| `tuple(...)` | Positional. All-direct fast path when every element is fixed-size. |
| `tagged(field, {name = c})` | Discriminated union. 1B tag. Up to 256 variants. |

### Delta — reliable transport only

Tracks the previous frame's value and ships only what changed. Rejected on `unreliable = true`.

| Codec | Static | Mutation |
|:---|:---:|:---:|
| `deltaStruct(schema)` | 1 B | per-field |
| `deltaArray(c, max?)` | 1 B | per-changed-index |
| `deltaMap(k, v, max?)` | 1 B | per-changed-key |
| `deltaInt(min, max)` | 1 B | 1–5 B |
| `deltaFloat(min, max, precision)` | 1 B | 1–5 B |
| `deltaVec3(min, max, precision)` | 3 B | 3–15 B |
| `deltaCFrame(posMin, posMax, precision)` | 1 B | 4–13 B |

- `deltaArray` element / `deltaMap` key+value cannot themselves contain delta state. Use `deltaStruct` for per-field deltas inside.
- `deltaVec3` and `deltaCFrame` error on out-of-range components.

### Meta

| Codec | Notes |
|:---|:---|
| `enum(...)` | String enum. ≤ 256 variants. 1B u8 index. |
| `bitfield(schema)` | 1–32 bits total. `{ type = "bool" }`, `{ type = "uint", width }`, `{ type = "int", width }`. |
| `custom(size, write, read, typeCheck?)` | User-defined fixed-size codec. |
| `nothing` | 0 bytes; reads `nil`. For fire-and-forget signals. |
| `unknown` | Bypasses serialization through the channel sidecar. Must be paired with `validate`. |
| `auto` | Self-describing: nil / bool / numbers / strings / buffers / Roblox datatypes. 1B type tag + payload. |

## Rate limiting

Per-packet, pick one mode:

- Token bucket: `{ maxPerSecond = N, burst = M }`
- Cooldown: `{ cooldown = seconds }`

Global per-player cap: `Lync.configure({ globalRateLimit = { maxPerSecond = N } })`.

## Limits

| | |
|:---|---:|
| Packet + query IDs (combined) | 127 |
| Buffer per frame | 1 MB max |
| In-flight queries | 65,535 |
| Enum / tagged variants | 256 |
| Bitfield total bits | 32 |
| Sidecar refs per frame | 65,535 |

## Benchmarks

`rojo serve bench.project.json` with one server + one client.

### Cross-library — 1000 fires/frame, 10 s

[Blink's methodology](https://github.com/1Axen/blink/blob/main/benchmark/Benchmarks.md): same payload reused every frame, identical entity / bool shapes. Other tools from Blink v0.17.1.

| Tool | `array<entity>[100]` | `array<bool>[1000]` |
|:---|:---|:---|
| roblox | 16 fps · 559,364 Kbps | 21 fps · 353,107 Kbps |
| **lync** | **59 fps · 3.37 Kbps** | **61 fps · 2.45 Kbps** |
| blink | 42 fps · 41.81 Kbps | 97 fps · 7.91 Kbps |
| zap | 39 fps · 41.71 Kbps | 52 fps · 8.10 Kbps |
| bytenet | 32 fps · 41.64 Kbps | 35 fps · 8.11 Kbps |

### Network bandwidth — 100 fires/frame, 8 s

| Workload | Naive Kbps | Optimized | Savings |
|:---|---:|:---|---:|
| `array<entity>[100]` random | 3,607 | `deltaArray` 3 of 100 mutated | **154** (–96%) |
| `array<entity>[100]` reused | 3,607 | XOR baseline (identical frames) | **2.4** (–99.9%) |
| `array<bool>[1000]` random | 762 | XOR baseline (1 bit flipped) | **20.4** (–97%) |
| `struct(state)` random | 201 | `deltaStruct` 1 field mutated | **29.0** (–86%) |
| `map<id, vec3>[200]` 5 keys mutated | 657 | `deltaMap` 5 keys mutated | **393** (–40%) |
| `array<cframe>[50]` random | 4,585 | — | — |
| `vec3` walking motion (continuous diff) | — | `deltaVec3` | **19.5** |
| `CFrame` walking pose (pos + rot) | — | `deltaCFrame` | **41.1** |

## License

MIT
