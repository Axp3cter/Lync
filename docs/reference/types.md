# Types

Handlers, records and replies are typed from the schema. Nothing is annotated.

```lua
local Types = require(game.ReplicatedStorage.Lync.Types)

local Fighter = Lync.struct({ name = Lync.str(1, 20), score = Lync.int(0, 1000000) })

type Fighter = Types.Infer<typeof(Fighter)>      -- { name: string, score: number }
type Roster  = Types.Schema<typeof(fields)>      -- a table of codecs as its record
type Patch   = Types.Update<Fighter, Lync.None>  -- what a set update takes
```

```lua
local codec: Lync.Codec<number>
local packet: Lync.Packet<Vector3>
local query: Lync.Query<Order, Receipt>
local set: Lync.Set<Fighter>
local group: Lync.Group
local conn: Lync.Connection
local to: Lync.Recipient           -- All | Player | { Player } | Group | Except
local kind: Lync.LogKind           -- "warn" | "error"
local cause: Lync.Cause            -- "removed" | "cleared"
local code: Lync.OutcomeCode       -- "timeout" | "unanswered" | "leave" | "shutdown"
local ctx: Lync.ValidateContext    -- player, now, last
local log: Lync.LogData            -- file, line, player?, definition?
local why: Lync.OutcomeData        -- definition, elapsed?
local done: Lync.Outcome<Receipt>  -- a server request's completion callback
local clear: Lync.None             -- the type of Lync.none
```
