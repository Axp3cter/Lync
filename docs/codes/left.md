---
family: outcome
since: 5.0.0
---

# left

The player the server asked left before answering. Requests never throw (v5.md §3.5, §5.2); the outcome is the `error` of the result `invoke` returns.

## Example

`invoke` returns:

```example
{ ok = false, error = "left" }
```

## Fix

Nothing; treat the request as not answered.
