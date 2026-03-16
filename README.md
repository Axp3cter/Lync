<h1 align="center">Lync</h1>
<p align="center">
  Binary networking for Roblox.<br>
  Batched, delta-encoded, XOR-framed. One RemoteEvent per frame.
</p>
<p align="center">
  <a href="https://github.com/Axp3cter/Lync/releases/latest">Releases</a> · <a href="#installation">Install</a> · <a href="#benchmarks">Benchmarks</a>
</p>

---

## What Lync Does

Lync is a runtime networking library for Roblox. You define packet schemas in Luau, and Lync handles serialization, batching, and transport — no build step, no code generation, no external tools. Drop it into ReplicatedStorage and go.

Every frame, Lync collects all sends into a single buffer per channel (reliable and unreliable), serializes them using your declared codecs, and fires one RemoteEvent. On the receiving side, it deserializes, validates, and dispatches. The entire path — from `.send()` to your listener callback — runs through binary buffers, not Roblox's default encoding.

**What makes Lync different from other buffer networking libraries:**

- **Delta compression.** `deltaStruct` and `deltaArray` only send fields that actually changed since the last frame. Unchanged fields cost zero bytes.
- **XOR framing.** Reliable channel buffers are XOR'd against the previous frame before sending. When most data is unchanged (the common case in gameplay), the XOR'd buffer is mostly zeros, which Roblox's internal deflate compresses extremely well.
- **Security built in.** Every incoming packet is scanned for NaN/inf values (recursive, up to configurable depth), rate-limited per packet with token buckets, and optionally validated with custom callbacks. Rejected packets fire a centralized `onDrop` handler with reason codes.
- **Middleware.** Intercept any packet on send or receive with chainable handlers. Namespace-scoped middleware only fires for packets in that namespace.
- **No build step.** Unlike IDL compilers (Blink, Zap), Lync is a pure Luau runtime library. Define schemas with function calls, not a custom language.

---

## Constraints & Limits

Know these before you build on Lync.

| Constraint | Default | Configurable | Notes |
| :--------- | ------: | :----------- | :---- |
| Max packet types | 255 | No | Packet IDs are u8 on the wire. Includes query pairs (each query uses 2 IDs). |
| Max buffer per channel per frame | 256 KB | Yes (`setChannelMaxSize`, 4 KB–1 MB) | One buffer per player per channel (reliable/unreliable). Warns at 75%. |
| Max concurrent queries | 65,536 | No | Correlation IDs are u16 on the wire. Slots free on response or timeout. |
| Query default timeout | 5s | Yes (per query, `timeout` field) | Returns `nil` to the caller on timeout. |
| NaN/inf scan depth | 16 levels | Yes (`setValidationDepth`, 4–32) | Tables nested deeper than this are rejected as malformed. |
| Idle channel pool | 16 objects | Yes (`setPoolSize`, 2–128) | Excess released channels are GC'd. ~1.5 KB per pooled channel. |
| Delta codecs + unreliable | — | No | `deltaStruct` and `deltaArray` require reliable delivery. Lync errors if you try to combine them with `unreliable = true`. |
| Namespaces | 64 max | No | Hard limit on `defineNamespace` calls. |
| Wire protocol | v0.6 | — | Not backward-compatible with v0.5. Query correlation IDs changed from u8 to u16. |

**All definitions must happen before `Lync.start()`.** Packets, queries, and namespaces register IDs at define time. Defining after start is undefined behavior.

---

## Installation

Place `Lync` in `ReplicatedStorage`. Define all packets before calling `start()`.

```luau
local Lync = require(ReplicatedStorage.Lync)

-- definitions here

Lync.start()
```

Install via [Wally](https://wally.run):

```toml
[dependencies]
Lync = "axpecter/lync@0.6.0-alpha"
```

Or grab the `.rbxm` from the [latest release](https://github.com/Axp3cter/Lync/releases/latest).

---

## Packets

Define once in a shared module. The API splits by context automatically — server gets `sendTo`/`sendToAll`/etc., client gets `send`.

```luau
local Hit = Lync.definePacket("Hit", {
    value = Lync.struct({
        targetId = Lync.u32,
        amount   = Lync.f32,
        crit     = Lync.bool,
    }),
})
```

<details>
<summary><b>Server</b></summary>

```luau
Hit:sendTo(data, player)
Hit:sendToAll(data)
Hit:sendToAllExcept(data, player)
Hit:sendToList(data, players)
Hit:sendToGroup(data, "lobby")
```
</details>

<details>
<summary><b>Client</b></summary>

```luau
Hit:send(data)
```
</details>

<details>
<summary><b>Listening</b></summary>

```luau
Hit:listen(function(data, sender) end)
Hit:once(function(data, sender) end)
Hit:wait()
Hit:disconnectAll()
```

`sender` is the `Player` on the server, `nil` on the client.
</details>

---

## Queries

Bidirectional request-reply built on RemoteEvents — no RemoteFunctions. Returns `nil` on timeout or handler error. Up to 65,536 concurrent in-flight queries.

```luau
local GetInventory = Lync.defineQuery("GetInventory", {
    request   = Lync.u32,
    response  = Lync.array(Lync.struct({
        itemId = Lync.u32,
        count  = Lync.u16,
    })),
    timeout   = 5,
    rateLimit = { maxPerSecond = 10 },
    validate  = function(data, player)
        return data > 0, "invalid id"
    end,
})
```

<details>
<summary><b>Server</b></summary>

```luau
GetInventory:listen(function(playerId, player)
    return fetchInventory(playerId)
end)

-- query a client
local response = GetInventory:invoke(request, player)
```
</details>

<details>
<summary><b>Client</b></summary>

```luau
local items = GetInventory:invoke(localPlayer.UserId)

-- listen for server queries
GetInventory:listen(function(request)
    return computeResponse(request)
end)
```
</details>

---

## Namespaces

Group related packets and queries under a shared name. Names are auto-prefixed (`"Combat.Hit"`, `"Combat.Death"`), preventing collisions. Namespaces provide batch operations and scoped middleware.

```luau
local Combat = Lync.defineNamespace("Combat", {
    packets = {
        Hit = {
            value = Lync.struct({
                targetId = Lync.u32,
                damage   = Lync.f32,
                crit     = Lync.bool,
            }),
        },
        Death = {
            value = Lync.struct({
                victimId = Lync.u32,
                killerId = Lync.u32,
            }),
        },
    },
    queries = {
        GetStats = {
            request  = Lync.u32,
            response = Lync.struct({ kills = Lync.u32, deaths = Lync.u32 }),
            timeout  = 5,
        },
    },
})
```

Access by short name — no prefix needed in code:

```luau
Combat.Hit:sendTo(data, player)
Combat.Death:sendToAll(data)
local stats = Combat.GetStats:invoke(playerId)
```

<details>
<summary><b>Batch listening</b></summary>

Listen to every packet in the namespace. The short name is passed as the first argument.

```luau
local conn = Combat:listenAll(function(name, data, sender)
    print(sender.Name, "sent", name, data)
end)

conn:disconnect()
```
</details>

<details>
<summary><b>Scoped middleware</b></summary>

Only fires for packets in this namespace. Non-matching packets pass through untouched.

```luau
local removeSend = Combat:onSend(function(data, name, player)
    if not isAlive(player) then return nil end
    return data
end)

local removeRecv = Combat:onReceive(function(data, name, player)
    log(name, data)
    return data
end)

removeSend()
removeRecv()
```
</details>

<details>
<summary><b>Cleanup & introspection</b></summary>

```luau
Combat:disconnectAll()    -- listeners only
Combat:destroy()          -- listeners + scoped middleware

Combat:packetNames()      -- { "Death", "Hit" } (sorted)
Combat:queryNames()       -- { "GetStats" } (sorted)
```
</details>

---

## Types

All codecs serialize to binary buffers. Fixed-size codecs report their `_size` for struct optimization. Variable-size codecs use varint length prefixes.

<details open>
<summary><b>Primitives</b></summary>

| Type   | Bytes | Range |
| :----- | ----: | :---- |
| `u8`   |     1 | 0 – 255 |
| `u16`  |     2 | 0 – 65,535 |
| `u32`  |     4 | 0 – 4,294,967,295 |
| `i8`   |     1 | -128 – 127 |
| `i16`  |     2 | -32,768 – 32,767 |
| `i32`  |     4 | -2,147,483,648 – 2,147,483,647 |
| `f16`  |     2 | ±65,504 (~3 decimal digits) |
| `f32`  |     4 | IEEE 754 single precision |
| `f64`  |     8 | IEEE 754 double precision |
| `bool` |     1 | true / false (packed into bitfields inside structs) |
</details>

<details>
<summary><b>Complex</b></summary>

| Type     | Bytes | Description |
| :------- | ----: | :---------- |
| `string` | varint + N | UTF-8 bytes, varint length prefix |
| `vec2`   |     8 | Vector2 as 2× f32 |
| `vec3`   |    12 | Vector3 as 3× f32 |
| `cframe` |    24 | Position (3× f32) + axis-angle rotation (3× f32). Identity rotation writes zeros for clean XOR deltas. |
| `color3` |     3 | 0–255 per channel, clamped |
| `inst`   |     2 | Instance reference via sidecar array (u16 index) |
| `buff`   | varint + N | Raw buffer, varint length prefix |
</details>

<details>
<summary><b>Composites</b></summary>

```luau
Lync.struct({ key = codec, ... })        -- named fields; bools auto-packed into bitfields
Lync.array(codec)                        -- variable-length list, varint count
Lync.map(keyCodec, valueCodec)           -- key-value pairs, varint count
Lync.optional(codec)                     -- 1 byte flag + value if present
Lync.tuple(codec1, codec2, ...)          -- positional, ordered, no keys
```
</details>

<details>
<summary><b>Delta (reliable only)</b></summary>

Only changed data is sent between frames. First frame sends everything. Subsequent frames send a bitmask of dirty fields/elements plus only the changed values. Identical frames cost 1 byte.

```luau
Lync.deltaStruct({ key = codec, ... })   -- dirty fields only
Lync.deltaArray(codec)                   -- dirty elements only (varint indices)
```

Delta codecs require reliable delivery — Lync errors at define time if combined with `unreliable = true`.
</details>

<details>
<summary><b>Specialized</b></summary>

```luau
Lync.enum("idle", "walking", "running")               -- u8 index, up to 256 variants
Lync.quantizedFloat(min, max, precision)               -- fixed-point, auto-selects u8/u16/u32
Lync.quantizedVec3(min, max, precision)                -- 3× quantized float
Lync.bitfield({                                        -- sub-byte packing (1–32 bits total)
    alive = { type = "bool" },
    level = { type = "uint", width = 5 },
    delta = { type = "int",  width = 4 },
})
Lync.tagged("kind", { move = moveCodec, chat = chatCodec })  -- discriminated union, u8 tag
```

| Type      | Description |
| :-------- | :---------- |
| `nothing` | Zero bytes, reads nil. For fire-and-forget signals with no payload. |
| `unknown` | Bypasses binary serialization entirely. Value is passed through Roblox's remote argument sidecar. Use when no typed codec exists. |
| `auto`    | Self-describing: writes a u8 type tag + value. Supports nil, bool, all integers, f32, f64, string, vec2, vec3, color3, cframe, buffer. |
</details>

---

## Packet Options

```luau
Lync.definePacket("Position", {
    value      = Lync.vec3,
    unreliable = true,
    rateLimit  = { maxPerSecond = 30, burstAllowance = 5 },
    validate   = function(data, player)
        return true
    end,
})
```

| Option | Required | Description |
| :----- | :------: | :---------- |
| `value` | Yes | Codec for the payload. |
| `unreliable` | No | Send via UnreliableRemoteEvent. Default `false`. Cannot combine with delta codecs. |
| `rateLimit` | No | Token-bucket rate limiter. `burstAllowance` defaults to `maxPerSecond`. Server-side only. |
| `validate` | No | Server-side callback. Return `false, "reason"` to drop the packet. Runs after NaN scanning. |

---

## Groups

Named player sets for targeted broadcasts. Players are auto-removed on `PlayerRemoving`.

```luau
Lync.createGroup("lobby")
Lync.addToGroup("lobby", player)        -- returns true if added, false if already in
Lync.removeFromGroup("lobby", player)   -- returns true if removed, false if absent
Lync.hasInGroup("lobby", player)        -- boolean
Lync.groupCount("lobby")                -- number
Lync.getGroupSet("lobby")               -- { [Player]: true }
Lync.forEachInGroup("lobby", fn)        -- calls fn(player) for each member
Lync.destroyGroup("lobby")              -- removes group and all memberships

-- Send to a group
Hit:sendToGroup(data, "lobby")
```

---

## Middleware

Intercept packets globally. Return `nil` to drop. Handlers chain in registration order. Each handler receives the data, the packet name, and the player (nil on client sends).

```luau
local removeSend = Lync.onSend(function(data, name, player)
    return data  -- pass through
end)

local removeRecv = Lync.onReceive(function(data, name, player)
    return data
end)

removeSend()  -- unregister
```

<details>
<summary><b>Drop handler</b></summary>

Called when an incoming packet is rejected by NaN scanning, rate limiting, or validation.

```luau
Lync.onDrop(function(player, reason, packetName, data)
    -- reason: "nan" | "rate" | "validate" | custom string from validate callback
end)
```
</details>

---

## Configuration

Optional tuning. Call before `start()`.

```luau
Lync.setChannelMaxSize(524288)   -- buffer cap per channel (default 256 KB, range 4 KB–1 MB)
Lync.setValidationDepth(24)      -- NaN/inf scan depth (default 16, range 4–32)
Lync.setPoolSize(32)             -- idle channel pool cap (default 16, range 2–128)
```

| Function | Default | Range | What it controls |
| :------- | ------: | :---- | :--------------- |
| `setChannelMaxSize` | 262,144 | 4,096 – 1,048,576 | Max bytes per channel buffer per frame. Warns at 75%, errors at limit. |
| `setValidationDepth` | 16 | 4 – 32 | How deep NaN/inf scanning recurses into nested tables. |
| `setPoolSize` | 16 | 2 – 128 | Idle ChannelState objects kept between frames. Excess is GC'd on release. |

**Introspection:**

```luau
Lync.version              -- "0.6.0-alpha"
Lync.queryPendingCount()  -- number of queries currently awaiting a response
```

---

## Benchmarks

Tested in Roblox Studio, local server with one player. 1,000 packets fired per frame for 10 seconds per test. Entity struct is 34 bytes: 2× vec3, 2× f32, bool, u8.

| Scenario | What changes each frame | Raw Kbps | Actual Kbps (median) | Actual Kbps (p95) | FPS (median) | Reduction |
| :------- | :---------------------- | -------: | -------------------: | ----------------: | -----------: | --------: |
| Static booleans | Nothing | 480 | 2.25 | 3.57 | 59.99 | 99.5% |
| Static entities | Nothing | 16,320 | 2.51 | 2.58 | 60.00 | 99.98% |
| Moving entities | Position only | 16,320 | 3.31 | 3.39 | 59.99 | 99.98% |
| Chaotic entities | Every field, random | 16,320 | 4.66 | 4.73 | 60.01 | 99.97% |

**How to read this:** "Raw Kbps" is what the data would cost without any optimization (payload bytes × 1,000 fires × 60 fps × 8 bits / 1,000). "Actual Kbps" is what Roblox reports on the wire after Lync's batching, XOR framing, and Roblox's internal deflate. The reduction column shows the ratio.

**Why static entities compress to 2.51 Kbps from 16,320:** Every frame sends the same 34-byte struct 1,000 times. Lync batches them into one buffer, XORs against the previous frame (producing all zeros since nothing changed), and Roblox deflate compresses the zero buffer to near-nothing. The 2.51 Kbps is mostly RemoteEvent overhead.

**Why chaotic entities are still only 4.66 Kbps:** Even with every field randomized, batching 1,000 packets into one buffer still lets deflate find patterns across the batch. XOR framing provides no benefit here (random data XOR'd with different random data is still random), but the batching alone provides massive compression.

<details>
<summary><b>Run benchmarks yourself</b></summary>

```bash
rojo build bench.project.json -o Lync-bench.rbxl
```

Open in Studio, start a local server with one player. Results print to the server output.
</details>

---

## Wire Format (v0.6)

For anyone reading the source or building tooling, here's what goes on the wire.

**Packet frame:** `packetId(u8) + count(u16) + [payload × count]`. Multiple sends to the same packet ID in one frame share a single header. Different packet IDs get separate headers. All headers and payloads are concatenated into one buffer per channel.

**Query frame:** `packetId(u8) + correlationId(u16) + status(u8) + [payload if status=0]`. Status 0 = payload present. Status 1 = nil response. Query frames seal any open packet batch before writing.

**Transport:** One `RemoteEvent` (reliable) and one `UnreliableRemoteEvent` per Lync instance. Reliable channel applies XOR framing (current buffer XOR'd against previous). Unreliable channel sends raw. Both fire once per frame on Heartbeat.

**Breaking change from v0.5:** Query correlation IDs widened from u8 to u16 (query frame header is 4 bytes, was 3). Packet frames are unchanged.

---

## License

MIT
