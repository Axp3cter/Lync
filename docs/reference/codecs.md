# Codecs

Every codec, the Luau type it carries, and its cost. [Codecs](../guide/codecs.md) in the guide
explains how to choose. Rules on parameters are under [Limits](limits.md#codecs).

## Numbers

| Codec | Type | Cost | Notes |
| --- | --- | --- | --- |
| `int(min, max)` | `number` | Bits to count `max - min + 1` values | Refuses a fraction. |
| `quant(min, max, step)` | `number` | Bits to count the steps | Rounds to the nearest step. |
| `angle(degrees)` | `number` | Bits to count `360 / degrees` values | Wraps at a whole turn. `degrees` must divide 360. |
| `f32()` | `number` | 32 bits | About 7 significant digits. |
| `f64()` | `number` | 64 bits | About 15 significant digits. |
| `vlq()` | `number` | 1 byte per 7 bits of value, up to 8 bytes | Whole, from 0, below 2^53. |
| `vli()` | `number` | The same, with a sign | Whole, magnitude below 2^53. |
| `bool()` | `boolean` | 1 bit | |
| `empty()` | `nil` | Nothing | A whole packet or query payload only. |

## Text

| Codec | Type | Cost | Notes |
| --- | --- | --- | --- |
| `str(min, max)` | `string` | The length, then 8 bits per byte | Length in bytes. |
| `str.alphabet(symbols, min, max)` | `string` | The length, then the bits to count `symbols` per character | Only characters from `symbols`. |
| `buffer(min, max)` | `buffer` | The length, then the bytes | |

`Lync.str.alphabet("0123456789abcdef", 32, 32)` is a 32-character hex string at 4 bits per
character, 16 bytes in all.

## Roblox

| Codec | Type | Cost | Notes |
| --- | --- | --- | --- |
| `vec2(component?)` | `Vector2` | Two components | Each is `f32`, or the codec given. |
| `vec3(component?)` | `Vector3` | Three components | The same. |
| `vec3.unit(degrees)` | `Vector3` | 2 bytes at 1° | A direction. Any nonzero vector is normalized when sent. |
| `cframe(position, rotation)` | `CFrame` | Both codecs | A position codec and a rotation codec. |
| `rotation.quat(degrees)` | `CFrame` | 4 bytes at 0.5° | Any rotation, at that precision. |
| `rotation.none()` | `CFrame` | Nothing | No rotation. |
| `color3()` | `Color3` | 96 bits | Three floats. |
| `color3.rgb565()` | `Color3` | 16 bits | |
| `inst(class?)` | `Instance?` | A small index. The instance travels beside the buffer. | Arrives as nil if the receiver cannot see it. With `class`, an instance that is not `:IsA(class)` is refused. |

```lua
Lync.cframe(Lync.vec3(Lync.quant(-512, 512, 0.1)), Lync.rotation.quat(0.5))
```

## Composites

| Codec | Type | Cost | Notes |
| --- | --- | --- | --- |
| `struct({ name = codec })` | `{ name: T }` | Its fields, packed together | Every field is required unless `optional`. An undeclared field is refused. |
| `array(codec, min, max)` | `{ T }` | The count, then each element | |
| `map(key, value, min, max)` | `{ [K]: V }` | The count, then each pair | |
| `optional(codec)` | `T?` | A presence bit, then the value if present | |
| `tagged(field, { name = struct })` | A union of the variants | The variant, then its fields | The variant's name is read from and written to `field`. |
| `enum({ "a", "b" })` | `"a" \| "b"` | Bits to count the names | |
| `bitfield({ "a", "b" })` | `{ a: boolean, b: boolean }` | 1 bit per name | |

A tagged union:

```lua
Outcome = Lync.packet(Lync.tagged("kind", {
    hit = Lync.struct({ target = Lync.int(0, 255) }),
    miss = Lync.struct({ at = Lync.vec3() }),
})),
```

```lua
-- After Lync.start():
Net.Outcome:fireClient(player, { kind = "hit", target = 4 })
```

## Modifiers

| Modifier | Applies to | |
| --- | --- | --- |
| `:validate(fn)` | Any codec outside a set. | `fn(value, context)` returns nil to accept or a string to drop. Runs on arrival and in `decode`. |
| `:as(lift, lower)` | Any codec. | `lift` turns the decoded value into your type, `lower` turns it back. |
| `:newest(hz?)` | A set's own fields. | Only the latest value is sent, at most `hz` times a second. |
