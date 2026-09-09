# Types

Handler arguments, records and replies get their types from the schema. No annotations are
needed.

Three type functions convert a codec into the Luau type of the value it carries. They are
exported from the `Types` module next to `Lync`.

```lua
local Types = require(game.ReplicatedStorage.Lync.Types)

local Fighter = Lync.struct({
    name = Lync.str(1, 20),
    score = Lync.int(0, 1000000),
})

type Fighter = Types.Infer<typeof(Fighter)>
type Roster = Types.Schema<typeof(fields)>
type Patch = Types.Update<Fighter, Lync.None>
```

| Type function | Answers |
| --- | --- |
| `Infer<C>` | The type of the value a codec carries. `{ name: string, score: number }` in the example. |
| `Schema<F>` | The record type described by a table of codecs. |
| `Update<T, None>` | The argument type of a set update: any subset of `T`, with `Lync.none` allowed on optional fields. |

The remaining types are exported from `Lync`, for annotating your own function signatures.

| Type | Holds |
| --- | --- |
| `Lync.Codec<T>` | A codec carrying `T`. |
| `Lync.Packet<T>` | A packet definition. |
| `Lync.Query<Q, R>` | A query definition. |
| `Lync.Set<T>` | A set definition. |
| `Lync.Group` | A group. |
| `Lync.Connection` | The value returned by every `on*` method. |
| `Lync.Recipient` | Anything `to` accepts. |
| `Lync.LogKind` | `"warn"` or `"error"`. |
| `Lync.Cause` | `"removed"` or `"cleared"`. |
| `Lync.OutcomeCode` | One of the four request endings. |
| `Lync.ValidateContext` | `player`, `now`, `last`. |
| `Lync.LogData` | `file`, `line`, and `player` and `definition` when present. |
| `Lync.OutcomeData` | `definition`, and `elapsed` when the request ended. |
| `Lync.Outcome<R>` | A server request's completion callback. |
| `Lync.None` | The type of `Lync.none`. |
