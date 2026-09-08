# Validation

Two gates on the way in: the codec, then your check. A rejection at either is a drop, logged as
one warning, and your listener never runs.

```lua
Damage = Lync.int(0, 500):validate(function(amount, ctx)
    -- ctx.player  who sent it, nil for the server's own values
    -- ctx.now     when it arrived
    -- ctx.last    when this sender's previous value arrived, accepted or not
    if ctx.last ~= nil and ctx.now - ctx.last < 0.1 then return "faster than 10 Hz" end
    return nil  -- nil passes, a string drops
end),
```

```lua
-- a check on the whole record, for rules between fields
Trade = Lync.struct({
    give = Lync.int(0, 1000),
    take = Lync.int(0, 1000),
}):validate(function(offer)
    return if offer.give == 0 and offer.take == 0 then "empty trade" else nil
end),
```

`ctx` is reused between calls. A dropped request is answered by nothing, so the requester sees
`timeout`.
