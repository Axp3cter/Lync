# Validation

Incoming values are checked in two steps. First the codec rejects anything outside its bounds,
before your code runs. Then any check attached to the codec with `:validate` runs.

A check on one field, rejecting a sender who fires faster than ten times a second.

```lua
Damage = Lync.int(0, 500):validate(function(amount, context)
    if context.last ~= nil and context.now - context.last < 0.1 then
        return "faster than 10 Hz"
    end
    return nil
end),
```

A check on a whole record, for a rule between fields.

```lua
Trade = Lync.struct({
    give = Lync.int(0, 1000),
    take = Lync.int(0, 1000),
}):validate(function(offer)
    if offer.give == 0 and offer.take == 0 then
        return "empty trade"
    end
    return nil
end),
```

Return nil to pass or a string to drop. The string becomes the reason in the log.

| `context` field | |
| --- | --- |
| `player` | The player who sent the value. Nil for a value the server sent to itself. |
| `now` | When it arrived. |
| `last` | When the previous value from this sender for this definition arrived, whether it was accepted or not. |

`last` is updated on every arrival, including rejected ones, so a sender cannot reset it by sending
invalid values. The context table is reused between calls, so copy anything you keep from it.

## What a drop does

| | |
| --- | --- |
| The listener | Never runs. |
| The log | Gets one warning with the reason, the definition, the file and line it was declared at, and the player. |
| A request | Gets no reply, so the requester ends with the `timeout` code. |
