---
family: fact
since: 5.0.0
evidence: seq
---

# impossibleAck

An ack names a state-frame sequence never sent to this player (v5.md §6.1 step 4). The ack is ignored; the
rest of the frame is kept.

| Evidence | Meaning |
|---|---|
| `seq` | the extended sequence the ack names |

Known honest causes: none.

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] impossibleAck: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

Nothing; an honest client never produces it.
