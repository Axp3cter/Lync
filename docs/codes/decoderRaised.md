---
family: fact
since: 5.0.0
evidence: lane
---

# decoderRaised

The decoder raised while decoding a frame, which it never does by design (v5.md §4.8). The frame is dropped,
and the raise is also reported natively, at most once per window (§7.2).

| Evidence | Meaning |
|---|---|
| `lane` | 0 reliable, 1 unreliable |

Known honest causes: a Lync bug.

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] decoderRaised: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

Report the native report's message and the schema as a Lync bug.
