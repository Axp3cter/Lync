# Codecs

A codec says how one value validates, encodes and decodes. Out of range throws on the way out and
drops on the way in.

## Numbers

| | Type | |
| --- | --- | --- |
| `int(min, max)` | `number` | Whole, bounded. |
| `quant(min, max, step)` | `number` | Rounded onto a grid. |
| `angle(degrees)` | `number` | Cyclic, wraps at a whole turn. |
| `f32()` `f64()` | `number` | Roughly 7 and 15 digits. |
| `vlq()` `vli()` | `number` | Unbounded integers exact to 2^53, unsigned and signed. |
| `bool()` | `boolean` | One bit. |
| `empty()` | `nil` | No payload. |

```lua
Lync.int(0, 100)            -- 7 bits
Lync.quant(-512, 512, 0.1)  -- 14 bits
Lync.angle(1)               -- 9 bits
Lync.f32()                  -- 32 bits
```

## Text

| | Type | |
| --- | --- | --- |
| `str(min, max)` | `string` | Byte length bounded. |
| `str.alphabet(symbols, min, max)` | `string` | Only those characters. Smaller set, fewer bits per character. |
| `buffer(min, max)` | `buffer` | Opaque bytes. |

```lua
Lync.str.alphabet("0123456789abcdef", 32, 32)  -- 4 bits a character, 16 bytes total
```

## Roblox

| | Type | |
| --- | --- | --- |
| `vec2(c?)` `vec3(c?)` | `Vector2` `Vector3` | `f32` per component, or one codec for each. |
| `vec3.unit(degrees)` | `Vector3` | A direction. Any nonzero vector normalizes at encode. |
| `cframe(position, rotation)` | `CFrame` | A position codec with a rotation codec. |
| `rotation.none()` `.quat(degrees)` | `CFrame` | No degrees of freedom, or three. |
| `color3()` `.rgb565()` | `Color3` | Floats, or one 16 bit word. |
| `inst(class?)` | `Instance?` | Always optional. A receiver that cannot see it gets nil. |

```lua
Lync.cframe(Lync.vec3(Lync.quant(-512, 512, 0.1)), Lync.rotation.quat(0.5))
Lync.inst("BasePart")
```

UDim2, Region3, Ray and the rest go over with `:as`.

## Composites

| | Type | |
| --- | --- | --- |
| `struct({ k = c })` | `{ k: ... }` | An undeclared field throws on encode. |
| `array(c, min, max)` | `{ T }` | Count bounded. |
| `map(k, v, min, max)` | `{ [K]: V }` | Count bounded. |
| `optional(c)` | `T?` | |
| `tagged(field, { k = c })` | union | One struct per variant, the name in `field`. |
| `enum({ "a", "b" })` | `string` | |
| `bitfield({ "a", "b" })` | `{ a: boolean }` | One bit each. |

```lua
Lync.tagged("kind", {
    hit  = Lync.struct({ target = Lync.int(0, 255) }),
    miss = Lync.struct({ at = Lync.vec3() }),
})
-- { kind = "hit", target = 4 }
```

## Modifiers

| | Scope | |
| --- | --- | --- |
| `:validate(fn)` | any | `fn(value, ctx)` returns nil to pass or a reason to drop. |
| `:as(to, from)` | any | The wire type to and from your own. |
| `:newest(hz?)` | set fields | Only the latest matters. `hz` caps the rate. |

```lua
local Fraction = Lync.int(0, 255):as(
    function(byte) return byte / 255 end,  -- wire to yours
    function(fraction) return math.round(fraction * 255) end
)

local UDim = Lync.struct({ s = Lync.f32(), o = Lync.int(-4096, 4096) }):as(
    function(w) return UDim.new(w.s, w.o) end,
    function(u) return { s = u.Scale, o = u.Offset } end
)
```

A modifier answers a new codec. A set marker inside a packet or query throws at start.
