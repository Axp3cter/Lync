---
family: fact
since: 5.0.0
evidence: frames
---

# missedFlush

Under `Lync.scheduler("manual")`, data has been pending for more than 2 `PostSimulation` steps without a
`Lync.flush()` (v5.md §5.1). It is reported once; nothing is dropped.

| Evidence | Meaning |
|---|---|
| `frames` | the steps the data had waited when reported |

Known honest causes: a custom tick slower than the frame rate.

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] missedFlush: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

Call `Lync.flush()` at the end of every tick, or return to the automatic scheduler.
