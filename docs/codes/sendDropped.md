---
family: fact
since: 5.0.0
evidence: queue, lane, bytes
---

# sendDropped

A local send is dropped: a reliable send past the join hold of 32,768 B, an unreliable send before the
namespace's `WELCOME`, or a send over its `limit` past the FIFO or on the unreliable lane (v5.md §5.3, §5.4). On
the server, `player` is the player the send was for.

| Evidence | Meaning |
|---|---|
| `queue` | 1 the join hold, 2 the `limit` FIFO |
| `lane` | 0 reliable, 1 unreliable |
| `bytes` | the dropped message's encoded size |

Known honest causes: heavy sends during a join; firing faster than `limit`.

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] sendDropped: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

Send less while players join, or fire within the definition's `limit`.
