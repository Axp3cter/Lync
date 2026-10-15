---
family: fact
since: 5.0.0
evidence: hashChanged
---

# repeatedHello

A `HELLO` names a namespace this connection already had welcomed or refused (v5.md §4.6). It is ignored.

| Evidence | Meaning |
|---|---|
| `hashChanged` | 1 when its schema hash differs from the first `HELLO`'s, else 0 |

Known honest causes: none.

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] repeatedHello: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

Nothing; an honest client sends one `HELLO` per namespace.
