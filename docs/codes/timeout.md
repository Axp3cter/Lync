---
family: outcome
since: 5.0.0
---

# timeout

No answer arrived within the request's `timeout` (10 s unless the schema says otherwise). The asking side reclaims the slot and flips its epoch, so a late answer is discarded and counted as `lateAnswers`. Requests never throw (v5.md §3.5, §5.2); the outcome is the `error` of the result `invoke` returns.

## Example

`invoke` returns:

```example
{ ok = false, error = "timeout" }
```

## Fix

Raise the definition's `timeout`, or make its handler answer sooner.
