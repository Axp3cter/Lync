# Limits

Every limit Lync enforces, what happens when you reach it, and whether you can change it.

Limits are **fixed** when both machines must agree on them, or when they protect the server from a
client. Everything you can change is a codec bound, a count, or an argument you pass, and the last
column says which.

## Declaring

These are checked when a codec is constructed, when `define` runs, or when `start` compiles the
schema. `Lync.encode` and `Lync.decode` apply the codec checks the first time they see a codec.

### Codecs

| Limit | Value | At the limit | Instead | Set by |
| --- | --- | --- | --- | --- |
| Steps in an `int`, `quant` or `angle` | Under 2^53 | `start` throws. | Narrow the range or coarsen the step. Use `f64` for an unbounded number. | Codec bounds |
| `int` bounds | Whole, `min <= max` | The constructor throws. | | Codec bounds |
| `quant` bounds | Finite, `min <= max`, step above 0 | The constructor throws. | | Codec bounds |
| Angle precision (`angle`, `vec3.unit`, `rotation.quat`) | Above 0, up to 360 | The constructor throws. | | Codec precision |
| `angle` precision | Must divide 360 | `start` throws. | Use a divisor such as 0.5, 1, 2 or 5. | Codec precision |
| `rotation.quat` precision | Its components must fit in 24 bits, so nothing finer than about 0.00002° | `start` throws. A packed value cannot mix parts wider and narrower than 24 bits. | Use a coarser precision. | Codec precision |
| Counts of `str`, `str.alphabet`, `buffer`, `array`, `map` | Whole, from 0, `min <= max` | The constructor throws. | | Codec counts |
| `str.alphabet` symbols | At least one, each byte once | The constructor throws. | | Codec |
| `enum` and `bitfield` names | At least one, each a string, each once | The constructor throws. | | Codec |
| `tagged` variants | At least one. Each is a `struct` that does not declare the tag field. The tag is a non-empty string. | The constructor throws. | | Codec |
| `inst` class | A non-empty string | The constructor throws. | Omit it to accept any instance. | Codec |
| `inst` as a `map` key | Refused | The constructor throws. | Key the map by an id and carry the instance as the value. | Fixed |
| `optional` placement | Not directly inside `array`, `map`, `optional`, `vec2`, `vec3` or `cframe` | The constructor throws. | Put it in a `struct` field. | Fixed |
| `empty` placement | Only as a whole packet or query payload | The constructor throws. | | Fixed |
| `:newest` placement | Only on a set's own fields | `start` or `encode` throws. | Use a `newest` packet. | Fixed |
| `:newest(hz)` and `packet:newest(hz)` rate | Above 0 and finite | The call throws. | Omit `hz` for no cap. | The `hz` you pass |

### Sizes

| Limit | Value | At the limit | Instead | Set by |
| --- | --- | --- | --- | --- |
| Worst case of one packet payload, request, reply or set record | 1,000,000 bytes (1 MB) | `start` throws. | Lower the maximum counts. | Codec counts |
| `unreliable` and `newest` packets | 1000 bytes worst case, header included | `start` throws. | Narrow the codec, or make the packet reliable. | Codec bounds |
| A set's `newest` field | 1000 bytes for one record of it, header and key included | `start` throws. | Narrow the field, or drop `:newest`. | Codec bounds |

`Lync.encode` has no size limit of its own. The 1 MB limit belongs to remote calls.

### Definitions

| Limit | Value | At the limit | Instead | Set by |
| --- | --- | --- | --- | --- |
| Fields per set | 1 to 64 | `start` throws. | Group fields in a nested `struct`, which counts as one field and is sent whole when any part changes. Or split the set. | Fixed |
| Set key | A field of kind `bool`, `int`, `enum`, `vlq`, `vli` or `str`. Not `optional`, not `:newest`, not `:as`. | `start` throws. | Key by an exact id and keep the lossy value as another field. | Fixed |
| `:validate` in a set record | Refused at any depth | `start` throws. | Check input where it enters, in a packet or query. | Fixed |
| `unreliable` with `newest` | Refused | `start` throws. | Choose one. | Fixed |
| Namespace name | A non-empty string with no `;` or `=`, used once | `define` throws. | | Fixed |
| Definition name | No `;` or `=` | `start` throws. | | Fixed |
| Definition | One namespace each, and a packet, query or set | `define` throws. | | Fixed |
| `define` | Before `start` | `define` throws. | Require every schema module before `start`. | Fixed |
| Query responder | One per side, before `start` | The second registration, or one after `start`, throws. | | Fixed |

## Running

These apply while the game runs.

### Values

| Limit | Value | At the limit | Instead | Set by |
| --- | --- | --- | --- | --- |
| Set ids, `vlq`, `vli` | Whole, magnitude under 2^53. `vlq` starts at 0. | The call throws. | Carry larger values as a `str` or `buffer`. | Fixed |
| Any value against its codec | The codec's bounds and counts | The call throws on sending. The value is dropped on arrival. | See [Validation](../guide/validation.md). | Codec |

### Sending

| Limit | Value | At the limit | Instead | Set by |
| --- | --- | --- | --- | --- |
| One remote call | 1,000,000 bytes | A larger flush is split across calls, in order. | | Fixed |
| Set state per flush | 32 KB per second since the last flush, per client, at least 1024 bytes | The rest waits for later flushes, in order. Packets, requests and replies are never held. | Pass a larger budget, or move bulky sets to a namespace flushed on its own. | `flush(budget)`, `flush(name, budget)` |
| Budget floor | 1024 bytes | `flush` throws. | | Fixed |
| State section | 1024 bytes. A larger record goes alone. | State is sent and budgeted a section at a time. | | Fixed |
| Unflushed queue | 1 s | An error is logged, naming the definition. | Flush every frame. | Fixed |

### Requests

| Limit | Value | At the limit | Instead | Set by |
| --- | --- | --- | --- | --- |
| Request timeout | 10 s by default. Must be positive and finite. | The request ends with `"timeout"`. A bad timeout throws at the call. | Pass a timeout. | The `timeout` argument, per call |
| Requests in flight | 32768 per namespace, on each machine | The next `request` throws. | Wait for requests to end before making more. | Fixed |
| Running responders | 64 per client, per namespace | Further requests from that client end `"unanswered"` without running the responder. | | Fixed |

### Arrival

| Limit | Value | At the limit | Instead | Set by |
| --- | --- | --- | --- | --- |
| Frames held before joining | 64 reliable frames per client | The client drops later ones with a `drop.unready` warning. | | Fixed |
| `newest` order | A window of 32768 sends | An arrival 32768 or more sends away from the last one read counts as old and is dropped. | | Fixed |
| Timestamps | 1 ms resolution in 24 bits, so they wrap every 4.66 hours | A stamp is read against its arrival time, so it is correct for anything that arrives within 2.3 hours of being sent. | | Fixed |
| Client timestamps | Clamped to between 60 s before arrival and arrival | A client cannot claim a send time in the future or long past. | | Fixed |
| Drop warnings from one client | 8 per code per 10 s, per namespace | The rest are counted and logged as one summary when the window reopens or the player leaves. | | Fixed |
| "Nothing listens" warnings from clients | Once per definition | Repeats are silent until a listener attaches. | | Fixed |
