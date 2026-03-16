<h1 align="center">Lync</h1>
<p align="center">Buffer-based networking for Roblox with delta compression, XOR framing, and built-in security.</p>
<p align="center">
  <a href="https://github.com/Axp3cter/Lync/releases/latest">Releases</a> · <a href="#benchmarks">Benchmarks</a>
</p>

---

## Install

```toml
# wally.toml
[dependencies]
Lync = "axpecter/lync@0.6.0-alpha"
```

Or grab the `.rbxm` from the [latest release](https://github.com/Axp3cter/Lync/releases/latest). Place in `ReplicatedStorage`.

---

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

-- Server
Hit:sendTo(data, player)
Hit:sendToAll(data)

-- Client
Hit:send(data)

-- Both
Hit:listen(function(data, sender) end)
```

All definitions must happen before `Lync.start()`.

---

## Packets

```luau
local Packet = Lync.definePacket("Name", {
    value      = codec,            -- required
    unreliable = true,             -- default false
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
| `sendToGroup(data, groupName)` | | |

---

## Queries

Request-reply over RemoteEvents. No RemoteFunctions. Returns `nil` on timeout.

```luau
local GetStats = Lync.defineQuery("GetStats", {
    request  = Lync.u32,
    response = Lync.struct({ kills = Lync.u32, deaths = Lync.u32 }),
    timeout  = 5,
})

-- Server
GetStats:listen(function(playerId, player)
    return fetchStats(playerId)
end)

-- Client
local stats = GetStats:invoke(localPlayer.UserId)
```

---

## Namespaces

Group packets and queries. Names auto-prefix (`"Combat.Hit"`). Scoped middleware only fires for that namespace.

```luau
local Combat = Lync.defineNamespace("Combat", {
    packets = {
        Hit  = { value = Lync.struct({ targetId = Lync.u32, damage = Lync.f32 }) },
        Death = { value = Lync.struct({ victimId = Lync.u32 }) },
    },
    queries = {
        GetStats = { request = Lync.u32, response = Lync.struct({ kills = Lync.u32 }) },
    },
})

Combat.Hit:sendTo(data, player)
Combat.GetStats:invoke(playerId)

Combat:listenAll(function(name, data, sender) end)  -- all packets in namespace
Combat:onSend(function(data, name, player) return data end)  -- scoped middleware
Combat:destroy()  -- cleanup listeners + middleware
```

---

## Types

### Primitives

| Type | Bytes | Type | Bytes | Type | Bytes |
|:-----|------:|:-----|------:|:-----|------:|
| `u8` | 1 | `i8` | 1 | `f16` | 2 |
| `u16` | 2 | `i16` | 2 | `f32` | 4 |
| `u32` | 4 | `i32` | 4 | `f64` | 8 |
| `bool` | 1 | | | | |

### Complex

| Type | Bytes | Type | Bytes |
|:-----|------:|:-----|------:|
| `string` | varint + N | `color3` | 3 |
| `vec2` | 8 | `inst` | 2 |
| `vec3` | 12 | `buff` | varint + N |
| `cframe` | 24 | | |

### Composites

```luau
Lync.struct({ key = codec, ... })      -- bools auto-packed into bitfields
Lync.array(codec)                      -- varint length prefix
Lync.map(keyCodec, valueCodec)
Lync.optional(codec)                   -- 1 byte flag + value
Lync.tuple(codec1, codec2, ...)
```

### Delta (reliable only)

```luau
Lync.deltaStruct({ key = codec, ... })   -- only dirty fields sent
Lync.deltaArray(codec)                   -- only dirty elements sent
```

### Specialized

```luau
Lync.enum("idle", "walking", "running")
Lync.quantizedFloat(min, max, precision)
Lync.quantizedVec3(min, max, precision)
Lync.bitfield({ alive = { type = "bool" }, level = { type = "uint", width = 5 } })
Lync.tagged("kind", { move = moveCodec, chat = chatCodec })
Lync.nothing        -- zero bytes
Lync.unknown        -- bypasses serialization, uses Roblox sidecar
Lync.auto           -- self-describing tag + value
```

---

## Groups

```luau
Lync.createGroup("lobby")
Lync.addToGroup("lobby", player)
Lync.removeFromGroup("lobby", player)
Lync.destroyGroup("lobby")

Hit:sendToGroup(data, "lobby")
```

Players auto-removed on `PlayerRemoving`.

---

## Middleware

```luau
local remove = Lync.onSend(function(data, name, player)
    return data   -- return nil to drop
end)

Lync.onReceive(function(data, name, player) return data end)

Lync.onDrop(function(player, reason, name, data) end)
-- reason: "nan" | "rate" | "validate" | custom string

remove()
```

---

## Benchmarks

1,000 packets/frame, 10 seconds, local server, one player.

| Scenario | Raw Kbps | Actual Kbps | FPS | Reduction |
|:---------|--------:|-----------:|----:|----------:|
| Static booleans (1 byte) | 480 | 2.25 | 59.99 | 99.5% |
| Static entities (34 bytes) | 16,320 | 2.51 | 60.00 | 99.98% |
| Moving entities (position changes) | 16,320 | 3.31 | 59.99 | 99.98% |
| Chaotic entities (all random) | 16,320 | 4.66 | 60.01 | 99.97% |

---

## Limits

| | Default | Configurable |
|:--|------:|:--|
| Packet types | 255 | No |
| Buffer per channel/frame | 256 KB | `Lync.setChannelMaxSize(n)` |
| Concurrent queries | 65,536 | No |
| NaN scan depth | 16 | `Lync.setValidationDepth(n)` |
| Channel pool size | 16 | `Lync.setPoolSize(n)` |
| Namespaces | 64 | No |

```luau
Lync.version              -- "0.6.0-alpha"
Lync.queryPendingCount()  -- in-flight queries
```

---

## License

MIT
