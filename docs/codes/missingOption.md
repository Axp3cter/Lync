---
family: declaration
since: 5.0.0
---

# missingOption

A required option is absent: `from` on an event or a request, `perSecond` in a `limit`, or `encode`,
`decode`, `name`, `version` and one of `maxBits` and `maxBytes` in a `t.custom` spec.

## Example

```luau
chat = Lync.event({ data = t.string(200) }),
```

```example
ReplicatedStorage.Net.schema:6: [Lync] missingOption: arena.chat must have the option from, "client" or "server"
```

## Fix

Add the option. For `from`, name the side that sends the definition.
