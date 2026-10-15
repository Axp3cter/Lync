# Sets

A set is a table of records that the server owns, each under an integer id. Clients hold a copy of
the records they may see, and are told when records appear, change or go away.

```lua
Fighters = Lync.replicate(Lync.struct({
    name = Lync.str(1, 20),
    team = Lync.enum({ "red", "blue" }),
    hp = Lync.int(0, 100),
    pos = Lync.vec3(Lync.quant(-512, 512, 0.1)):newest(10),
    title = Lync.optional(Lync.str(0, 16)),
})):keyBy("team"),
```

## Write

Only the server writes, after `start`.

```lua
-- After Lync.start():
Net.Fighters:add(player.UserId, { name = player.Name, team = "red", hp = 100, pos = Vector3.zero })
Net.Fighters:update(player.UserId, { hp = 90 })
Net.Fighters:update(player.UserId, { title = Lync.none })
Net.Fighters:remove(player.UserId)
```

| Call | Does |
| --- | --- |
| `add(id, record)` | Adds a record. Throws if the id is in use. |
| `update(id, fields)` | Changes only the fields given. `Lync.none` clears an optional field. |
| `remove(id)` | Removes a record. Throws if the id is not in use. |
| `clear()` | Removes every record. |
| `audience(key, to)` | Chooses who receives a key's records. See [Audiences](#audiences). |

- **Values are checked at the call.** A field that doesn't fit its codec, or isn't declared,
  throws there. A refused `update` changes nothing.
- **Unchanged values send nothing.** Setting a field to the value it holds is skipped.
- **Ids are whole numbers** below 2^53 in magnitude, so a UserId works directly. Ids are unique
  across the whole set.

## Read

Both sides read the records they hold and listen for changes.

```lua
Net.Fighters:onAdded(function(id, record)
    print("joined", record.name)
end)

Net.Fighters:onChanged(function(id, record, old)
    print(record.name, old.hp, "->", record.hp)
end)

Net.Fighters:onRemoved(function(id, cause)
    print("gone", id, cause)
end)

for id, record in Net.Fighters do
    print(id, record.hp)
end
```

| Member | Gives |
| --- | --- |
| `get(id)` | The record, or nil. This is Lync's own table: read it, never change it. |
| `#set` | How many records this side holds. |
| `for id, record in set` | Each record this side holds. |
| `onAdded(fn)` | `fn(id, record)` when a record becomes visible here: an add, a join, or an audience change. |
| `onChanged(fn)` | `fn(id, record, old)`, after and before the flush. |
| `onRemoved(fn)` | `fn(id, cause)`, where `cause` is `"removed"` or `"cleared"`. |

## What a flush sends

A flush sends only fields that changed, only to clients that can see the record. Changes to one
record within a flush are combined.

| Inside one flush | Sends |
| --- | --- |
| `update(1, { hp = 90 })` then `update(1, { hp = 80 })` | One change, `hp = 80`. |
| `add(2, record)` then `remove(2)` | Nothing. |
| `add(3, record)` then `update(3, { hp = 5 })` | One add, with `hp = 5`. |

A client that joins late, or gains sight of a record, receives its current state in one `onAdded`.
Earlier changes are not replayed. How much state one flush sends is capped by its
[budget](lifecycle.md#budgets).

## Audiences

Who receives a record follows one rule:

- **A set without `keyBy` goes to every client.**
- **A keyed set goes to whoever its key's audience names.** `keyBy(field)` groups records by the
  value of that field. `audience(key, to)` names who receives the records under `key`.
- **A key with no audience goes to nobody.** A forgotten audience hides records instead of leaking
  them.

`to` is any [recipient](recipients.md). Keying by team, with a group per team:

```lua
-- After Lync.start():
Net.Fighters:audience("red", redTeam)
Net.Fighters:audience("blue", blueTeam)
```

| When | Clients |
| --- | --- |
| You assign an audience later | New members receive the key's existing records. |
| You reassign it | Those who lose sight receive `onRemoved(id, "removed")`. Those who gain it receive `onAdded`. |
| A group in an audience changes | The audience follows it at the next flush. |
| A record's key field changes | The record moves to the new key's audience in the same flush. |

When one flush moves a record from `"red"` to `"blue"`:

| A client that sees | Receives |
| --- | --- |
| `"red"` only | `onRemoved(id, "removed")` |
| `"blue"` only | `onAdded(id, record)` |
| Both keys | `onChanged(id, record, old)` |

### Per-player records

The rule covers private data too. Key by the owner's UserId, and give each player their own key.

```lua
Inventory = Lync.replicate(Lync.struct({
    owner = Lync.vli(),
    item = Lync.enum({ "sword", "shield", "potion" }),
    count = Lync.int(0, 99),
})):keyBy("owner"),
```

```lua
local Players = game:GetService("Players")

-- After Lync.start():
local function grant(player: Player)
    Net.Inventory:audience(player.UserId, player)
end

Players.PlayerAdded:Connect(grant)
for _, player in Players:GetPlayers() do
    grant(player)
end
```

Remove a player's records when they leave. Once empty, their key is forgotten.

### Keys

A key must be an exact field: `bool`, `int`, `enum`, `vlq`, `vli` or `str`. It cannot be
`optional`, `:newest` or `:as`, since a key must arrive reliably and compare exactly. `start`
throws on any other.

## Newest fields

Mark a field `:newest(hz?)` when only its latest value matters, such as a position.

- It is sent unreliably, at most `hz` times a second, and not resent while unchanged.
- It works only on a field of the record itself, not inside a nested struct.
- One record of it must fit in 1000 bytes. See [Limits](../reference/limits.md#sizes).

!!! note
    When one flush changes both a newest field and a reliable field of a record, `onChanged` can run
    twice. Read values from `record` inside the handler instead of caching them.

## Trust

Set values come only from the server, which is the side that checks. So `:validate` is refused
anywhere in a set record. Check input where it enters, in a [packet](packets.md) or
[query](queries.md).
