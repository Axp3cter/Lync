# Validation

Every value that arrives is checked before your code sees it. A value that fails is dropped.

## Two checks

| Check | Covers | Runs |
| --- | --- | --- |
| Codec bounds | Types, ranges, lengths, counts, enum names, an instance's class | When sending, and on arrival |
| `:validate` | Any rule of your own | On arrival only |

A value that fails its bounds when sending throws at the call. On arrival, either check failing
drops the value.

## The trust boundary

The server is the trust boundary.

- **On the server**, values come from clients, who may be exploiters. A drop is logged as a
  warning.
- **On a client**, values come from the server, so a drop means the two disagree. It is logged as
  an error.

## Checks of your own

Bounds stop malformed values. They cannot tell whether a player is allowed to do something, which
is what `:validate` is for. A check returns nil to accept, or a string to drop, which becomes the
reason in the log.

A check on one field, refusing a sender who fires more than ten times a second:

```lua
Damage = Lync.packet(Lync.int(0, 500):validate(function(amount, context)
    if context.last ~= nil and context.now - context.last < 0.1 then
        return "faster than 10 Hz"
    end
    return nil
end)),
```

A check on a whole value, for a rule between fields:

```lua
Trade = Lync.packet(Lync.struct({
    give = Lync.int(0, 1000),
    take = Lync.int(0, 1000),
}):validate(function(offer)
    if offer.give == 0 and offer.take == 0 then
        return "empty trade"
    end
    return nil
end)),
```

| `context` field | Holds |
| --- | --- |
| `player` | The sender. Nil on a client, and in `Lync.decode`. |
| `now` | When the value arrived. 0 in `Lync.decode`. |
| `last` | When this sender's previous value for this definition arrived. Nil in `Lync.decode`. |

- `last` advances on every payload, including rejected ones and each payload of a batch. A sender
  cannot reset it or slip a burst past a rate check.
- The context table is reused, so copy anything you keep from it.
- Checks run in the order you chained them, and the first reason wins.

## What a drop does

| | Result |
| --- | --- |
| Your listener | Never runs for that value. |
| The log | One record with the reason, the definition, where it was declared, and the sender. |
| A request | Gets no reply, so the asker ends with `"timeout"`. |
| The rest of the frame | Still read after a `:validate` rejection. Bytes that don't decode drop the rest of that frame. |

One client cannot flood your log: each gets 8 drop records per code every 10 seconds in each
namespace. The rest are counted and logged as one summary. See
[Errors and logging](logging.md#codes).
