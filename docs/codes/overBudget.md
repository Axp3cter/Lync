---
family: fact
since: 5.0.0
evidence: lane, bytes, instances, elements
---

# overBudget

On the server, a frame finds its lane's frame bucket below 1 or its byte bucket below the frame's charge,
`buffer.len` plus 8 B per instance, before anything is decoded; or its decode exhausts the player's
`inbound.elements` allowance (v5.md §4.8 rule 10, §6.1 step 2). The frame is dropped. An over-budget reliable
frame is still tag-checked, so the count stays in step.

| Evidence | Meaning |
|---|---|
| `lane` | 0 reliable, 1 unreliable |
| `bytes` | the frame's `buffer.len` |
| `instances` | the frame's instance count |
| `elements` | the elements its decode had charged when rule 10 refused it; 0 when a frame or byte bucket refused it |

Known honest causes: a stall longer than the bucket's burst releasing many frames together; a budget below the game's traffic.

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] overBudget: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

If honest players reach it, raise the budget that refused it with `Lync.configure({ inbound = … })` (v5.md §7.5).
