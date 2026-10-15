---
family: fact
since: 5.0.0
evidence: seq, behind, seen
---

# replayed

An upstream unreliable frame's sequence was already seen inside the 64-frame replay window, or is older than
the window (v5.md §4.5). The frame is dropped.

| Evidence | Meaning |
|---|---|
| `seq` | the frame's extended sequence |
| `behind` | how far it is behind the newest sequence received |
| `seen` | 1 when it was seen inside the window, 0 when it is older than the window |

Known honest causes: transport duplication or deep reordering (unmeasured, v5.md §10).

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] replayed: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

Nothing; the frame's first copy was already delivered.
