---
family: declaration
since: 5.0.0
---

# notACodec

A value where a codec is expected is neither a codec nor a record (a plain table of codecs): a
definition's `data`, `reply` or `key`, a record field, a union variant, or a constructor's codec
argument. A collection's `data` must be a record. A common cause is a constructor that was not
called, such as `t.direction` for `t.direction(11)`.

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

return Lync.schema("arena", {
	strike = Lync.event({
		from = "client",
		data = { target = t.int(1, 2 ^ 40), aim = t.direction },
	}),
})
```

raises:

```example
ReplicatedStorage.Net.schema:6: [Lync] notACodec: arena.strike data.aim must be a codec or a record of codecs, got function
```

## Fix

Call the constructor, or replace the value with a codec. The subject names the definition and the
path the place in it.
