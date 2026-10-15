---
family: outcome
since: 5.0.0
---

# rejected

The answering side dropped the ask after reading its slot: it was over `limit`, `validate` returned `false` or raised, or it was `unresolved`. Requests never throw (v5.md §3.5, §5.2); the outcome is the `error` of the result `invoke` returns.

## Example

`invoke` returns:

```example
{ ok = false, error = "rejected" }
```

## Fix

Ask within the definition's `limit`, with a value the other side's validator accepts.
