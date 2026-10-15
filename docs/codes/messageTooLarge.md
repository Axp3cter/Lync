---
family: declaration
since: 5.0.0
---

# messageTooLarge

A message's worst-case encoded size is over 16,000 bytes, so it could not always fit one chunk
(v5.md §3.4, §4.9). The size is the single-row encoding's bits, rounded up to bytes, plus its tail
bytes; a request's ask and answer add their slot fields, and a collection's add row its slot and
key.

## Example

```luau
log = Lync.event({ from = "server", data = t.array(t.string(1000), 100) }),
```

```example
ReplicatedStorage.Net.schema:8: [Lync] messageTooLarge: arena.log data must encode in at most 16000 bytes, got 100126
```

## Fix

Lower the maximum counts or lengths, or split the data across messages.
