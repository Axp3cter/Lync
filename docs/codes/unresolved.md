---
family: fact
since: 5.0.0
evidence: what, value
---

# unresolved

On the server, a message holds a Roblox enum value the engine lacks (what 1), a required instance that arrived
`nil` (2), or an instance that fails its `IsA` class (3) (v5.md §6.1 step 5). The message is dropped and an ask
is answered `rejected`. A client drops such messages and counts them as `unresolvedMessages` instead.

| Evidence | Meaning |
|---|---|
| `what` | 1 enum value, 2 `nil` instance, 3 `IsA` failure |
| `value` | the enum value, or the instance's index in its chunk |

Known honest causes: engine version skew; streaming, which leaves instances unreplicated; an instance replaced before the message arrived.

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] unresolved: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

Send instances the receiver has, or make the field `t.optional` when it may arrive `nil`.
