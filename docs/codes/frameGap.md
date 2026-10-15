---
family: fact
since: 5.0.0
evidence: skipped
---

# frameGap

An upstream reliable frame's tag matches at e + j for j from 1 to 4, so j frames the client counted never
arrived (v5.md §4.5). The frame is kept and the count moves past the gap.

| Evidence | Meaning |
|---|---|
| `skipped` | j, the frames counted but never received, 1 to 4 |

Known honest causes: `FireServer` raising on the client after the count advanced.

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] frameGap: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

Nothing; the frame was accepted.
