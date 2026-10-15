---
family: fact
since: 5.0.0
evidence: perSecond, burst
---

# overLimit

On the server, a client-sent message finds its definition's `limit` bucket empty; the bucket refills at
`perSecond` and holds `burst` plus 2 s × `perSecond` (v5.md §5.4). The message is dropped, and an ask is answered
`rejected`.

| Evidence | Meaning |
|---|---|
| `perSecond` | the definition's `limit.perSecond` |
| `burst` | the definition's `limit.burst` |

Known honest causes: a stall longer than the slack releasing many messages at once; a `limit` declared below what the game sends.

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] overLimit: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

If honest players reach it, raise the definition's `limit` in the schema.
