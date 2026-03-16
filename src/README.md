<h1 align="center">Lync</h1>
<p align="center">Buffer networking for Roblox — batched, delta-encoded, XOR-framed.</p>
<p align="center">
  <a href="https://github.com/Axp3cter/Lync/releases/latest">Releases</a> ·
  <a href="#benchmarks">Benchmarks</a> ·
  <a href="#api">API</a>
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

1,000 packets/frame · 10 seconds · local server · one player

| Scenario | Raw Kbps | Actual Kbps | FPS |
|:---------|--------:|-----------:|----:|
| Static booleans (1 byte) | 480 | 2.25 | 59.99 |
| Static entities (34 bytes) | 16,320 | 2.51 | 60.00 |
| Moving entities (position changes) | 16,320 | 3.31 | 59.99 |
| Chaotic entities (all random) | 16,320 | 4.66 | 60.01 |

Entity struct: 2× vec3, 2× f32, bool, u8. XOR framing + Roblox deflate compresses unchanged data to near-zero.

## API

### Packets

```luau
local Packet = Lync.definePacket("Name", {
    value      = codec,
    unreliable = true,                          -- default false
    rateLimit  = { maxPerSecond = 30 },         -- server-side token bucket
    validate   = function(data, player)         -- server-side, return false to drop
        return true
    end,
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

Request-reply over RemoteEvents. Returns `nil` on timeout.

```luau
local GetStats = Lync.defineQuery("GetStats", {
    request  = Lync.u32,
    response = Lync.struct({ kills = Lync.u32, deaths = Lync.u32 }),
    timeout  = 5,
})

-- Server: listen and return
GetStats:listen(function(id, player) return fetchStats(id) end)

-- Client: invoke and await
local stats = GetStats:invoke(localPlayer.UserId)
```

### Namespaces

Group packets/queries. Auto-prefixes names. Scoped middleware.

```luau
local Combat = Lync.defineNamespace("Combat", {
    packets = {
        Hit   = { value = Lync.struct({ targetId = Lync.u32, damage = Lync.f32 }) },
        Death = { value = Lync.struct({ victimId = Lync.u32 }) },
    },
})

Combat.Hit:sendTo(data, player)
Combat:listenAll(function(name, data, sender) end)
Combat:onSend(function(data, name, player) return data end)
Combat:destroy()
```

<details>
<summary><b>Types</b></summary>

### Primitives

`u8` `u16` `u32` `i8` `i16` `i32` `f16` `f32` `f64` `bool`

### Complex

`string` · `vec2` (8B) · `vec3` (12B) · `cframe` (24B) · `color3` (3B) · `inst` (2B) · `buff`

### Composites

```luau
Lync.struct({ key = codec })        -- bools packed into bitfields
Lync.array(codec)
Lync.map(keyCodec, valueCodec)
Lync.optional(codec)
Lync.tuple(codec1, codec2)
```

### Delta (reliable only)

```luau
Lync.deltaStruct({ key = codec })   -- only dirty fields
Lync.deltaArray(codec)              -- only dirty elements
```

### Specialized

```luau
Lync.enum("idle", "walking", "running")
Lync.quantizedFloat(min, max, precision)
Lync.quantizedVec3(min, max, precision)
Lync.bitfield({ alive = { type = "bool" }, level = { type = "uint", width = 5 } })
Lync.tagged("kind", { move = moveCodec, chat = chatCodec })
Lync.nothing    Lync.unknown    Lync.auto
```

</details>

<details>
<summary><b>Groups</b></summary>

Named player sets. Auto-cleaned on `PlayerRemoving`.

```luau
Lync.createGroup("lobby")
Lync.addToGroup("lobby", player)
Lync.removeFromGroup("lobby", player)
Lync.destroyGroup("lobby")

Hit:sendToGroup(data, "lobby")
```

</details>

<details>
<summary><b>Middleware</b></summary>

Chain handlers on send/receive. Return `nil` to drop.

```luau
local remove = Lync.onSend(function(data, name, player) return data end)
Lync.onReceive(function(data, name, player) return data end)
Lync.onDrop(function(player, reason, name, data) end)
remove()
```

</details>

<details>
<summary><b>Configuration</b></summary>

Call before `start()`.

```luau
Lync.setChannelMaxSize(524288)    -- default 256 KB, range 4 KB – 1 MB
Lync.setValidationDepth(24)       -- default 16, range 4 – 32
Lync.setPoolSize(32)              -- default 16, range 2 – 128
```

```luau
Lync.version                      -- "0.6.0-alpha"
Lync.queryPendingCount()          -- in-flight queries
```

</details>

<details>
<summary><b>Limits</b></summary>

| Constraint | Value |
|:--|--:|
| Packet types | 255 |
| Buffer per channel/frame | 256 KB |
| Concurrent queries | 65,536 |
| NaN scan depth | 16 |
| Namespaces | 64 |

</details>

## License

MIT
