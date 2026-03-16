<h1 align="center">Lync</h1>
<p align="center">Buffer networking for Roblox with delta compression, XOR framing, and built-in security.</p>
<p align="center">
  <a href="https://github.com/Axp3cter/Lync/releases/latest">Releases</a> ·
  <a href="#benchmarks">Benchmarks</a> ·
  <a href="#api">API</a> ·
  <a href="#limits--configuration">Limits</a>
</p>

## Install

```toml
[dependencies]
Lync = "axpecter/lync@0.6.0-alpha"
```

Or grab the `.rbxm` from [releases](https://github.com/Axp3cter/Lync/releases/latest). Place in `ReplicatedStorage`.

## Quick Start

```luau
local Lync = require(ReplicatedStorage.Lync)

local Hit = Lync.definePacket("Hit", {
    value = Lync.struct({
        targetId = Lync.u32,
        damage   = Lync.f32,
        crit     = Lync.bool,
    }),
})

Lync.start()
```

```luau
-- Server
Hit:sendTo(data, player)
Hit:sendToAll(data)

-- Client
Hit:send(data)

-- Both
Hit:listen(function(data, sender) end)
```

> [!IMPORTANT]
> All definitions must happen before `Lync.start()`.

## Benchmarks

1,000 packets/frame · 10 seconds · one player

| Scenario | Without Lync | With Lync | FPS |
|:---------|------------:|---------:|----:|
| Static booleans (1B) | 480 Kbps | **2.25 Kbps** | 59.99 |
| Static entities (34B) | 16,320 Kbps | **2.51 Kbps** | 60.00 |
| Moving entities | 16,320 Kbps | **3.31 Kbps** | 59.99 |
| Chaotic entities | 16,320 Kbps | **4.66 Kbps** | 60.01 |

## API

### Packets

```luau
Lync.definePacket("Name", {
    value      = codec,              -- required
    unreliable = true,               -- default false; cannot use with delta codecs
    rateLimit  = { maxPerSecond = 30, burstAllowance = 5 },
    validate   = function(data, player) return true end,
})
```

| Server | Client | Both |
|:-------|:-------|:-----|
| `sendTo(data, player)` | `send(data)` | `listen(fn)` |
| `sendToAll(data)` | | `once(fn)` |
| `sendToAllExcept(data, except)` | | `wait()` |
| `sendToList(data, players)` | | `disconnectAll()` |
| `sendToGroup(data, group)` | | |

### Queries

Returns `nil` on timeout or handler error.

```luau
Lync.defineQuery("GetStats", {
    request  = Lync.u32,
    response = Lync.struct({ kills = Lync.u32, deaths = Lync.u32 }),
    timeout  = 5,
    rateLimit = { maxPerSecond = 10 },
    validate  = function(data, player) return data > 0, "invalid" end,
})
```

```luau
-- Server
GetStats:listen(function(id, player) return fetchStats(id) end)

-- Client
local stats = GetStats:invoke(localPlayer.UserId)
```

### Namespaces

Group packets and queries under a shared prefix. Scoped middleware only fires for that namespace.

**Define:**
```luau
local Combat = Lync.defineNamespace("Combat", {
    packets = {
        Hit   = { value = Lync.struct({ targetId = Lync.u32, damage = Lync.f32 }) },
        Death = { value = Lync.struct({ victimId = Lync.u32 }) },
    },
    queries = {
        GetStats = { request = Lync.u32, response = Lync.struct({ kills = Lync.u32 }) },
    },
})
```

**Use:**
```luau
Combat.Hit:sendTo(data, player)
Combat.GetStats:invoke(playerId)
```

**Namespace methods:**

| Method | Description |
|:-------|:------------|
| `listenAll(fn)` | Listen to every packet. Callback receives `(name, data, sender)`. |
| `onSend(fn)` | Scoped send middleware. Returns remover. |
| `onReceive(fn)` | Scoped receive middleware. Returns remover. |
| `disconnectAll()` | Disconnects listeners created through `listenAll`. |
| `destroy()` | Disconnects listeners and removes scoped middleware. |
| `packetNames()` | Returns sorted list of packet names. |
| `queryNames()` | Returns sorted list of query names. |

---

### Types

| Primitives | | | | |
|:--|:--|:--|:--|:--|
| `u8` (1B) | `u16` (2B) | `u32` (4B) | `f16` (2B) | `bool` (1B) |
| `i8` (1B) | `i16` (2B) | `i32` (4B) | `f32` (4B) | `f64` (8B) |

| Complex | Bytes | | |
|:--------|------:|:--|--:|
| `string` | varint + N | `color3` | 3 |
| `vec2` | 8 | `inst` | 2 |
| `vec3` | 12 | `buff` | varint + N |
| `cframe` | 24 | | |

| Composites | | Delta *(reliable only)* | |
|:-----------|:--|:----------------------|:--|
| `struct({ key = codec })` | bools packed | `deltaStruct({ key = codec })` | dirty fields only |
| `array(codec)` | varint count | `deltaArray(codec)` | dirty elements only |
| `map(key, value)` | varint count | | |
| `optional(codec)` | 1B flag | | |
| `tuple(c1, c2, ...)` | ordered | | |

| Specialized | |
|:------------|:--|
| `enum("a", "b", "c")` | u8 index, up to 256 variants |
| `quantizedFloat(min, max, prec)` | fixed-point, auto-selects u8/u16/u32 |
| `quantizedVec3(min, max, prec)` | 3× quantized float |
| `bitfield({ k = spec })` | sub-byte packing, 1–32 bits total |
| `tagged(field, { k = codec })` | discriminated union, u8 tag |
| `nothing` | zero bytes |
| `unknown` | bypasses serialization, uses Roblox sidecar |
| `auto` | self-describing u8 tag + value |

---

### Groups

Named player sets for targeted sends. Auto-cleaned on `PlayerRemoving`.

| Method | Returns |
|:-------|:--------|
| `Lync.createGroup(name)` | |
| `Lync.addToGroup(name, player)` | `boolean` |
| `Lync.removeFromGroup(name, player)` | `boolean` |
| `Lync.hasInGroup(name, player)` | `boolean` |
| `Lync.groupCount(name)` | `number` |
| `Lync.getGroupSet(name)` | `{ [Player]: true }` |
| `Lync.forEachInGroup(name, fn)` | |
| `Lync.destroyGroup(name)` | |

```luau
Hit:sendToGroup(data, "lobby")
```

---

### Middleware

Intercept packets globally. Return `nil` to drop. Handlers chain in registration order.

| Method | Description |
|:-------|:------------|
| `Lync.onSend(fn)` | Intercept outgoing. Returns remover function. |
| `Lync.onReceive(fn)` | Intercept incoming. Returns remover function. |
| `Lync.onDrop(fn)` | Called on reject. Reason: `"nan"` `"rate"` `"validate"` or custom. |

## Limits & Configuration

| Constraint | Default | Configure | Notes |
|:-----------|--------:|:----------|:------|
| Packet types | 255 | — | u8 on the wire. Each query uses 2 IDs. |
| Buffer / channel / frame | 256 KB | `Lync.setChannelMaxSize(n)` | Range: 4 KB – 1 MB |
| Concurrent queries | 65,536 | — | u16 correlation IDs. Freed on response or timeout. |
| NaN/inf scan depth | 16 | `Lync.setValidationDepth(n)` | Range: 4 – 32 |
| Channel pool | 16 | `Lync.setPoolSize(n)` | Range: 2 – 128. Excess is GC'd. |
| Namespaces | 64 | — | |
| Delta + unreliable | — | — | Errors at define time if combined. |

> [!NOTE]
> Configuration functions must be called before `Lync.start()`.

```luau
Lync.version                    -- "0.6.0-alpha"
Lync.queryPendingCount()        -- in-flight queries
```

## License

MIT
