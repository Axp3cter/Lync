---
family: fact
since: 5.0.0
evidence: seconds
---

# remotesMissing

On a client, Lync's remotes are still missing 10 s after its first use (v5.md §4.1). The client keeps
waiting.

| Evidence | Meaning |
|---|---|
| `seconds` | the time since the first use, 10 |

Known honest causes: a server that never uses Lync.

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] remotesMissing: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

Use Lync on the server as well, so that it creates the remotes.
