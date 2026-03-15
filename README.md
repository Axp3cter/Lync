# Lync

Binary networking for Roblox. Packets are batched per player, delta-encoded, XOR-compressed, and sent as a single RemoteEvent per frame.

&nbsp;

---

&nbsp;

## Installation

Place `Lync` in `ReplicatedStorage`. Define all packets before calling `start()`.

```luau
local Lync = require(ReplicatedStorage.Lync)

-- definitions

Lync.start()
```

&nbsp;

---

&nbsp;

## Packets

```luau
local Hit = Lync.definePacket("Hit", {
    value = Lync.struct({
        targetId = Lync.u32,
        amount   = Lync.f32,
        crit     = Lync.bool,
    }),
})
```

&nbsp;

**Server**

```luau
Hit:sendTo(data, player)
Hit:sendToAll(data)
Hit:sendToAllExcept(data, player)
Hit:sendToList(data, players)
Hit:sendToGroup(data, "lobby")
```

&nbsp;

**Client**

```luau
Hit:send(data)
```

&nbsp;

**Listening**

```luau
Hit:listen(function(data, sender) end)
Hit:once(function(data, sender) end)
Hit:wait()
Hit:disconnectAll()
```

> `sender` is the `Player` on the server, `nil` on the client.

&nbsp;

---

&nbsp;

## Queries

Request-reply over RemoteEvents.

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

&nbsp;

**Server**

```luau
GetInventory:listen(function(playerId, player)
    return fetchInventory(playerId)
end)
```

&nbsp;

**Client**

```luau
local items = GetInventory:invoke(localPlayer.UserId)
```

> Yields. Returns `nil` on timeout.

&nbsp;

---

&nbsp;

## Types

&nbsp;

### Primitives

| Type   | Bytes | Range                          |
| ------ | ----: | ------------------------------ |
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

&nbsp;

### Complex

| Type     | Bytes      | Description                  |
| -------- | ---------: | ---------------------------- |
| `string` | varint + N | UTF-8 string                 |
| `vec2`   |          8 | Vector2                      |
| `vec3`   |         12 | Vector3                      |
| `cframe` |         24 | CFrame (position + rotation) |
| `color3` |          3 | Color3 (0–255 per channel)   |
| `inst`   |          2 | Instance reference           |
| `buff`   | varint + N | Raw buffer                   |

&nbsp;

### Composites

```luau
Lync.struct({ key = codec, ... })
Lync.array(codec)
Lync.map(keyCodec, valueCodec)
Lync.optional(codec)
Lync.tuple(codec1, codec2, ...)
```

&nbsp;

### Delta

Only changed data is sent between frames.

```luau
Lync.deltaStruct({ key = codec, ... })
Lync.deltaArray(codec)
```

> Requires reliable delivery. Errors if paired with `unreliable = true`.

&nbsp;

### Specialized

```luau
Lync.enum("idle", "walking", "running")
Lync.quantizedFloat(min, max, precision)
Lync.quantizedVec3(min, max, precision)
Lync.bitfield({ alive = { type = "bool" }, level = { type = "uint", width = 5 } })
Lync.tagged("kind", { move = moveCodec, chat = chatCodec })
```

&nbsp;

### Special

| Type      | Description                                  |
| --------- | -------------------------------------------- |
| `nothing` | Zero bytes, reads nil                        |
| `unknown` | Bypasses binary encoding, uses Roblox sidecar |
| `auto`    | Self-describing tag + value                  |

&nbsp;

---

&nbsp;

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
| ------------ | ---------------------------------------------------------- |
| `value`      | Required. Codec for the payload.                           |
| `unreliable` | Use UnreliableRemoteEvent. Default `false`.                |
| `rateLimit`  | Token bucket. `burstAllowance` defaults to `maxPerSecond`. |
| `validate`   | Server-only. Return `false, "reason"` to drop.             |

> NaN/inf scanning, depth limiting, and rate limiting run on all incoming packets automatically.

&nbsp;

---

&nbsp;

## Groups

```luau
Lync.createGroup("lobby")
Lync.addToGroup("lobby", player)
Lync.removeFromGroup("lobby", player)
Lync.hasInGroup("lobby", player)
Lync.getGroupSet("lobby")
Lync.forEachInGroup("lobby", fn)
Lync.destroyGroup("lobby")
```

> Players are auto-removed on `PlayerRemoving`.

&nbsp;

---

&nbsp;

## Middleware

```luau
local remove = Lync.onSend(function(data, name, player)
    return data
end)

Lync.onReceive(function(data, name, player)
    return data
end)

remove()
```

> Return `nil` to cancel. Handlers chain in registration order.

&nbsp;

---

&nbsp;

## Drop Handler

```luau
Lync.onDrop(function(player, reason, name, data)
    -- "nan" | "rate" | "validate" | custom string
end)
```

&nbsp;

---

&nbsp;

## How It Works

```
write → batch → xor → compress → fire → decompress → unxor → read → gate → signal
```

Static data costs near-zero bandwidth. Changing data compresses proportionally to how much actually changed.
