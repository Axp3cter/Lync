# Sets

Records the server owns and clients watch. Each client holds what its audiences allow.

```lua
Fighters = Lync.replicate(Lync.struct({
    name  = Lync.str(1, 20),
    team  = Lync.enum({ "red", "blue" }),
    hp    = Lync.int(0, 100),
    pos   = Lync.vec3(Lync.quant(-512, 512, 0.1)):newest(10),  -- lossy, 10 Hz
    title = Lync.optional(Lync.str(0, 16)),
})):keyBy("team"),                                            -- audiences split on team
```

```lua
-- server
Net.Fighters:add(id, { name = "Ada", team = "red", hp = 100, pos = spawn })
Net.Fighters:update(id, { hp = 90 })                            -- only hp goes out
Net.Fighters:update(id, { title = Lync.none })                  -- clears optional
Net.Fighters:audience("red", redTeam)                           -- any recipient
Net.Fighters:remove(id)

-- anywhere
Net.Fighters:onAdded(function(id, record) board:show(id, record) end)
Net.Fighters:onChanged(function(id, record, old) bar:set(id, record.hp, old.hp) end)
Net.Fighters:onRemoved(function(id, cause) board:hide(id) end)  -- removed | cleared

local me = Net.Fighters:get(id)                                 -- borrowed, copy it
for id, record in Net.Fighters do end                           -- #Net.Fighters
```

| Server | |
| --- | --- |
| `add(id, record)` | Throws if the id is live. |
| `update(id, fields)` | Named fields only. |
| `remove(id)` `clear()` | Remove throws on an absent id. |
| `audience(key, to)` | Keyed sets only. |

Ids are exact to 2^53, so UserIds work as they are.

## What a flush sends

```lua
Net.Fighters:update(1, { hp = 90 })
Net.Fighters:update(1, { hp = 80 })  -- one delta, hp = 80
Net.Fighters:add(2, record)
Net.Fighters:remove(2)               -- nothing
```

Changed fields only, to viewers only. A late viewer gets the current record as one `onAdded`.

## Audiences

```lua
Net.Fighters:update(id, { team = "blue" })  -- migrates inside the flush
-- viewers of "red" alone   -> onRemoved(id, "removed")
-- viewers of "blue" alone  -> onAdded(id, record)
-- viewers of both keys     -> onChanged(id, record, old)
```

Without `keyBy` the whole set goes to everyone. An audience holds the group itself, so membership
changes reach viewers on the next flush.

!!! note
    A flush that moves a newest field and a reliable field of one record tells a viewer twice,
    reliable first. Read `record` in the handler and both tellings are right.
