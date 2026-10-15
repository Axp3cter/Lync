---
family: caller
since: 5.0.0
---

# valueRefused

A value passed to a send does not fit its codec: a type, range, length, count, class or enum item
outside what the schema declares (v5.md §3.3). Nothing is sent, and the writer is left as it was.
The subject names the definition and call, and the path the place in the value. Until milestone 2
adds the views, the trigger calls the encoder directly.

## Example

The module `StarterPlayer.StarterPlayerScripts.Shop`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local Bits = require(ReplicatedStorage.Packages.Lync.wire.bits)
local Rows = require(ReplicatedStorage.Packages.Lync.codec.rows)
local t = Lync.types

local arena = Lync.schema("arena", {
	buy = Lync.request({ from = "client", data = { item = t.enum({ "sword", "shield" }) } }),
})
local codec = arena.ir.byName.buy.data
local instances = { list = {}, index = {} }

Rows.encodeValue(Bits.writer(), codec, { item = "axe" }, instances, "arena.buy:invoke")
```

raises:

```example
StarterPlayer.StarterPlayerScripts.Shop:13: [Lync] valueRefused: arena.buy:invoke data.item must be one of "sword", "shield", got "axe"
```

## Fix

Pass a value the codec accepts, or widen the codec in the schema.
