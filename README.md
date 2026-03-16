<h1 align="center">Lync</h1>
<p align="center">
  Binary networking for Roblox.<br>
  Batched, delta-encoded, XOR-framed. One RemoteEvent per frame.
</p>
<p align="center">
  <a href="https://github.com/Axp3cter/Lync/releases/latest">Releases</a> · <a href="#installation">Install</a> · <a href="#benchmarks">Benchmarks</a>
</p>

---

Define packets, call `start()`. Lync handles the rest: binary serialization, batching, delta compression, and XOR framing that feeds clean input to Roblox's deflate. NaN/inf scanning, rate limiting, and validation run on all incoming data.

---

## Installation

Place `Lync` in `ReplicatedStorage`. Define all packets before calling `start()`.

```luau
local Lync = require(ReplicatedStorage.Lync)

-- definitions

Lync.start()
```

Install via [Wally](https://wally.run):

```toml
[dependencies]
Lync = "axpecter/lync@0.5.0-alpha"
```

Or grab the `.rbxm` from the [latest release](https://github.com/Axp3cter/Lync/releases/latest).

---

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

---

## Queries

Bidirectional request-reply over RemoteEvents. No RemoteFunctions. Returns `nil` on timeout or handler error.

```luau
local GetInventory = Lync.defineQuery("GetInventory", {
    request   = Lync.u32,
    response  = Lync.array(Lync.struct({
        itemId = Lync.u32,
        count  = Lync.u16,
    })),
    timeout   = 5,
    rateLimit = { maxPerSecond = 10 },
    validate  = function(data, player)
        return data > 0, "invalid id"
    end,
})
```

<details>
<summary><b>Server</b></summary>

```luau
GetInventory:listen(function(playerId, player)
    return fetchInventory(playerId)
end)

-- query a client
local response = GetInventory:invoke(request, player)
```
</details>

<details>
<summary><b>Client</b></summary>

```luau
local items = GetInventory:invoke(localPlayer.UserId)

-- listen for server queries
GetInventory:listen(function(request)
    return computeResponse(request)
end)
```
</details>

---

## Types

<details open>
<summary><b>Primitives</b></summary>

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
</details>

<details>
<summary><b>Complex</b></summary>

| Type     |      Bytes | Description                  |
| :------- | ---------: | :--------------------------- |
| `string` | varint + N | UTF-8 string                 |
| `vec2`   |          8 | Vector2                      |
| `vec3`   |         12 | Vector3                      |
| `cframe` |         24 | CFrame (position + rotation) |
| `color3` |          3 | Color3 (0–255 per channel)   |
| `inst`   |          2 | Instance reference           |
| `buff`   | varint + N | Raw buffer                   |
</details>

<details>
<summary><b>Composites</b></summary>

```luau
Lync.struct({ key = codec, ... })        -- named fields, bools packed
Lync.array(codec)                        -- variable-length list
Lync.map(keyCodec, valueCodec)           -- key-value pairs
Lync.optional(codec)                     -- nil flag + value
Lync.tuple(codec1, codec2, ...)          -- positional, ordered
```
</details>

<details>
<summary><b>Delta</b></summary>

Only changed data is sent between frames. Requires reliable delivery.

```luau
Lync.deltaStruct({ key = codec, ... })   -- dirty fields only
Lync.deltaArray(codec)                   -- dirty elements only
```
</details>

<details>
<summary><b>Specialized</b></summary>

```luau
Lync.enum("idle", "walking", "running")
Lync.quantizedFloat(min, max, precision)
Lync.quantizedVec3(min, max, precision)
Lync.bitfield({
    alive = { type = "bool" },
    level = { type = "uint", width = 5 },
    delta = { type = "int",  width = 4 },
})
Lync.tagged("kind", { move = moveCodec, chat = chatCodec })
```

| Type      | Description                                   |
| :-------- | :-------------------------------------------- |
| `nothing` | Zero bytes, reads nil                         |
| `unknown` | Bypasses binary encoding, uses Roblox sidecar |
| `auto`    | Self-describing tag + value                   |
</details>

---

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

| Option       | Description                                                |
| :----------- | :--------------------------------------------------------- |
| `value`      | Required. Codec for the payload.                           |
| `unreliable` | Use UnreliableRemoteEvent. Default `false`.                |
| `rateLimit`  | Token bucket. `burstAllowance` defaults to `maxPerSecond`. |
| `validate`   | Server-only. Return `false, "reason"` to drop.             |

---

## Groups

Named player sets for targeted sends. Auto-removed on `PlayerRemoving`.

```luau
Lync.createGroup("lobby")
Lync.addToGroup("lobby", player)
Lync.removeFromGroup("lobby", player)
Lync.hasInGroup("lobby", player)
Lync.groupCount("lobby")
Lync.getGroupSet("lobby")
Lync.forEachInGroup("lobby", fn)
Lync.destroyGroup("lobby")
```

---

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

<details>
<summary><b>Drop handler</b></summary>

Called when an incoming packet is rejected.

```luau
Lync.onDrop(function(player, reason, name, data)
    -- "nan" | "rate" | "validate" | custom string
end)
```
</details>

---

## Benchmarks

1000 packets/frame to one player, 10 seconds per test, 60 FPS.
Entity struct is 34 bytes (2× vec3, 2× f32, bool, u8).

| Scenario         | What changes         | Raw Kbps | Kbps (med) | Kbps (p95) | Reduction |
| :--------------- | :------------------- | -------: | ---------: | ---------: | --------: |
| Static booleans  | Nothing              |      480 |       2.27 |       3.52 |     99.5% |
| Static entities  | Nothing              |   16,320 |       2.59 |       2.66 |    99.98% |
| Moving entities  | Position only        |   16,320 |       3.09 |       3.23 |    99.98% |
| Chaotic entities | Every field, random  |   16,320 |       4.70 |       4.77 |    99.97% |

<details>
<summary><b>Run benchmarks</b></summary>

```bash
rojo build bench.project.json -o Lync-bench.rbxl
```

Open in Studio, start a local server with one player.
</details>

---

## License

MIT
