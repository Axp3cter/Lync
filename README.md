<h1 align="center">Lync</h1>
<p align="center">Buffer networking for Roblox with delta compression, XOR framing, and built-in security.</p>
<p align="center">
  <a href="https://github.com/Axp3cter/Lync/releases/latest">Releases</a> ·
  <a href="#benchmarks">Benchmarks</a> ·
  <a href="#api">API</a> ·
  <a href="#limits">Limits</a>
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

| Scenario | Raw Kbps | Actual Kbps | FPS |
|:---------|--------:|-----------:|----:|
| Static booleans (1B payload) | 480 | 2.25 | 59.99 |
| Static entities (34B payload) | 16,320 | 2.51 | 60.00 |
| Moving entities (position changes) | 16,320 | 3.31 | 59.99 |
| Chaotic entities (all fields random) | 16,320 | 4.66 | 60.01 |

Entity struct: 2× vec3 + 2× f32 + bool + u8 = 34 bytes.

## API

### Packets

```luau
local Packet = Lync.definePacket("Name", {
    value      = codec,              -- required
    unreliable = true,               -- default false, cannot use with delta codecs
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

Request-reply built on RemoteEvents. Returns `nil` on timeout or handler error.

```luau
local GetStats = Lync.defineQuery("GetStats", {
    request  = Lync.u32,
    response = Lync.struct({ kills = Lync.u32, deaths = Lync.u32 }),
    timeout  = 5,
    rateLimit = { maxPerSecond = 10 },
    validate  = function(data, player) return data > 0, "invalid" end,
})

-- Server
GetStats:listen(function(id, player) return fetchStats(id) end)

-- Client
local stats = GetStats:invoke(localPlayer.UserId)
```

### Namespaces

Group packets and queries under a shared prefix. Supports scoped middleware that only fires for that namespace.

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

Combat.Hit:sendTo(data, player)
Combat.GetStats:invoke(playerId)

Combat:listenAll(function(name, data, sender) end)   -- all packets in namespace
Combat:onSend(function(data, name, player) return data end)
Combat:onReceive(function(data, name, player) return data end)
Combat:disconnectAll()                                -- listeners only
Combat:destroy()                                      -- listeners + middleware
Combat:packetNames()                                  -- { "Death", "Hit" }
Combat:queryNames()                                   -- { "GetStats" }
```

### Types

**Primitives** — `u8` `u16` `u32` `i8` `i16` `i32` `f16` `f32` `f64` `bool`

**Complex**

| Type | Bytes | Type | Bytes |
|:-----|------:|:-----|------:|
| `string` | varint + N | `color3` | 3 |
| `vec2` | 8 | `inst` | 2 |
| `vec3` | 12 | `buff` | varint + N |
| `cframe` | 24 | | |

**Composites**

```luau
Lync.struct({ key = codec })         -- bools packed into bitfields
Lync.array(codec)                    -- varint length prefix
Lync.map(keyCodec, valueCodec)       -- varint count
Lync.optional(codec)                 -- 1 byte flag + value
Lync.tuple(codec1, codec2)           -- positional, ordered
```

**Delta** — reliable only, only changed data is sent after the first frame

```luau
Lync.deltaStruct({ key = codec })    -- dirty fields only
Lync.deltaArray(codec)               -- dirty elements only
```

**Specialized**

```luau
Lync.enum("idle", "walking", "running")          -- u8 index, up to 256 variants
Lync.quantizedFloat(min, max, precision)          -- fixed-point, auto-selects width
Lync.quantizedVec3(min, max, precision)           -- 3× quantized float
Lync.bitfield({                                   -- sub-byte packing, 1–32 bits
    alive = { type = "bool" },
    level = { type = "uint", width = 5 },
    delta = { type = "int",  width = 4 },
})
Lync.tagged("kind", { move = moveCodec, chat = chatCodec })
Lync.nothing                                      -- zero bytes, reads nil
Lync.unknown                                      -- bypasses serialization
Lync.auto                                         -- self-describing tag + value
```

### Groups

Named player sets for targeted sends. Auto-cleaned on `PlayerRemoving`.

```luau
Lync.createGroup("lobby")
Lync.addToGroup("lobby", player)       -- returns true/false
Lync.removeFromGroup("lobby", player)  -- returns true/false
Lync.hasInGroup("lobby", player)
Lync.groupCount("lobby")
Lync.getGroupSet("lobby")             -- { [Player]: true }
Lync.forEachInGroup("lobby", fn)
Lync.destroyGroup("lobby")

Hit:sendToGroup(data, "lobby")
```

### Middleware

Intercept packets globally. Return `nil` to drop. Handlers chain in order.

```luau
local remove = Lync.onSend(function(data, name, player) return data end)
Lync.onReceive(function(data, name, player) return data end)
Lync.onDrop(function(player, reason, name, data) end)   -- "nan" | "rate" | "validate"
remove()
```

### Configuration

Call before `start()`.

```luau
Lync.setChannelMaxSize(524288)     -- default 256 KB, range 4 KB – 1 MB
Lync.setValidationDepth(24)        -- default 16, range 4 – 32
Lync.setPoolSize(32)               -- default 16, range 2 – 128
```

```luau
Lync.version                       -- "0.6.0-alpha"
Lync.queryPendingCount()           -- in-flight queries
```

## Limits

| Constraint | Default | Configurable | Notes |
|:-----------|--------:|:-------------|:------|
| Packet types | 255 | No | IDs are u8 on the wire. Each query uses 2 IDs. |
| Buffer per channel / frame | 256 KB | `setChannelMaxSize` | One buffer per player per channel. |
| Concurrent queries | 65,536 | No | Correlation IDs are u16. Freed on response or timeout. |
| NaN/inf scan depth | 16 | `setValidationDepth` | Tables deeper than this are rejected. |
| Channel pool | 16 | `setPoolSize` | Idle objects kept in memory. Excess is GC'd. |
| Namespaces | 64 | No | |
| Delta + unreliable | — | No | Delta codecs error if combined with `unreliable = true`. |

## License

MIT
