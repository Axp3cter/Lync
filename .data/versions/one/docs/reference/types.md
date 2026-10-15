# Types

Handler arguments, records and replies get their types from the schema, so most code needs no
annotations. For your own signatures, three type functions turn codecs into types.

## Type functions

They live in the `Types` module next to `Lync`, because Luau cannot re-export a type function.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Lync)
local Types = require(ReplicatedStorage.Lync.Types)

local fields = {
    name = Lync.str(1, 20),
    score = Lync.int(0, 1000000),
}
local Fighter = Lync.struct(fields)

type Fighter = Types.Infer<typeof(Fighter)>   -- { name: string, score: number }
type Same = Types.Schema<typeof(fields)>      -- the same, from the table of codecs
type Patch = Types.Update<Fighter, Lync.None> -- { name: string?, score: number? }
```

| Type function | Gives |
| --- | --- |
| `Infer<C>` | The type of the value a codec carries. |
| `Schema<F>` | The record type a table of codecs describes. |
| `Update<T, None>` | The argument of a set `update`: any subset of `T`, with `Lync.none` allowed on optional fields. |

## Exported types

| Type | Is |
| --- | --- |
| `Lync.Codec<T>` | A codec carrying `T`. |
| `Lync.Packet<T>` | A packet. |
| `Lync.Query<Q, R>` | A query. |
| `Lync.Set<T>` | A set. |
| `Lync.Group` | A group. |
| `Lync.Connection` | What every `on*` method returns. |
| `Lync.Recipient` | Anything a `to` argument accepts. |
| `Lync.All`, `Lync.Except` | The types of `Lync.all` and `Lync.except(...)`. |
| `Lync.None` | The type of `Lync.none`. |
| `Lync.LogKind` | `"warn"` or `"error"`. |
| `Lync.LogData` | `file`, `line`, and `player`, `definition` and other fields when present. |
| `Lync.Cause` | `"removed"` or `"cleared"`. |
| `Lync.OutcomeCode` | `"timeout"`, `"unanswered"`, `"leave"` or `"shutdown"`. |
| `Lync.OutcomeData` | `definition`, and `elapsed` when the request ended. |
| `Lync.Outcome<R>` | A server request's callback. |
| `Lync.ValidateContext` | `player`, `now`, `last`. |
