---
family: caller
since: 5.0.0
---

# valueRefused

A value passed to a send does not fit its codec: a type, range, length, count, class or enum item
outside what the schema declares (v5.md §3.3). Nothing is sent, and the writer is left as it was.
The subject names the definition and call, and the path the place in the value.

## Example

```luau
local result = Net.buy:invoke({ item = "axe" })
```

```example
StarterPlayer.StarterPlayerScripts.Shop:41: [Lync] valueRefused: arena.buy:invoke data.item must be one of "sword", "shield", got "axe"
```

## Fix

Pass a value the codec accepts, or widen the codec in the schema.
