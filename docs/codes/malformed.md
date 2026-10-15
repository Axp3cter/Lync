---
family: fact
since: 5.0.0
evidence: lane, rule
---

# malformed

A frame breaks a canonical-decode rule (v5.md §4.8, rules 1 to 9). The whole frame is dropped; nothing in it
is delivered. On the server this is about the sender; a client applies the same rules to what it receives.

| Evidence | Meaning |
|---|---|
| `lane` | 0 reliable, 1 unreliable |
| `rule` | the §4.8 rule the frame broke, 1 to 9 |

Known honest causes: a Lync bug.

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] malformed: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

An honest client never produces it; if one does, report the rule and the schema as a Lync bug.
