<p align="center">
  <h1 align="center">Lync</h1>
  <p align="center">
    Binary networking for Roblox.<br>
    Packets are batched, delta-encoded, XOR-framed, and sent as a single RemoteEvent per frame.
  </p>
</p>

<br>

## Installation

Place `Lync` in `ReplicatedStorage`. Define all packets before calling `start()`.

```luau
local Lync = require(ReplicatedStorage.Lync)

-- definitions

Lync.start()
```

<br>

## Packets

Define once in a shared module. The API splits by context automatically.

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

<br>

## Queries

Request-reply over RemoteEvents. No RemoteFunctions.

```luau
local GetInventory = Lync.defineQuery("GetInventory", {
    request  = Lync.u32,
    response = Lync.array(Lync.struct({
        itemId = Lync.u32,
        count  = Lync.u16,
    })),
    timeout = 5,
})
```

<details>
<summary><b>Server</b></summary>

```luau
GetInventory:listen(function(playerId, player)
    return fetchInventory(playerId)
end)
```
</details>

<details>
<summary><b>Client</b></summary>

```luau
local items = GetInventory:invoke(localPlayer.UserId)
-- yields, returns nil on timeout
```
</details>

<br>

## Types

### Primitives

| Type   | Bytes | Range                          |
| :----- | ----: | :----------------------------- |
| `u8`   |     1 | 0 – 255                        |
| `u16`  |     2 | 0 – 65,535                     |
| `u32`  |     4 | 0 – 4,294,967,295              |
| `i8`   |     1 | -128 – 127                     |
| `i16`  |     2 | -32,768 – 32,767               |
| `i32`  |     4 | -2,147,483,648 – 2,147,483,647 |
| `f16`  |     2 | ±65,504 (~3 digits)            |
| `f32`  |     4 | IEEE 754 single                |
| `f64`  |     8 | IEEE 754 double                |
| `bool` |     1 | true / false                   |

### Complex

| Type     |      Bytes | Description                  |
| :------- | ---------: | :--------------------------- |
| `string` | varint + N | UTF-8 string                 |
| `vec2`   |          8 | Vector2                      |
| `vec3`   |         12 | Vector3                      |
| `cframe` |         24 | CFrame (position + rotation) |
| `color3` |          3 | Color3 (0–255 per channel)   |
| `inst`   |          2 | Instance reference           |
| `buff`   | varint + N | Raw buffer                   |

### Composites

```luau
Lync.struct({ key = codec, ... })        -- named fields, bools packed
Lync.array(codec)                        -- variable-length list
Lync.map(keyCodec, valueCodec)           -- key-value pairs
Lync.optional(codec)                     -- nil flag + value
Lync.tuple(codec1, codec2, ...)          -- positional, ordered
```

### Delta

Only changed data is sent between frames. Requires reliable delivery.

```luau
Lync.deltaStruct({ key = codec, ... })   -- dirty fields only
Lync.deltaArray(codec)                   -- dirty elements only
```

### Specialized

```luau
Lync.enum("idle", "walking", "running")
Lync.quantizedFloat(min, max, precision)
Lync.quantizedVec3(min, max, precision)
Lync.bitfield({ alive = { type = "bool" }, level = { type = "uint", width = 5 } })
Lync.tagged("kind", { move = moveCodec, chat = chatCodec })
```

### Special

| Type      | Description                                   |
| :-------- | :-------------------------------------------- |
| `nothing` | Zero bytes, reads nil                         |
| `unknown` | Bypasses binary encoding, uses Roblox sidecar |
| `auto`    | Self-describing tag + value                   |

<br>

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

| Option       | Description                                                |
| :----------- | :--------------------------------------------------------- |
| `value`      | Required. Codec for the payload.                           |
| `unreliable` | Use UnreliableRemoteEvent. Default `false`.                |
| `rateLimit`  | Token bucket. `burstAllowance` defaults to `maxPerSecond`. |
| `validate`   | Server-only. Return `false, "reason"` to drop.             |

NaN/inf scanning, depth limiting, and rate limiting run on all incoming packets automatically.

<br>

## Groups

Named player sets for targeted sends. Players are auto-removed on `PlayerRemoving`.

```luau
Lync.createGroup("lobby")
Lync.addToGroup("lobby", player)
Lync.removeFromGroup("lobby", player)
Lync.hasInGroup("lobby", player)
Lync.getGroupSet("lobby")
Lync.forEachInGroup("lobby", fn)
Lync.destroyGroup("lobby")
```

<br>

## Middleware

Intercept packets globally. Return `nil` to cancel. Handlers chain in registration order.

```luau
local remove = Lync.onSend(function(data, name, player)
    return data
end)

Lync.onReceive(function(data, name, player)
    return data
end)

remove()
```

<br>

## Drop Handler

Called when an incoming packet is rejected by the gate.

```luau
Lync.onDrop(function(player, reason, name, data)
    -- "nan" | "rate" | "validate" | custom string
end)
```

<br>

## Benchmarks

1000 packets/frame to one player, 10 seconds per test, 60 FPS. Entity struct is 34 bytes (2× vec3, 2× f32, bool, u8).

| Scenario | What changes | Raw Kbps | Actual Kbps | Reduction |
| :------- | :----------- | -------: | ----------: | --------: |
| Static booleans | Nothing | 480 | 2.33 | 99.5% |
| Static entities | Nothing | 16,320 | 2.58 | 99.98% |
| Moving entities | Position only | 16,320 | 3.12 | 99.98% |
| Chaotic entities | Every field, random | 16,320 | 4.74 | 99.97% |

All tests held 60 FPS. Roblox handles buffer compression transparently via deflate.

To run: `rojo build bench.project.json -o Lync-bench.rbxl`, open in Studio, start a local server with one player.

<br>

## How It Works

```
write → batch → xor → fire → [roblox compression] → unxor → read → gate → signal
```

XOR transforms unchanged bytes to zeros. Roblox compresses the buffer transparently before sending. Static data costs near-zero bandwidth. Changing data compresses proportionally to how much actually changed.
