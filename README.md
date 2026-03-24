<h1 align="center">Lync</h1>
<p align="center">Buffer networking for Roblox.</p>
<p align="center">
  <a href="https://github.com/Axp3cter/Lync/releases/latest">Releases</a> ·
  <a href="#install">Install</a> ·
  <a href="#example">Example</a> ·
  <a href="#codecs">Codecs</a> ·
  <a href="#wire-protocol">Wire Protocol</a> ·
  <a href="#benchmarks">Benchmarks</a>
</p>

Lync serializes structured data into flat buffers, batches all sends into a single `RemoteEvent:FireClient` per player per frame, and applies XOR framing so Roblox's internal deflate compressor can eliminate redundancy across frames. On the server, every incoming payload is schema-validated and rate-limited before any listener fires.

All codecs are defined at runtime. No code generation, no build step, no external CLI. Packets, queries, groups, and middleware are configured in shared modules and resolved at `Lync.start()`.

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

Or grab the `.rbxm` from [Releases](https://github.com/Axp3cter/Lync/releases/latest) and drop it into `ReplicatedStorage`.

> [!IMPORTANT]
> All packets, queries, and groups must be defined before calling `Lync.start()`. The registry assigns sequential IDs at define time. Defining packets after `start()` will cause ID mismatches between server and client.

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

## Lifecycle

| Function | Behavior |
|:---------|:---------|
| `Lync.configure(options)` | Sets limits and enables stats. Must be called before `start()`. See [Configuration](#configuration). |
| `Lync.start()` | Server creates remotes under `ReplicatedStorage.LyncRemotes`. Client waits for them. Connects the Heartbeat flush loop. Errors if called twice. |
| `Lync.started` | Read-only boolean. `true` after `start()` returns. |
| `Lync.flush()` | Forces an immediate buffer flush. Resets the accumulator to prevent double-sending on the next Heartbeat. Errors if not started. |
| `Lync.flushRate(hz)` | 1–60. Default 60. At 60, flushes every Heartbeat directly. Below 60, uses an elapsed-time accumulator with drift correction. Callable at runtime. |

## Packets

`Lync.packet(name, codec, options?)` returns a Packet handle. The second argument is any codec. Options go in the optional third argument.

### Packet Options

| Field | Type | Default | Behavior |
|:------|:-----|:--------|:---------|
| `unreliable` | `boolean` | `false` | Routes through `UnreliableRemoteEvent`. Incompatible with delta codecs (errors at define time). |
| `rateLimit` | `RateLimitConfig` | none | Server-side rate limiting on incoming fires. See [Rate Limiting](#rate-limiting). |
| `validate` | `(data, player) → (bool, string?)` | none | Server-side callback after schema validation. Return `false, "reason"` to drop. Fires `onDrop`. |
| `maxPayloadBytes` | `number` | none | Maximum bytes a single payload can consume. |
| `timestamp` | `"frame"`, `"offset"`, or `"full"` | none | Prepends a timestamp to each item. `"frame"` = u8 wrapping counter (1B). `"offset"` = u16 milliseconds into the current second (2B). `"full"` = f64 `os.clock()` (8B). Listeners receive it as a third argument after `sender`. |

### Packet Methods

**Sending (server):**

```luau
packet:send(data, player)              -- single player
packet:send(data, Lync.all)            -- all connected players
packet:send(data, Lync.except(p1, p2)) -- all except specified
packet:send(data, { p1, p2, p3 })      -- array of players
packet:send(data, group)               -- group members
```

**Sending (client):**

```luau
packet:send(data)  -- to server
```

**Receiving (both):**

| Method | Behavior |
|:-------|:---------|
| `packet:on(fn)` | Connects a listener. `fn(data, sender, timestamp?)`. Server `sender` is `Player`. Client `sender` is `nil`. Returns a [Connection](#connection). |
| `packet:once(fn)` | Same as `on` but auto-disconnects after one fire. |
| `packet:wait()` | Yields until the next fire. Returns `(data, sender, timestamp?)`. |
| `packet:name()` | Returns the registration name string. |
| `packet:stats()` | Returns `{ bytesSent, bytesReceived, fires, recvFires, drops }`. Populated only when stats are enabled. |

## Queries

`Lync.query(name, requestCodec, responseCodec, options?)` returns a Query handle. Built on RemoteEvents with varint correlation IDs. Returns `nil` on timeout or handler error.

### Query Options

| Field | Type | Default | Behavior |
|:------|:-----|:--------|:---------|
| `timeout` | `number` | 5 | Seconds before the request yields `nil`. |
| `rateLimit` | `RateLimitConfig` | `{ maxPerSecond = 30 }` | Server-side rate limiting on incoming requests. |
| `validate` | `(data, player) → (bool, string?)` | none | Server-side validation on incoming requests. |

### Query Methods

| Method | Context | Behavior |
|:-------|:--------|:---------|
| `query:handle(fn)` | Both | Registers a handler. Server: `fn(request, player) → response`. Client: `fn(request) → response`. Returns a Connection that clears the handler on disconnect. |
| `query:request(data)` | Client | Sends request to server, yields until response or timeout. Returns the response or `nil`. |
| `query:request(data, player)` | Server | Sends request to one client, yields until response or timeout. |
| `query:request(data, target)` | Server | Sends request to multiple targets. Returns `{ [Player]: response? }`. Accepts `Lync.all`, arrays, and groups. |
| `query:name()` | Both | Returns the registration name. |
| `query:stats()` | Both | Returns combined stats for the request and response channels. |

Each query consumes two packet IDs internally (one for requests, one for responses).

## Groups

`Lync.group(name)` returns a Group. Members are removed automatically on `PlayerRemoving`. Names must be unique (duplicate errors). Destroyed groups free their name for reuse.

Groups implement `__iter`, so `for player in group do` works directly.

| Method | Returns | Behavior |
|:-------|:--------|:---------|
| `group:add(player)` | `boolean` | `true` if added, `false` if already a member. |
| `group:remove(player)` | `boolean` | `true` if removed, `false` if not a member. |
| `group:has(player)` | `boolean` | Membership check. |
| `group:count()` | `number` | Current member count. |
| `group:destroy()` | — | Clears all members and frees the name. Safe to call multiple times. |

## Scope

`Lync.scope()` batches connections for lifecycle-aligned cleanup.

```luau
local scope = Lync.scope()
scope:on(packetA, fnA)
scope:on(packetB, fnB)
scope:add(someRBXScriptConnection)
scope:destroy()
```

| Method | Behavior |
|:-------|:---------|
| `scope:on(source, fn)` | Calls `source:on(fn)` and tracks the returned connection. |
| `scope:once(source, fn)` | Calls `source:once(fn)` and tracks the returned connection. |
| `scope:add(connection)` | Accepts both Lync connections and `RBXScriptConnection`. |
| `scope:destroy()` | Disconnects all tracked connections. Safe to call multiple times. |

## Connection

Returned by `packet:on()`, `packet:once()`, `query:handle()`, `scope:on()`, and middleware functions.

| Field/Method | Behavior |
|:-------------|:---------|
| `connection.connected` | `boolean`. `true` until disconnected. |
| `connection:disconnect()` | Stops the listener. O(1) via swap-remove. Safe to call multiple times. Safe to call during a fire (snapshot iteration prevents skipped listeners). |

## Middleware

Global intercept chains on all packets. Handlers run in registration order. Return a transformed value to pass it downstream. Return `nil` to pass through unchanged. Return `Lync.DROP` from `onSend` to silently drop the packet.

All three functions return a [Connection](#connection).

| Function | Behavior |
|:---------|:---------|
| `Lync.onSend(fn)` | `fn(data, name, player?) → data?`. Runs before serialization. |
| `Lync.onReceive(fn)` | `fn(data, name, player?) → data?`. Runs after deserialization and validation. |
| `Lync.onDrop(fn)` | `fn(player, reason, name, data?)`. Fires when a packet is rejected. Reason is `"rate"`, `"validation"`, or the string returned by the `validate` callback. |
| `Lync.DROP` | Frozen sentinel. Return from `onSend` to silently drop the packet. |

## Targets

Server-side second argument to `packet:send()` and `query:request()`.

| Target | Behavior |
|:-------|:---------|
| `player` | Single `Player` instance. |
| `Lync.all` | All connected players via `Players:GetPlayers()`. |
| `Lync.except(...)` | All players except specified. Accepts any mix of `Player` and Group arguments. |
| `{ p1, p2, ... }` | Lua array of players. Non-player entries are silently skipped. |
| `group` | All current members of a [Group](#groups). |

## Codecs

### Numbers

`Lync.int(min, max)` selects the smallest wire type that fits the range:

| Range | Wire | Bytes |
|:------|:-----|------:|
| `[0, 255]` | u8 | 1 |
| `[0, 65535]` | u16 | 2 |
| `[0, 4294967295]` | u32 | 4 |
| `[-128, 127]` | i8 | 1 |
| `[-32768, 32767]` | i16 | 2 |
| `[-2147483648, 2147483647]` | i32 | 4 |

Signed integers use unsigned buffer writes (`writeu8`/`writeu16`/`writeu32`) with two's complement conversion because `writei8`/`writei16`/`writei32` are not FASTCALL-optimized in Luau.

| Codec | Bytes | Behavior |
|:------|------:|:---------|
| `Lync.f16` | 2 | Half-precision IEEE 754. ~3 decimal digits. ±65504 normal range. Overflow clamps to ±inf. NaN preserved. |
| `Lync.f32` | 4 | IEEE 754 single-precision. |
| `Lync.f64` | 8 | IEEE 754 double-precision. |
| `Lync.bool` | 1 | `true`/`false`. Inside structs, bools are separated and bitpacked (8 per byte). Inside arrays, bools are bitpacked. Standalone uses 1 byte. |

`Lync.float(min, max, precision)` quantizes a float range to an integer range. Wire type is selected by `ceil((max - min) / precision)`: u8 if ≤ 255, u16 if ≤ 65535, u32 otherwise. Values outside `[min, max]` are clamped.

### Strings and Buffers

| Codec | Wire format | Behavior |
|:------|:------------|:---------|
| `Lync.string` | varint length + raw bytes | Lengths 0–191 use a 1-byte prefix (dense prefix-varint). 192+ use multi-byte. Binary-safe. |
| `Lync.string(maxLength)` | same | Callable via `__call`. Same write path. Read rejects if decoded length exceeds `maxLength`. |
| `Lync.buff` | varint length + raw bytes | Same wire format as string. Read returns an isolated buffer copy. |

### Roblox Types

All fixed-size types expose `_directWrite` and `_directRead` for struct fast-path optimization, except `Lync.inst` (requires the channel's ref array).

| Codec | Bytes | Wire layout |
|:------|------:|:------------|
| `Lync.vec2` | 8 | 2× f32 |
| `Lync.vec3` | 12 | 3× f32 |
| `Lync.cframe` | 24 | 3× f32 position + 3× f32 axis-angle rotation |
| `Lync.color3` | 3 | 3× u8 RGB, clamped to [0, 1] then scaled to [0, 255] |
| `Lync.inst` | 2 | u16 index into sidecar `{ Instance }` array |
| `Lync.udim` | 8 | f32 Scale + i32 Offset |
| `Lync.udim2` | 16 | 2× UDim |
| `Lync.numberRange` | 8 | f32 Min + f32 Max |
| `Lync.rect` | 16 | 4× f32 |
| `Lync.ray` | 24 | 6× f32 (Origin + Direction) |
| `Lync.vec2int16` | 4 | 2× i16 |
| `Lync.vec3int16` | 6 | 3× i16 |
| `Lync.region3` | 24 | 6× f32 (Min + Max) |
| `Lync.region3int16` | 12 | 6× i16 (Min + Max) |
| `Lync.numberSequence` | varint + N×12 | f32 time + f32 value + f32 envelope per keypoint |
| `Lync.colorSequence` | varint + N×7 | f32 time + u8 R + u8 G + u8 B per keypoint |

### Quantized Variants

These codecs are callable. The bare name gives the lossless version; calling with arguments gives the quantized version.

| Codec | Bytes | Behavior |
|:------|------:|:---------|
| `Lync.vec2(min, max, precision)` | 2–8 | Per-component quantization. 2B at u8, 4B at u16, 8B at u32. |
| `Lync.vec3(min, max, precision)` | 3–12 | Per-component quantization. 3B at u8, 6B at u16, 12B at u32. |
| `Lync.cframe()` | 16 | Smallest-three quaternion compression. 3× f32 position (12B) + 2-bit largest-component index + 3× 10-bit signed quaternion components (4B). Angular precision ≤ 0.16° (~0.003 radians). Saves 8 bytes vs lossless. |

### Composites

| Constructor | Behavior |
|:------------|:---------|
| `Lync.struct(schema)` | `{ [string]: Codec }`. Fields serialized in sorted key order. Bools separated and bitpacked after all non-bool fields. All-fixed-size structs expose `_size`, `_directWrite`, `_directRead`. |
| `Lync.array(element, maxCount?)` | Varint count + elements. Fixed-size elements use a stride loop. Bool elements are bitpacked. Optional `maxCount` rejects on read. |
| `Lync.map(keyCodec, valueCodec, maxCount?)` | Varint count + key-value pairs. |
| `Lync.optional(codec)` | 1-byte flag. `0` = nil. `1` = value follows. |
| `Lync.tuple(...)` | Positional values without keys. All-fixed-size tuples expose `_size`. |
| `Lync.tagged(tagField, variants)` | Discriminated union. u8 variant tag. `variants` is `{ [string]: Codec }`, sorted alphabetically for deterministic tag assignment. Tag field is injected on read. |

### Delta Codecs

Reliable transport only. Errors at define time if combined with `unreliable = true`.

Delta codecs serialize into a scratch buffer and compare byte-for-byte against a cached baseline. Identical bytes produce a 1-byte `UNCHANGED` flag. Any difference triggers a full re-send prefixed with a `FULL` flag byte.

| Constructor | Behavior |
|:------------|:---------|
| `Lync.deltaStruct(schema)` | Same schema as `struct`. First frame is always full. |
| `Lync.deltaArray(element, maxCount?)` | Delta-framed array. |
| `Lync.deltaMap(keyCodec, valueCodec, maxCount?)` | Delta-framed map. |

### Meta Codecs

| Constructor | Behavior |
|:------------|:---------|
| `Lync.enum(...)` | String enum. u8 index, up to 256 variants. Errors on unknown values at write time and duplicate values at define time. |
| `Lync.bitfield(schema)` | Sub-byte packing, 1–32 bits. Spec: `{ type = "bool" }`, `{ type = "uint", width = N }`, or `{ type = "int", width = N }`. Wire: 1B ≤8 bits, 2B ≤16 bits, 4B ≤32 bits. Signed ints use sign extension. Fields sorted alphabetically. |
| `Lync.custom(size, write, read)` | User-defined fixed-size codec. `write(buffer, offset, value)`, `read(buffer, offset) → value`. |
| `Lync.nothing` | Zero bytes. Reads `nil`. |
| `Lync.unknown` | Bypasses buffer serialization. Values go through the remote's sidecar array. Warns at define time if used without `validate`. |
| `Lync.auto` | Self-describing. u8 type tag + value. Integers auto-sized. Floats try f32 then f64. Supports nil, bool, number, string, buffer, and 15 Roblox types. Tables error. |

## Wire Protocol

### Dense Prefix-Varint

Variable-length unsigned integer encoding. 1-byte range covers 0–191 (LEB128 only covers 0–127).

| Range | Bytes | Encoding |
|:------|------:|:---------|
| 0–191 | 1 | Direct value |
| 192–8,383 | 2 | `0xC0 + high5`, `low8` |
| 8,384–1,056,959 | 3 | `0xE0 + high4`, `low16 LE` |
| 1,056,960–4,294,967,295 | 5 | `0xF0`, `u32 LE` |

### MSB Batch Framing

All sends within one Heartbeat are batched into a single buffer per player per reliability channel.

**Single-item:** `[1IIIIIII] [payload]` — MSB set, 7-bit packet ID, no count byte. 1-byte header.

**Multi-item:** `[0IIIIIII] [u16 count] [payload₁] ...` — MSB clear, u16 item count follows. Used when ≥2 sends to the same packet occur in one frame.

The single-item path saves 2 bytes per packet per frame vs always writing a count. Maximum 127 packet IDs (7 bits).

### XOR Framing

Reliable channels XOR the current frame against the previous before sending. The receiver XOR's against its previous decoded frame to recover the original. Produces long zero runs that compress well under Roblox's internal deflate.

XOR operates in u32-aligned chunks with u8 remainder. Mismatched frame sizes are handled: excess bytes in a longer frame are copied directly.

Unreliable channels skip XOR (no guaranteed frame ordering).

## Security

### Schema Validation

Every incoming packet on the server passes through Gate before listeners fire:

- **`_typeCheck`**: Rejects wrong `typeof`.
- **`_isInteger` + `_min`/`_max`**: Rejects non-integers, NaN, inf, out-of-range.
- **`_schema`** (struct codecs): Recursive per-field validation.
- **Fallback**: NaN/inf scan up to `validationDepth` levels for codecs without metadata.

Rejected packets fire `onDrop` and are silently discarded. Other packets in the same frame from the same player are unaffected.

### Rate Limiting

Two modes (mutually exclusive):

**Token bucket:** `{ maxPerSecond = N, burst = M }`. Tokens refill at N/sec. Burst defaults to 1. Each fire costs one token.

**Cooldown:** `{ cooldown = seconds }`. Rejects fires within `cooldown` seconds of the last accepted fire.

Global rate limit: `Lync.configure({ globalRateLimit = { maxPerSecond = N } })`. Checked before per-packet limits.

### Bandwidth Throttle

`Lync.configure({ bandwidthLimit = { softLimit = bytes, maxStrikes = N } })`. Per-player. Oversized frames increment strikes. Small frames decrement (decay). Exceeding `maxStrikes` drops the entire frame.

## Stats

Disabled by default. Zero overhead when off. Enable via `Lync.configure({ stats = true })`.

| Function | Behavior |
|:---------|:---------|
| `packet:stats()` | `{ bytesSent, bytesReceived, fires, recvFires, drops }` |
| `Lync.stats.player(player)` | `{ bytesSent, bytesReceived }` or `nil`. Server only. |
| `Lync.stats.reset()` | Zeros all counters. |

## Debug

| Function | Behavior |
|:---------|:---------|
| `Lync.debug.pending()` | In-flight query request count. |
| `Lync.debug.registrations()` | Frozen array of `{ name, id, kind, isUnreliable }`. |

## Configuration

`Lync.configure(options)` — call before `Lync.start()`.

| Option | Default | Range | Behavior |
|:-------|--------:|:------|:---------|
| `channelMaxSize` | 262,144 | 4,096–1,048,576 | Max bytes per channel buffer per frame. |
| `validationDepth` | 16 | 4–32 | Max recursion for NaN/inf scanning. |
| `poolSize` | 16 | 2–128 | ChannelState reuse pool size. |
| `bandwidthLimit` | none | — | `{ softLimit, maxStrikes }`. Per-player. |
| `globalRateLimit` | none | — | `{ maxPerSecond }`. Per-player across all packets. |
| `stats` | `false` | — | Enables stat counters. |

## Limits

| Constraint | Value |
|:-----------|------:|
| Max packet/query registrations | 127 (7-bit wire ID, queries use 2 each) |
| Max buffer per channel per frame | 256 KB default, 1 MB max |
| Max concurrent query requests | 65,536 (varint correlation IDs) |
| `Lync.enum` variants | 256 |
| `Lync.bitfield` total bits | 32 |
| `Lync.tagged` variants | 256 |
| Bool packing density | 8 per byte |
| String inline varint threshold | 191 bytes (1B prefix), 192+ uses multi-byte |
| Delta + unreliable | Not allowed (define-time error) |

## Benchmarks

Run `rojo serve bench.project.json`, open in Studio with one local server + one client.

See `bench/Run.server.luau` for full configuration and methodology.

### Wire Sizes

Exact byte count per codec write. Raw payload only — no batch framing overhead included.

| Codec | Input | Bytes |
|:------|:------|------:|
| `bool` | `true` | 1 |
| `int(0, 255)` | `42` | 1 |
| `int(0, 65535)` | `1000` | 2 |
| `int(0, 1000000)` | `500000` | 4 |
| `int(-128, 127)` | `-50` | 1 |
| `f16` | `42.5` | 2 |
| `f32` | `3.14` | 4 |
| `f64` | `π` | 8 |
| `nothing` | `nil` | 0 |
| `string` | `""` (empty) | 1 |
| `string` | 5 chars | 6 |
| `string` | 191 chars (max inline prefix) | 192 |
| `string` | 192 chars (varint prefix) | 194 |
| `string` | 1000 chars | 1002 |
| `vec2` | lossless | 8 |
| `vec2(0, 100, 1)` | u8 quantized | 2 |
| `vec3` | lossless | 12 |
| `vec3(0, 100, 1)` | u8 quantized | 3 |
| `vec3(-1000, 1000, 0.1)` | u16 quantized | 6 |
| `cframe` | lossless | 24 |
| `cframe()` | smallest-three | 16 |
| `color3` | RGB | 3 |
| `ray` | origin + direction | 24 |
| entity struct | 6 fields + bool (lossless) | 34 |
| entity struct | quantized fields (compact) | 13 |
| bitfield | bool + uint packed | 2 |
| `array` × 100 entities | 100× struct(6× u8) | 601 |
| `array` × 1000 bools | bitpacked | 127 |

### Codec Throughput

Isolated CPU cost. No networking. Encode + decode measured independently. 100k iterations with warmup.

| Codec | Bytes | Encode | Decode | Round-trips/sec |
|:------|------:|-------:|-------:|----------------:|
| `bool` | 1 | 44ns | 29ns | 13,862,127 |
| `int(0, 255)` | 1 | 42ns | 28ns | 14,387,868 |
| `int(0, 65535)` | 2 | 41ns | 28ns | 14,395,324 |
| `f16` | 2 | 61ns | 42ns | 9,686,824 |
| `f32` | 4 | 41ns | 25ns | 15,003,300 |
| `f64` | 8 | 41ns | 26ns | 14,844,063 |
| `string` (empty) | 1 | 30ns | 22ns | 19,240,019 |
| `string` (10 chars) | 11 | 46ns | 60ns | 9,441,889 |
| `string` (100 chars) | 101 | 48ns | 91ns | 7,166,506 |
| `string` (1000 chars) | 1002 | 76ns | 238ns | 3,179,953 |
| `vec2` | 8 | 75ns | 43ns | 8,417,720 |
| `vec3` | 12 | 53ns | 27ns | 12,360,328 |
| `vec3` (quantized) | 3 | 130ns | 85ns | 4,636,348 |
| `cframe` (lossless) | 24 | 92ns | 144ns | 4,232,266 |
| `cframe()` (compressed) | 16 | 123ns | 170ns | 3,413,621 |
| `color3` | 3 | 125ns | 58ns | 5,482,756 |
| `udim2` | 16 | 235ns | 112ns | 2,880,482 |
| entity struct | 34 | 239ns | 395ns | 1,578,183 |
| entity compact | 13 | 377ns | 490ns | 1,153,064 |
| bitfield flags | 2 | 142ns | 332ns | 2,107,486 |
| 100× entity array | 601 | 15.2µs | 34.1µs | 20,306 |
| 1000× bool array | 127 | 4.3µs | 5.1µs | 106,806 |

### Delta Savings

Byte cost across three consecutive writes: initial (full), identical repeat (unchanged), and single-field mutation (changed).

| Codec | Full | Unchanged | Changed | Savings |
|:------|-----:|----------:|--------:|--------:|
| `deltaStruct` (entity) | 35B | 1B | 35B | 97% |
| `deltaStruct` (compact) | 14B | 1B | 14B | 93% |
| `deltaArray` (100× entity) | 602B | 1B | 1B | 100% |
| `deltaArray` (1000× bool) | 128B | 1B | 1B | 99% |
| `deltaMap` (string → u8) | 19B | 1B | 19B | 95% |

### Batch Framing

MSB single-item batches use a 1-byte header. Multi-item batches add a u16 count after the header.

| Scenario | Total bytes | Per-item overhead |
|:---------|----------:|------------------:|
| 1 × u8 (single-item) | 2B | 1B |
| 10 × u8 (multi-item) | 13B | 0.3B |

### Network Throughput

Live sends to one player. Measured over 8 seconds. FPS and Kbps at median and tail.

| Packet | Fires/frame | FPS median | FPS p1 | Kbps median | Kbps p95 | Kbps p99 |
|:-------|:---:|----:|----:|-----:|-----:|-----:|
| booleans | 1000 | 60 | 59.9 | 2.5 | 6.2 | 6.2 |
| entity struct | 1000 | 60 | 59.9 | 2.3 | 2.4 | 2.4 |
| entity compact | 1000 | 60 | 59.9 | 2.4 | 2.5 | 2.5 |
| 100× entities | 100 | 60 | 59.9 | 2.3 | 3.1 | 3.1 |
| 1000× bools | 100 | 60 | 59.9 | 2.3 | 2.3 | 2.3 |
| bitfield flags | 1000 | 60 | 59.9 | 2.4 | 2.5 | 2.5 |
| cframe lossless | 1000 | 60 | 59.9 | 2.5 | 2.5 | 2.5 |
| cframe compressed | 1000 | 60 | 59.8 | 2.3 | 2.3 | 2.3 |

---

### Cross-Library Comparison

The tables below use the same data shapes and methodology as [Blink's published benchmarks](https://github.com/1Axen/blink/blob/main/benchmark/Benchmarks.md): 1,000 fires/frame, same data every frame, 10 seconds, Kbps scaled by 60/FPS.

Numbers for `blink`, `zap`, `bytenet`, and `roblox` are copied directly from [Blink v0.17.1 results](https://github.com/1Axen/blink/blob/main/benchmark/Benchmarks.md) (2025-04-30).

> [!NOTE]
> **Architectural differences that affect these numbers:**
> - Lync batches all sends into one buffer per Heartbeat frame. Other tools fire one RemoteEvent per `send()`, paying ~40 bytes of Roblox overhead per call.
> - Lync includes server-side schema validation and rate limiting. Other tools do not.
> - Lync bitpacks bool arrays (1,000 bools ≈ 127 bytes vs ~1,002 bytes for 1-byte-per-bool).
> - Lync uses runtime codecs. Blink and Zap use code generation with zero runtime schema.
> - Delta compression is not exercised here (same data every frame). See [Delta Savings](#delta-savings) for the real-world impact.
> - FPS is hardware-dependent. Kbps is FPS-scaled, making it comparable across machines.

**Tool versions:** blink v0.17.1 · zap v0.6.20 · bytenet v0.4.3 · lync v2.1.0

**Data shapes:** Entities = `100× struct { id u8, x u8, y u8, z u8, orientation u8, animation u8 }`. Booleans = `1000× bool`. [Source](https://github.com/1Axen/blink/blob/main/benchmark/src/shared/benches).

#### Entities — FPS

| Tool | Median | P0 | P80 | P90 | P95 | P100 | Loss |
|:-----|-------:|---:|----:|----:|----:|-----:|-----:|
| roblox | 16.00 | 16.00 | 15.00 | 15.00 | 15.00 | 15.00 | 0% |
| **lync** | **60.00** | **61.00** | **60.00** | **60.00** | **60.00** | **58.00** | **0%** |
| blink | 42.00 | 45.00 | 42.00 | 42.00 | 42.00 | 42.00 | 0% |
| zap | 39.00 | 40.00 | 38.00 | 38.00 | 38.00 | 38.00 | 0% |
| bytenet | 32.00 | 34.00 | 32.00 | 32.00 | 32.00 | 31.00 | 0% |

#### Entities — Kbps

| Tool | Median | P0 | P80 | P90 | P95 | P100 | Loss |
|:-----|-------:|---:|----:|----:|----:|-----:|-----:|
| roblox | 559,364 | 559,364 | 676,716 | 676,716 | 676,716 | 784,082 | 0% |
| **lync** | **3.68** | **3.61** | **3.72** | **3.75** | **3.75** | **4.18** | **0%** |
| blink | 41.81 | 26.30 | 42.40 | 42.48 | 42.48 | 42.62 | 0% |
| zap | 41.71 | 25.46 | 42.19 | 42.32 | 42.32 | 42.93 | 0% |
| bytenet | 41.64 | 22.84 | 42.36 | 42.82 | 42.82 | 43.24 | 0% |

#### Booleans — FPS

| Tool | Median | P0 | P80 | P90 | P95 | P100 | Loss |
|:-----|-------:|---:|----:|----:|----:|-----:|-----:|
| roblox | 21.00 | 22.00 | 20.00 | 19.00 | 19.00 | 19.00 | 0% |
| **lync** | **60.00** | **61.00** | **60.00** | **60.00** | **60.00** | **59.00** | **0%** |
| blink | 97.00 | 98.00 | 97.00 | 96.00 | 96.00 | 96.00 | 0% |
| zap | 52.00 | 53.00 | 51.00 | 51.00 | 51.00 | 49.00 | 0% |
| bytenet | 35.00 | 37.00 | 35.00 | 35.00 | 35.00 | 34.00 | 0% |

#### Booleans — Kbps

| Tool | Median | P0 | P80 | P90 | P95 | P100 | Loss |
|:-----|-------:|---:|----:|----:|----:|-----:|-----:|
| roblox | 353,107 | 196,827 | 690,748 | 842,240 | 842,240 | 1,124,176 | 0% |
| **lync** | **2.49** | **2.44** | **2.50** | **2.52** | **2.52** | **2.54** | **0%** |
| blink | 7.91 | 7.41 | 7.93 | 7.99 | 7.99 | 8.00 | 0% |
| zap | 8.10 | 5.75 | 8.17 | 8.22 | 8.22 | 8.27 | 0% |
| bytenet | 8.11 | 5.07 | 8.35 | 8.46 | 8.46 | 8.47 | 0% |

#### Wire Size Comparison

| Data | Lync | Other tools | Difference |
|:-----|-----:|------------:|-----------:|
| 100× entities | 601B | ~602B | -1B |
| 1000× bools | 127B | ~1002B | -875B (87% smaller) |

## License

MIT
