---
family: fact
since: 5.0.0
evidence: slot, case
---

# slotConflict

After the epoch check of v5.md §5.2: an answer for a free slot (case 1), an answer whose id is not the answer
id of the slot's request (case 2), or an ask for a slot already in flight with the same epoch (case 3). The
message is dropped.

| Evidence | Meaning |
|---|---|
| `slot` | the request slot, 0 to 15 |
| `case` | 1, 2 or 3, as above |

Known honest causes: none.

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] slotConflict: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

Nothing; an honest peer never produces it.
