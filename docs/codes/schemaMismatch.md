---
family: fact
since: 5.0.0
evidence: version, seedDiffers, hashLow, hashHigh, unknownName
---

# schemaMismatch

A `HELLO`'s protocol version, build seed or schema hash differs from the server's, or it names no namespace the
server loaded within 10 s (v5.md §4.6). The server answers `MISMATCH` and drops its own sends to that player's
namespace. The client that gets `MISMATCH` reports `schemaMismatch` natively, once per namespace, and drops that
namespace's sends (§7.2).

| Evidence | Meaning |
|---|---|
| `version` | the `HELLO`'s protocol version |
| `seedDiffers` | 1 when its build seed differs, else 0 |
| `hashLow` | the low 32 bits of its schema hash |
| `hashHigh` | the high 32 bits of its schema hash |
| `unknownName` | 1 when it names no loaded namespace, else 0 |

Known honest causes: a stale or mixed build: a client on another version of the schema than the server.

## Example

Its console line (v5.md §7.4): one at the first occurrence in a window, and a summary at the window's close if
more occurred. The text is the same for every occurrence; the numbers, at most 8 `UserId`s and at most 8
definition names travel in the line's context.

```example
[Lync] schemaMismatch: {count} in {seconds} s, {players} players, {definitions} definitions
```

## Fix

Publish one build to every server, and make sure the server loads the namespace on start (`Lync.server(schema)`).
