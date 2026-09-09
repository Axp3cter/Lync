# Sets

A set holds records owned by the server. Each client receives the records its audience allows
and is notified when they change.

A set of fighters, with audiences keyed by team.

```lua
Fighters = Lync.replicate(Lync.struct({
    name  = Lync.str(1, 20),
    team  = Lync.enum({ "red", "blue" }),
    hp    = Lync.int(0, 100),
    pos   = Lync.vec3(Lync.quant(-512, 512, 0.1)):newest(10),
    title = Lync.optional(Lync.str(0, 16)),
})):keyBy("team"),
```

Only the server creates, changes and removes records.

```lua
Net.Fighters:add(userId, { name = "Ada", team = "red", hp = 100, pos = spawn })
Net.Fighters:update(userId, { hp = 90 })
Net.Fighters:update(userId, { title = Lync.none })
Net.Fighters:audience("red", redTeam)
Net.Fighters:remove(userId)
```

| Server call | |
| --- | --- |
| `add(id, record)` | Throws if the id is already in use or the record has a field the set does not declare. |
| `update(id, fields)` | Changes only the fields given. `Lync.none` clears an optional field. |
| `remove(id)` | Throws on an absent id. |
| `clear()` | Removes every record. Clients receive `onRemoved` with cause `"cleared"` for each. |
| `audience(key, to)` | Sets who receives the records under a key. `to` is any [recipient](packets.md#recipients). Keyed sets only. |

Both sides can read records and subscribe to changes.

```lua
Net.Fighters:onAdded(function(id, record)
    board:show(id, record)
end)

Net.Fighters:onChanged(function(id, record, old)
    bar:set(id, record.hp, old.hp)
end)

Net.Fighters:onRemoved(function(id, cause)
    board:hide(id)
end)

local fighter = Net.Fighters:get(userId)
for id, record in Net.Fighters do
    board:show(id, record)
end
```

| Either side | |
| --- | --- |
| `get(id)` | The current record, or nil. This is the library's own table, so do not modify it, and copy it if you keep it. |
| `#set` | The number of records this side holds. |
| `for id, record in set` | Iteration over them. |
| `onAdded(fn)` | `fn(id, record)` when a record first becomes visible to this side: an add, a late join, or an audience change. |
| `onChanged(fn)` | `fn(id, record, old)` with the record after the flush and the record before it. |
| `onRemoved(fn)` | `fn(id, cause)` with `"removed"` or `"cleared"`. |

Ids can be any integer up to 2^53, so UserIds can be used directly.

## What a flush sends

A flush sends only the fields that changed, and only to clients that can see the record. Several
changes to one record within a flush are combined.

| Inside one flush | Ships |
| --- | --- |
| `update(1, { hp = 90 })` then `update(1, { hp = 80 })` | One delta, `hp = 80`. |
| `add(2, record)` then `remove(2)` | Nothing. |
| `add(3, record)` then `update(3, { hp = 5 })` | One add, with `hp = 5`. |

A client that joins late, or gains visibility of a record, receives the record's current state in
a single `onAdded` call. Earlier changes are not replayed.

## Audiences

Without `keyBy`, every client receives every record. With `keyBy`, a client receives the records
under the keys whose audience includes it. Changing a record's key moves it between audiences
within the flush.

```lua
Net.Fighters:update(userId, { team = "blue" })
```

| A client that sees | Receives |
| --- | --- |
| `"red"` only | `onRemoved(id, "removed")` |
| `"blue"` only | `onAdded(id, record)` |
| both keys | `onChanged(id, record, old)` |

The audience keeps a reference to the group rather than a copy. A player added to `redTeam`
later receives the red records on the next flush.

## Newest fields

Mark a field `:newest(hz?)` when only its latest value matters, such as a position. The field is
sent unreliably, at most `hz` times a second, and is not resent while its value is unchanged.

!!! note
    When one flush changes both a newest field and a reliable field of the same record, the
    client's `onChanged` runs twice, first for the reliable field. Read the values from `record`
    inside the handler rather than caching them.
