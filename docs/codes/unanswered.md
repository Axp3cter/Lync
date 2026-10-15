---
family: outcome
since: 5.0.0
---

# unanswered

The answering side's `handle` raised, returned nothing, or ran past the `timeout`. A raise is reported natively on that side. Requests never throw (v5.md §3.5, §5.2); the outcome is the `error` of the result `invoke` returns.

## Example

`invoke` returns:

```example
{ ok = false, error = "unanswered" }
```

## Fix

Make the handler return a value for every ask.
