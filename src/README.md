<h1 align="center">Lync</h1>
<p align="center">Buffer networking for Roblox with delta compression and built-in security.</p>
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

1,000 packets/frame · 10 seconds · one player

| Scenario | Raw Kbps | Actual Kbps | FPS |
|:---------|--------:|-----------:|----:|
| Static booleans | 480 | 2.25 | 59.99 |
| Static entities | 16,320 | 2.51 | 60.00 |
| Moving entities | 16,320 | 3.31 | 59.99 |
| Chaotic entities | 16,320 | 4.66 | 60.01 |

## API

### Packets

```luau
local Packet = Lync.definePacket("Name", {
    value      = codec,
    unreliable = true,
    rateLimit  = { maxPerSecond = 30 },
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

Returns `nil` on timeout.

```luau
local GetStats = Lync.defineQuery("GetStats", {
    request  = Lync.u32,
    response = Lync.struct({ kills = Lync.u32, deaths = Lync.u32 }),
    timeout  = 5,
})

-- Server
GetStats:listen(function(id, player) return fetchStats(id) end)

-- Client
local stats = GetStats:invoke(localPlayer.UserId)
```

### Namespaces

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

`u8` `u16` `u32` `i8` `i16` `i32` `f16` `f32` `f64` `bool`

`string` · `vec2` · `vec3` · `cframe` · `color3` · `inst` · `buff`

```luau
Lync.struct({ key = codec })
Lync.array(codec)
Lync.map(keyCodec, valueCodec)
Lync.optional(codec)
Lync.tuple(codec1, codec2)
Lync.deltaStruct({ key = codec })   -- reliable only, dirty fields
Lync.deltaArray(codec)              -- reliable only, dirty elements
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

Auto-cleaned on `PlayerRemoving`.

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

Return `nil` to drop.

```luau
local remove = Lync.onSend(function(data, name, player) return data end)
Lync.onReceive(function(data, name, player) return data end)
Lync.onDrop(function(player, reason, name, data) end)
remove()
```

</details>

<details>
<summary><b>Configuration</b></summary>

```luau
Lync.setChannelMaxSize(524288)    -- default 256 KB
Lync.setValidationDepth(24)       -- default 16
Lync.setPoolSize(32)              -- default 16
Lync.queryPendingCount()
```

</details>

<details>
<summary><b>Limits</b></summary>

| | Max |
|:--|--:|
| Packet types | 255 |
| Buffer / channel / frame | 256 KB |
| Concurrent queries | 65,536 |
| NaN scan depth | 16 |
| Namespaces | 64 |

</details>

## License

MIT
