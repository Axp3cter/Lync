# Codecs

A codec is a type with bounds. The bounds decide how many bits a value costs, what a sender may
send, and what a receiver accepts.

## Bounds are bits

A bounded value costs the bits needed to count its possible values. Narrower bounds mean fewer
bits.

| Codec | Values | Bits |
| --- | --- | --- |
| `bool()` | 2 | 1 |
| `enum({ "red", "blue", "green" })` | 3 | 2 |
| `int(0, 100)` | 101 | 7 |
| `quant(0, 1, 0.01)` | 101 | 7 |
| `angle(1)` | 360 | 9 |
| `quant(-512, 512, 0.1)` | 10241 | 14 |
| `f32()` | any float | 32 |

Fields pack across byte boundaries, so `struct({ hp = int(0, 100), alive = bool() })` takes one
byte. Choose bounds from the range your game uses, not from what the type could hold.

## Choosing a codec

| To send | Use | Not |
| --- | --- | --- |
| A count or index with a known range | `int(min, max)` | `f32`, which is always 32 bits |
| A position or speed | `quant(min, max, step)`, or `vec3(quant(...))` | `vec3()`, which is 96 bits |
| A heading, direction or rotation | `angle`, `vec3.unit`, `rotation.quat`, at a precision in degrees | Raw floats |
| An id or total with no useful bound | `vlq()`, or `vli()` if it can be negative | `f64`, which is always 8 bytes |
| One of a fixed set of names | `enum` | `str` |
| Text | `str(min, max)`, or `str.alphabet` when only some characters appear | |
| One of several shapes | `tagged` | A struct of optionals |

Every codec and its cost is in the [Codecs reference](../reference/codecs.md).

## Values off the grid

| Codec | Given a value between steps |
| --- | --- |
| `int` | Refuses a fraction. |
| `quant` | Rounds to the nearest step. |
| `angle` | Rounds, and wraps: 370 arrives as 10, -10 as 350. |

A value outside the bounds is refused: sending it throws at the call, and receiving it drops it
before your code sees it. See [Validation](validation.md).

## Modifiers

A modifier returns a new codec and leaves the original alone, so one base codec can be shared.

| Modifier | Does |
| --- | --- |
| `:validate(fn)` | Runs a check of your own on arrival. See [Validation](validation.md). |
| `:as(lift, lower)` | Carries your own type over a wire codec. |
| `:newest(hz?)` | Sends a set field as latest value only. See [Sets](sets.md#newest-fields). |

`:as` takes two functions. `lift` turns the decoded wire value into your type, and `lower` turns
your type back. It is also how to send a Roblox type with no codec of its own.

```lua
local UDimCodec = Lync.struct({
    scale = Lync.f32(),
    offset = Lync.int(-4096, 4096),
}):as(function(wire)
    return UDim.new(wire.scale, wire.offset)
end, function(udim)
    return { scale = udim.Scale, offset = udim.Offset }
end)
```

## Encoding without the network

`Lync.encode` turns a value into bytes, and `Lync.decode` turns them back.

```lua
local Settings = Lync.struct({
    volume = Lync.quant(0, 1, 0.01),
    keys = Lync.map(Lync.str(1, 16), Lync.str(1, 16), 0, 32),
})

local bytes = Lync.encode(Settings, { volume = 0.8, keys = { jump = "Space" } })
local settings = Lync.decode(Settings, bytes)
```

- The buffer is exactly as long as the value.
- A codec holding `inst` also returns the instances, as a second value, for that call only. Pass
  them to `decode`. Otherwise the second value is nil.
- `encode` throws on a value the codec refuses.
- `decode` runs every `:validate` and throws a readable message on bytes that do not decode or that
  have bytes left over.

!!! warning "Not a storage format"
    The bytes can change between Lync versions. Do not save them where a later build has to read
    them, such as a DataStore. Use them for bytes that live and die with one build.
