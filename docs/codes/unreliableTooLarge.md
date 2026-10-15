---
family: declaration
since: 5.0.0
---

# unreliableTooLarge

An unreliable event's worst-case encoded size is over 960 bytes, or a collection's `:newest()` row
is, so it could not always fit an unreliable frame (v5.md §3.4, §4.9).

## Example

```luau
shout = Lync.event({ from = "client", lane = "unreliable", data = t.string(1000) }),
```

```example
ReplicatedStorage.Net.schema:9: [Lync] unreliableTooLarge: arena.shout data must encode in at most 960 bytes, got 1002
```

## Fix

Lower the maximum lengths or counts, or send it on the reliable lane.
