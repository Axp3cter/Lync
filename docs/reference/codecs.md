# Codecs

A codec defines how a value is validated, encoded and decoded. Sending a value outside the
codec's bounds throws. Receiving one drops it.

## Numbers

| Codec | Type | |
| --- | --- | --- |
| `int(min, max)` | `number` | Whole, bounded. |
| `quant(min, max, step)` | `number` | Rounded onto a grid of `step`. |
| `angle(degrees)` | `number` | Cyclic, wraps at a whole turn, at that precision. |
| `f32()` `f64()` | `number` | Roughly 7 and 15 digits. |
| `vlq()` `vli()` | `number` | Unbounded integers exact to 2^53, unsigned and signed. |
| `bool()` | `boolean` | One bit. |
| `empty()` | `nil` | No payload. |

The wire size of some examples.

| Codec | Bits |
| --- | --- |
| `int(0, 100)` | 7 |
| `quant(-512, 512, 0.1)` | 14 |
| `angle(1)` | 9 |
| `f32()` | 32 |

## Text

| Codec | Type | |
| --- | --- | --- |
| `str(min, max)` | `string` | Byte length bounded. |
| `str.alphabet(symbols, min, max)` | `string` | Only the given characters are allowed. A smaller set takes fewer bits per character. |
| `buffer(min, max)` | `buffer` | Opaque bytes, length bounded. |

A 32 character hex string. Each character takes 4 bits, so the whole string takes 16 bytes.

```lua
Lync.str.alphabet("0123456789abcdef", 32, 32)
```

## Roblox

| Codec | Type | |
| --- | --- | --- |
| `vec2(component?)` `vec3(component?)` | `Vector2` `Vector3` | `f32` per component, or one codec for every component. |
| `vec3.unit(degrees)` | `Vector3` | A direction at the given precision. Any nonzero vector is normalized when encoded. |
| `cframe(position, rotation)` | `CFrame` | A position codec paired with a rotation codec. |
| `rotation.none()` | `CFrame` | No rotation at all. |
| `rotation.quat(degrees)` | `CFrame` | Any rotation, at that precision. |
| `color3()` | `Color3` | Three floats. |
| `color3.rgb565()` | `Color3` | One 16 bit word. |
| `inst(class?)` | `Instance?` | Always optional. If the instance is not replicated to the receiver, it receives nil. |

A CFrame with the position quantised to 0.1 and the rotation to half a degree, and a reference to
a part.

```lua
Lync.cframe(Lync.vec3(Lync.quant(-512, 512, 0.1)), Lync.rotation.quat(0.5))
Lync.inst("BasePart")
```

Other Roblox types such as UDim2, Region3 and Ray can be sent through `:as`, described below.

## Composites

| Codec | Type | |
| --- | --- | --- |
| `struct({ name = codec })` | `{ name: T }` | Named fields. A field that is not declared throws when encoded. |
| `array(codec, min, max)` | `{ T }` | Count bounded. |
| `map(key, value, min, max)` | `{ [K]: V }` | Count bounded. |
| `optional(codec)` | `T?` | May be absent. |
| `tagged(field, { name = struct })` | union | One struct per variant. The variant's name is stored in `field`. |
| `enum({ "a", "b" })` | `"a" \| "b"` | One of a fixed set. |
| `bitfield({ "a", "b" })` | `{ a: boolean, b: boolean }` | One bit per flag. |

A tagged union, and a value that matches its `hit` variant.

```lua
Outcome = Lync.tagged("kind", {
    hit  = Lync.struct({ target = Lync.int(0, 255) }),
    miss = Lync.struct({ at = Lync.vec3() }),
}),
```

```lua
Net.Outcome:fireClient(player, { kind = "hit", target = 4 })
```

## Modifiers

A modifier returns a new codec. The codec it was called on is not changed.

| Modifier | Scope | |
| --- | --- | --- |
| `:validate(fn)` | any | Adds a check. `fn(value, context)` returns nil to accept or a string to reject. See [Validation](../guide/validation.md). |
| `:as(lift, lower)` | any | Converts between the wire type and a type of your own. |
| `:newest(hz?)` | set fields | Only the latest value is delivered. `hz` limits the send rate. |

`:as` takes two functions. The first converts a decoded wire value to your type. The second
converts your type back to the wire value.

```lua
Fraction = Lync.int(0, 255):as(
    function(byte)
        return byte / 255
    end,
    function(fraction)
        return math.round(fraction * 255)
    end
),
```

```lua
UDim = Lync.struct({ scale = Lync.f32(), offset = Lync.int(-4096, 4096) }):as(
    function(wire)
        return UDim.new(wire.scale, wire.offset)
    end,
    function(udim)
        return { scale = udim.Scale, offset = udim.Offset }
    end
),
```

Using a set only modifier such as `:newest` inside a packet or query throws at `start`.
