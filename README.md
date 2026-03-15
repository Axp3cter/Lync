# Lync

Binary networking for Roblox. Batches, compresses, and delta-encodes packets over RemoteEvents.

## Setup

Drop `Lync` into `ReplicatedStorage`. Call `start()` once on both server and client after all packets are defined.

```luau
local Lync = require(ReplicatedStorage.Lync)

-- Define packets here (runs on both server and client)

Lync.start()
```

## Packets

```luau
local Damage = Lync.definePacket("Damage", {
    value = Lync.struct({
        targetId = Lync.u32,
        amount   = Lync.f32,
        crit     = Lync.bool,
    }),
})

-- Server
Damage:sendTo({ targetId = 5, amount = 25.5, crit = true }, player)
Damage:sendToAll(data)
Damage:sendToAllExcept(data, excludedPlayer)
Damage:sendToList(data, { player1, player2 })
Damage:sendToGroup(data, "team_red")

-- Client
Damage:send({ targetId = 5, amount = 25.5, crit = true })

-- Both
Damage:listen(function(data, sender) end) -- sender is nil on client
Damage:once(function(data, sender) end)
Damage:wait()
Damage:disconnectAll()
```

## Queries (Request-Reply)

```luau
local GetInventory = Lync.defineQuery("GetInventory", {
    request  = Lync.u32,          -- player ID
    response = Lync.array(Lync.struct({ itemId = Lync.u32, count = Lync.u16 })),
    timeout  = 5,                 -- seconds, default 5
})

-- Server
GetInventory:listen(function(playerId, player)
    return fetchInventory(playerId)
end)

-- Client
local items = GetInventory:invoke(localPlayer.UserId)
if items then
    -- got response
end
```

## Types

### Primitives
`u8` `u16` `u32` `i8` `i16` `i32` `f32` `f64` `bool` `f16`

### Complex
`string` `vec2` `vec3` `cframe` `color3` `inst` `buff`

### Composites
```luau
Lync.struct({ key = codec, ... })
Lync.array(codec)
Lync.map(keyCodec, valueCodec)
Lync.optional(codec)
Lync.tuple(codec1, codec2, ...)
```

### Delta (automatic frame-to-frame compression)
```luau
Lync.deltaStruct({ key = codec, ... })  -- only sends changed fields
Lync.deltaArray(codec)                  -- only sends changed elements
```
Delta codecs require reliable delivery. Lync errors if you pair them with `unreliable = true`.

### Specialized
```luau
Lync.enum("idle", "walking", "running")
Lync.quantizedFloat(min, max, precision)    -- e.g. (0, 100, 0.1) → 2 bytes
Lync.quantizedVec3(min, max, precision)     -- per-component quantization
Lync.bitfield({ alive = { type = "bool" }, level = { type = "uint", width = 5 } })
Lync.tagged("type", { move = moveCodec, chat = chatCodec })
```

### Special
```luau
Lync.nothing   -- zero bytes, reads nil
Lync.unknown   -- passes value through Roblox sidecar (no binary encoding)
Lync.auto      -- self-describing tag + value (flexible, larger wire size)
```

## Packet Options

```luau
Lync.definePacket("Position", {
    value      = Lync.vec3,
    unreliable = true,                               -- use UnreliableRemoteEvent
    rateLimit  = { maxPerSecond = 30, burstAllowance = 5 },
    validate   = function(data, player)              -- server-only, runs after deserialize
        if data.X ~= data.X then return false, "nan" end
        return true
    end,
})
```

NaN/inf scanning, depth limiting, and rate limiting run automatically on all incoming packets. `validate` is an additional user-defined check.

## Groups

```luau
Lync.createGroup("team_red")
Lync.addToGroup("team_red", player)        -- returns false if already in group
Lync.removeFromGroup("team_red", player)
Lync.hasInGroup("team_red", player)        -- returns boolean
Lync.getGroupSet("team_red")               -- returns { [Player]: true }
Lync.forEachInGroup("team_red", function(player) end)
Lync.destroyGroup("team_red")
```

Players are auto-removed from all groups on `PlayerRemoving`.

## Middleware

```luau
local removeSend = Lync.onSend(function(data, packetName, player)
    print("sending", packetName)
    return data -- return nil to cancel
end)

local removeRecv = Lync.onReceive(function(data, packetName, player)
    return data
end)

removeSend()  -- disconnect
```

## Drop Handler

```luau
Lync.onDrop(function(player, reason, packetName, data)
    -- reason: "nan" | "rate" | "validate" | custom string
end)
```

## How It Works

Every `send`/`sendTo` call writes binary data into a per-player channel buffer. On `Heartbeat`, each channel is sealed, XOR'd against the previous frame (producing zeros where nothing changed), LZSS compressed, and fired as a single `RemoteEvent`. The receiver reverses the pipeline: decompress → un-XOR → parse batches → deserialize → gate check → middleware → signal fire.

Static data costs near-zero bandwidth. Incrementally changing data (player movement) compresses proportionally to how much actually changed.
