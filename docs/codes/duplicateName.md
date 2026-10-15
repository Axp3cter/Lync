---
family: declaration
since: 5.0.0
---

# duplicateName

A list enum names the same item twice. Each item's index is its place in the list, so a repeated
name would have two indices.

## Example

```luau
team = t.enum({ "red", "blue", "red" }),
```

```example
ReplicatedStorage.Net.schema:27: [Lync] duplicateName: t.enum items must be distinct, got "red"
```

## Fix

Remove the repeated item.
