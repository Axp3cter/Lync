---
family: fact
since: 5.0.0
evidence: lane, expected
---

# tagMismatch

An upstream frame's tag matches at none of the counts e to e + 4 the server tries (v5.md §4.5). The frame is
dropped and the expected count is left unchanged.

| Evidence | Meaning |
|---|---|
| `lane` | 0 reliable, 1 unreliable |
| `expected` | the count e the server tried first: the reliable frame count, or the extended `seq` mod 2^32 |

Known honest causes: a Lync bug, which then repeats as `desync`.

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] tagMismatch: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

An honest client never produces it; nothing needs doing for a client that is not honest.
