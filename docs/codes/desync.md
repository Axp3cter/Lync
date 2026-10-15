---
family: fact
since: 5.0.0
evidence: failures, rekeySent
---

# desync

8 upstream frames in a row fail their tags with no valid frame between them (v5.md §4.5). The server sends
`REKEY` unless it sent one to this player in the last 60 s.

| Evidence | Meaning |
|---|---|
| `failures` | the consecutive tag failures, 8 |
| `rekeySent` | 1 when this occurrence sent `REKEY`, else 0 |

Known honest causes: unknown engine reconnect behaviour.

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] desync: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

Nothing; an honest client resumes on the new key.
