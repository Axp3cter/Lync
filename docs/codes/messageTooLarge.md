---
family: declaration
since: 5.0.0
---

# messageTooLarge

A message's worst-case encoded size is over 16,000 bytes, so it could not always fit one chunk
(v5.md §3.4, §4.9). The size is the bits of its encoding, rounded up to bytes, plus its tail bytes,
with each array or map in whichever of single rows and a column block (§4.3) costs more; a request's
ask and answer add their slot fields, and a collection's add row its slot and key.

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

return Lync.schema("arena", {
	log = Lync.event({ from = "server", data = t.array(t.string(1000), 100) }),
})
```

raises:

```example
ReplicatedStorage.Net.schema:6: [Lync] messageTooLarge: arena.log data must encode in at most 16000 bytes, got 100130
```

## Fix

Lower the maximum counts or lengths, or split the data across messages.
