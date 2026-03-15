# Lync

**Binary networking for Roblox.**  
Batches, compresses, and delta-encodes packets over RemoteEvents.

<br>

## Installation

Drop the `Lync` folder into `ReplicatedStorage`.  
Call `start()` once on both server and client after all packets are defined.

```luau
local Lync = require(ReplicatedStorage.Lync)

-- Define all packets and queries here

Lync.start()
```

<br>

## Packets

Define a packet once in a shared module. The API splits by context automatically.

```luau
local Damage = Lync.definePacket("Damage", {
    value = Lync.struct({
        targetId = Lync.u32,
        amount   = Lync.f32,
        crit     = Lync.bool,
    }),
})
```

**Server — sending:**

```luau
Damage:sendTo(data, player)
Damage:sendToAll(data)
Damage:sendToAllExcept(data, excludedPlayer)
Damage:sendToList(data, { player1, player2 })
Damage:sendToGroup(data, "team_red")
```

**Client — sending:**

```luau
Damage:send(data)
```

**Listening (both):**

```luau
local connection = Damage:listen(function(data, sender)
    -- sender is the Player on server, nil on client
end)

Damage:once(function(data, sender) end)
Damage:wait()
Damage:disconnectAll()
```

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
    timeout = 5, -- seconds (default 5)
})
```

**Server — handler:**

```luau
GetInventory:listen(function(playerId, player)
    return fetchInventory(playerId)
end)
```

**Client — invoke:**

```luau
local items = GetInventory:invoke(localPlayer.UserId)
-- returns nil on timeout
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
| `f16` | 2 | ±65,504 (~3 decimal digits) |
| `f32` | 4 | IEEE 754 single |
| `f64` | 8 | IEEE 754 double |
| `bool` | 1 | true / false |

### Complex

| Type | Bytes | Description |
|------|------:|-------------|
| `string` | varint + N | UTF-8 string |
| `vec2` | 8 | Vector2 (2× f32) |
| `vec3` | 12 | Vector3 (3× f32) |
| `cframe` | 24 | CFrame (position + axis-angle) |
| `color3` | 3 | Color3 (RGB, 0–255 per channel) |
| `inst` | 2 | Instance reference (sidecar) |
| `buff` | varint + N | Raw buffer |

### Composites

```luau
Lync.struct({ key = codec, ... })       -- named fields, bools auto-packed
Lync.array(codec)                       -- variable-length list
Lync.map(keyCodec, valueCodec)          -- key-value pairs
Lync.optional(codec)                    -- 1 byte nil flag + value
Lync.tuple(codec1, codec2, ...)         -- positional, ordered
```

### Delta

Automatic frame-to-frame compression. Only changed data is sent.

```luau
Lync.deltaStruct({ key = codec, ... })  -- sends only dirty fields
Lync.deltaArray(codec)                  -- sends only dirty elements
```

> Delta codecs require reliable delivery. Pairing with `unreliable = true` throws an error.

### Specialized

```luau
Lync.enum("idle", "walking", "running")                                       -- 1 byte
Lync.quantizedFloat(min, max, precision)                                      -- 1–4 bytes
Lync.quantizedVec3(min, max, precision)                                       -- 3–12 bytes
Lync.bitfield({ alive = { type = "bool" }, level = { type = "uint", width = 5 } })  -- bit-packed
Lync.tagged("type", { move = moveCodec, chat = chatCodec })                   -- discriminated union
```

### Special

| Type | Description |
|------|-------------|
| `nothing` | Zero bytes on the wire, reads `nil` |
| `unknown` | Passes value through the Roblox remote sidecar (no binary encoding) |
| `auto` | Self-describing tag + value (flexible, larger wire size) |

<br>

## Packet Options

```luau
Lync.definePacket("Position", {
    value      = Lync.vec3,
    unreliable = true,
    rateLimit  = { maxPerSecond = 30, burstAllowance = 5 },
    validate   = function(data, player)
        if data.X ~= data.X then return false, "nan" end
        return true
    end,
})
```

| Option | Type | Description |
|--------|------|-------------|
| `value` | `Codec` | **Required.** The codec for the packet payload. |
| `unreliable` | `boolean?` | Use `UnreliableRemoteEvent`. Default `false`. |
| `rateLimit` | `{ maxPerSecond, burstAllowance? }` | Server-side token bucket. Drops excess packets. |
| `validate` | `(data, player) → (bool, string?)` | Server-side check after deserialization. |

**Rate limiting** uses a token bucket. `burstAllowance` is the bucket capacity (defaults to `maxPerSecond`). Tokens refill at `maxPerSecond` rate. Each packet costs 1 token. At 0 tokens, packets are dropped.

**Built-in security** runs automatically on all incoming packets — NaN/inf rejection, recursive depth limiting (max 8 levels), and rate limiting all execute before `validate`.

<br>

## Groups

Named player sets for targeted broadcasting.

```luau
Lync.createGroup("team_red")
Lync.addToGroup("team_red", player)         -- returns false if already in group
Lync.removeFromGroup("team_red", player)
Lync.hasInGroup("team_red", player)         -- boolean
Lync.getGroupSet("team_red")               -- { [Player]: true }
Lync.forEachInGroup("team_red", function(player) end)
Lync.destroyGroup("team_red")
```

Players are auto-removed from all groups on `PlayerRemoving`.

<br>

## Middleware

Intercept outgoing and incoming data globally.

```luau
local removeSend = Lync.onSend(function(data, packetName, player)
    return data   -- return nil to cancel the send
end)

local removeRecv = Lync.onReceive(function(data, packetName, player)
    return data   -- return nil to discard
end)

removeSend()      -- disconnect the handler
```

Handlers chain in registration order. If any handler returns `nil`, the chain stops.

<br>

## Drop Handler

Called when an incoming packet is rejected.

```luau
Lync.onDrop(function(player, reason, packetName, data)
    -- reason: "nan" | "rate" | "validate" | custom string from validate()
end)
```

<br>

## Architecture

```
send() / sendTo()
    │
    ▼
┌──────────────────────┐
│  Middleware (onSend)  │  ── return nil to cancel
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│  Codec Serialize     │  ── struct/delta/quantized/bitfield/etc.
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│  Channel Batch       │  ── multiple packets → one buffer
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│  XOR Delta           │  ── zeros where nothing changed (reliable only)
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│  LZSS Compress       │  ── collapses zero runs
└──────────┬───────────┘
           ▼
     RemoteEvent:Fire()
           │
           ▼
     RemoteEvent.OnEvent
           │
           ▼
┌──────────────────────┐
│  LZSS Decompress     │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│  XOR Restore         │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│  Codec Deserialize   │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│  Gate (server only)  │  ── NaN scan → rate limit → validate
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│  Middleware (onRecv)  │
└──────────┬───────────┘
           ▼
     signal:fire()
```

Static data costs near-zero bandwidth. Incrementally changing data compresses proportionally to how much actually changed.

<br>

## License

MIT
