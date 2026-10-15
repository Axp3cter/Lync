---
family: fact
since: 5.0.0
evidence: one count per suppressed reason
---

# suppressed

A player's window closes with occurrences that the caps kept from being delivered: `observe.perPlayerEvents` facts
per player and `observe.serverEvents` per server, per window (v5.md §7.3). Each such player gets one `suppressed`,
exempt from the caps, so no occurrence is hidden. Its `count` is the total suppressed, and its `first` and `last`
the times of the first and last of them.

| Evidence | Meaning |
|---|---|
| `<reason>` | one field per suppressed reason, named by its code, holding that reason's count |

Known honest causes: none of its own; it carries the causes of the reasons it counts.

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] suppressed: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

Nothing; raise `observe.perPlayerEvents` or `observe.serverEvents` to see more facts one by one.
