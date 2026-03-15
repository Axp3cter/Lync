# Lync

**Binary networking for Roblox.**  
Batches, compresses, and delta-encodes packets over RemoteEvents.

<br>

## Installation

Place `Lync` in `ReplicatedStorage`. Define all packets before calling `start()`.

```luau
local Lync = require(ReplicatedStorage.Lync)

-- definitions go here

Lync.start()
```

<br>

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

**Server:**

```luau
Hit:sendTo(data, player)
Hit:sendToAll(data)
Hit:sendToAllExcept(data, player)
Hit:sendToList(data, players)
Hit:sendToGroup(data, "lobby")
```

**Client:**

```luau
Hit:send(data)
```

**Listening:**

```luau
Hit:listen(function(data, sender) end)   -- sender is Player on server, nil on client
Hit:once(function(data, sender) end)
Hit:wait()
Hit:disconnectAll()
```

<br>

## Queries

Request-reply over RemoteEvents.

```luau
local GetInventory = Lync.defineQuery("GetInventory", {
    request  = Lync.u32,
    response = Lync.array(Lync.struct({ itemId = Lync.u32, count = Lync.u16 })),
    timeout  = 5,
})
```

```luau
-- server
GetInventory:listen(function(playerId, player)
    return fetchInventory(playerId)
end)

-- client (yields, returns nil on timeout)
local items = GetInventory:invoke(localPlayer.UserId)
```

<br>

## Types

### Primitives

| Type | Bytes | Range |
|------|------:|-------|
| `u8` | 1 | 0 – 255 |
| `u16` | 2 | 0 – 65,535 |
| `u32` | 4 | 0 – 4,294,967,295 |
| `i8` | 1 | -128 – 127 |
| `i16` | 2 | -32,768 – 32,767 |
| `i32` | 4 | -2,147,483,648 – 2,147,483,647 |
| `f16` | 2 | ±65,504 (~3 digits) |
| `f32` | 4 | IEEE 754 single |
| `f64` | 8 | IEEE 754 double |
| `bool` | 1 | true / false |

### Complex

| Type | Bytes | Description |
|------|------:|-------------|
| `string` | varint + N | UTF-8 string |
| `vec2` | 8 | Vector2 |
| `vec3` | 12 | Vector3 |
| `cframe` | 24 | CFrame (position + axis-angle) |
| `color3` | 3 | Color3 (0–255 per channel) |
| `inst` | 2 | Instance reference |
| `buff` | varint + N | Raw buffer |

### Composites

```luau
Lync.struct({ key = codec, ... })       -- named fields, bools auto-packed
Lync.array(codec)                       -- variable-length list
Lync.map(keyCodec, valueCodec)          -- key-value pairs
Lync.optional(codec)                    -- nil flag + value
Lync.tuple(codec1, codec2, ...)         -- positional, ordered
```

### Delta

Only sends what changed between frames.

```luau
Lync.deltaStruct({ key = codec, ... })  -- dirty fields only
Lync.deltaArray(codec)                  -- dirty elements only
```

> Requires reliable delivery. Errors if paired with `unreliable = true`.

### Specialized

```luau
Lync.enum("idle", "walking", "running")                                              -- 1 byte
Lync.quantizedFloat(min, max, precision)                                             -- 1–4 bytes
Lync.quantizedVec3(min, max, precision)                                              -- 3–12 bytes
Lync.bitfield({ alive = { type = "bool" }, level = { type = "uint", width = 5 } })  -- bit-packed
Lync.tagged("kind", { move = moveCodec, chat = chatCodec })                          -- discriminated union
```

### Special

| Type | Description |
|------|-------------|
| `nothing` | Zero bytes, reads nil |
| `unknown` | Bypasses binary encoding, passes through Roblox sidecar |
| `auto` | Self-describing tag + value |

<br>

## Options

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

| Option | Description |
|--------|-------------|
| `value` | **Required.** Codec for the payload. |
| `unreliable` | Use UnreliableRemoteEvent. Default `false`. |
| `rateLimit` | Token bucket. `burstAllowance` defaults to `maxPerSecond`. |
| `validate` | Server-only. Runs after deserialization. Return `false, "reason"` to drop. |

NaN/inf scanning, depth limiting, and rate limiting run automatically on all incoming packets.

<br>

## Groups

Named player sets for targeted sends.

```luau
Lync.createGroup("lobby")
Lync.addToGroup("lobby", player)
Lync.removeFromGroup("lobby", player)
Lync.hasInGroup("lobby", player)
Lync.getGroupSet("lobby")
Lync.forEachInGroup("lobby", fn)
Lync.destroyGroup("lobby")
```

Players are auto-removed on `PlayerRemoving`.

<br>

## Middleware

```luau
local remove = Lync.onSend(function(data, name, player)
    return data    -- nil cancels
end)

Lync.onReceive(function(data, name, player)
    return data
end)

remove()
```

<br>

## Drop Handler

```luau
Lync.onDrop(function(player, reason, name, data)
    -- "nan" | "rate" | "validate" | custom string
end)
```

<br>

## How It Works

Every `send` call writes binary data into a per-player buffer. On `Heartbeat`, each buffer is sealed into a batch, XOR'd against the previous frame, LZSS compressed, and sent as a single RemoteEvent. The receiver reverses the pipeline.

```
write → batch → xor → compress → fire → decompress → unxor → read → gate → signal
```

Static data costs near-zero bandwidth. Changing data compresses proportionally to how much actually changed.

<br>

## License

MIT
