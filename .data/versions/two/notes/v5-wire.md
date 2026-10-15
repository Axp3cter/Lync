# Lync v5: wire format and compression

Design for review. It builds on [v5-api.md](v5-api.md), [v5-research.md](v5-research.md),
[v4-inventory.md](v4-inventory.md) and [v5-goals.md](v5-goals.md). Security is out of scope, except
where a decoder refusal is part of the format.

**Evidence labels.**
- **Verified:** Studio facts from research §6: zstd on remote buffers, the 1000 B limit counted after
  compression, about 6 B of call overhead plus the remote name's length.
- **Offline:** run here, with CPython 3.14's libzstd (level 3) as a stand-in and Monte Carlo geometry.
  Roblox's zstd level and size threshold are unknown, so offline numbers show ordering, not Roblox
  bytes. Workload parameters are in Appendix A.
- **Provisional:** a default pending the Studio measurement named beside it (§12).

No Studio instance was connected (`list_roblox_studios` returned none), so nothing was measured on
Roblox beyond the verified facts.

**Claims.** `W-n` is one testable statement. Tests tag the claims they prove. "Refuse" means the
decoder drops the rest of the frame (W-15).

## 1. Decisions

| # | Decision | Why |
|---|---|---|
| D-1 | A frame is one dense bit stream, least significant bit first. Only string and buffer bytes are byte-aligned. | Offline: padding costs 4% to 27% and zstd recovers none of it on high-entropy fields (§2). Aligned blobs allow a copy and stay visible to zstd. |
| D-2 | Redundancy is removed by schema-aware coding before zstd sees it: column modes (runs, delta, state delta), Exp-Golomb codes, change masks. No byte-oriented entropy coder of our own. | Offline: column modes beat the best zstd layout 1.2 to 2.6 times on structured columns and cost 2 bits on random ones. |
| D-3 | Three remotes per place, shared by every namespace, one-character names. | One call overhead (9 to 14 B) per lane per flush instead of per namespace; the unreliable overhead grows with the name. |
| D-4 | One call per recipient per lane per flush. Blocks keep issue order. One definition-id table per namespace serves both lanes. | v4 promised order across definitions. One table lets an oversize unreliable message demote to reliable. |
| D-5 | Collections are slot-addressed, partitioned, column-coded, and delta-coded against the previous reliable state. No acks. | Reliable ordering makes the receiver's state equal the sender's. Sections are the same for every viewer, so they are encoded once. |
| D-6 | `latest` fields send absolute values, an 8-bit send sequence, and a reliable settle. Baseline deltas stay an extension until M-6. | Offline: a delta against a baseline 1 to 8 sends old saves 46% to 64% of a position update before baseline traffic, but real motion and loss data decide (M-6). |
| D-7 | An unreliable message that cannot fit one call is demoted to the reliable lane. | Total behaviour: no throw on data-dependent size and no reassembly state. |
| D-8 | Timestamps are 16-bit milliseconds of `GetServerTimeNow`, once per block, offsets after. | No epoch exchange; tolerates 32 s of clock skew. |
| D-9 | The handshake verifies the schema and never transfers it. | [v5-api.md](v5-api.md) §7.1. |
| D-10 | Accuracy is opt-in by parameter. A bare `angle`, `direction` or `rotation` is exact. | Goal 1: exact by default. |
| D-11 | An encoder may always choose the plain mode; a decoder accepts every mode. | CPU relief valve with no format change. |

## 2. Bit packing and zstd

**Model.** Roblox zstd-compresses each call (verified: zeros 240 to 2.8 KB/s, random unchanged). A
random 990 B buffer plus a 9-character tag came to 1005 B, so overhead beyond content is 6 B. A zstd
frame alone needs about 9 B (offline: the stand-in adds 9 B to random input). So Roblox passes
incompressible buffers through, and a call costs `overhead + min(length, zstd(frame))`. M-1 confirms.
Two consequences:
- a dense, random-looking frame pays nothing extra;
- whatever zstd can remove must be visible to it as byte-level repetition.

**Offline, whole frames** (bytes after `min(raw, zstd)`, K records, 40 trials):

| Workload | Dense | Record-aligned | Byte-wide fields |
|---|---|---|---|
| Snapshot, K=64 | 584 | 640 | 710 |
| Events, K=200 | 450 | 528 | 571 |
| Delta stream, K=200 | 711 | 736 | 821 |
| 5-bit tiles with runs, K=1000 | 365 | 234 | 234 |

**Offline, one column of 256 values** (bytes):

| Column | Own column mode | Packed + zstd | Byte-aligned + zstd |
|---|---|---|---|
| 5-bit tiles with runs | 38 (RUNS) | 123 | 90 |
| Sorted 11-bit ids | 142 (DELTA) | 352 | 434 |
| 10-bit height walk | 121 (DELTA) | 319 | 313 |
| 7-bit health, 80% equal | 112 (RUNS) | 178 | 134 |
| Random 14-bit (control) | 448 (PACKED) | 448 | 512 |

**Reading.**
1. On high-entropy fields padding is pure loss: record-aligned costs 4% to 17% more, byte-wide 15%
   to 27%. zstd recovers part of the byte-wide waste on frames of 256 B or more (events: 800 B raw to
   571), never all of it, and almost nothing up to 100 B.
2. Packing does not hide periodic repetition: a run of identical records keeps a byte period of
   `lcm(bits, 8) / 8`, which zstd matches. It hides equal values separated by other fields at
   different bit phases.
3. Column modes put equal and near values side by side and code them directly. That left nothing
   for zstd to find, and beat its best result 1.2 to 2.6 times.
4. Where aligned plus zstd won (tiles, 36% under dense), RUNS beat it by 2.4 times.

**Rules that follow.**
- R-1: dense stream (D-1).
- R-2: structure first (D-2); zstd sees only the residue.
- R-3: align string and buffer bytes, so zstd can see repeated text and a copy replaces a per-byte shift.
- R-4: batch hard. Call overhead is fixed, zstd gains grow with size, and one call per lane (W-7)
  makes frames as large as the flush allows.

**When to revisit.** M-1 reruns the layout comparison on Roblox's real zstd. An aligned layout
becomes protocol version 2 if it wins by 8% after column modes on two reference workloads.

## 3. Transport and framing

| ID | Claim |
|---|---|
| W-1 | A place has three Lync remotes in one Folder under ReplicatedStorage: `r` (RemoteEvent, reliable), `u` (UnreliableRemoteEvent), `h` (RemoteEvent, handshake). Names are one character (provisional, M-2). The server creates them before it answers a hello. |
| W-2 | Every call on `r` and `u` is `(frame: buffer, instance1, instance2, ...)`. Instances are variadic arguments, not a table (provisional, M-2). |
| W-3 | A frame is a bit stream, least significant bit first: stream bit `i` is bit `i mod 8` of byte `i div 8`. A field of width `w` at offset `p` fills bits `p` to `p+w-1`, its own least significant bit first. |
| W-4 | A field wider than 32 bits (at most 53) is written as its low 32 bits, then the rest. A mask wider than 32 bits is written in 32-bit chunks, low first. |
| W-5 | A frame's first 3 bits hold `P`, the count of padding bits in its last byte. The stream ends at bit `8 x length - P`. Padding bits are zero. A frame with nonzero padding, or whose last block runs past the stream, is refused. |
| W-6 | A frame holds blocks back to back until the stream ends. A sender never sends a frame with no block. A receiver drops a zero-length frame. |
| W-7 | Per flush a sender makes at most one call per recipient per lane, carrying every block queued for that recipient and lane, subject to W-9 and W-10. |
| W-8 | Reliable blocks keep the order issued, across definitions and across events, requests, responses and collection sections. A collection section is open to coalescing only while it is the last block of the frame; any later block closes it. |
| W-9 | A reliable call carries at most 16 384 B (provisional, M-4). A block that would pass the cap starts the next call, and calls go out in order. A run (W-56) is cut between messages and a collection section by slot. One message larger than the cap travels alone up to 1 MiB; larger is refused at the call site. |
| W-10 | An unreliable call carries at most `985 - 6 x I` bytes of frame, `I` being its instance arguments (1000 - 6 overhead - 1 name - 8 margin; provisional, M-2). Cuts follow W-9. |
| W-11 | Instance arguments are deduplicated by identity within a call. A call carries at most 64 (provisional, M-2); a block that needs more starts a new call. |
| W-12 | A block header is: a same-namespace bit; if 0, a 4-bit namespace slot; then the definition id in `bits(n-1)` bits, `n` being the definitions of that namespace. The first block of a frame is compared with slot 0. |
| W-13 | Definition ids follow ascending byte order of definition names within a namespace. A request and a collection take one id each. |
| W-14 | One id table serves both lanes, so every block is valid on either lane. |
| W-15 | Blocks have no length prefix. A refusal inside a block drops the rest of the frame. |

**Block bodies by definition kind**

| Kind | After the header |
|---|---|
| event, unreliable event | run (W-56) |
| latest event | sequence, stamp if timestamped, one message (W-60) |
| request, response | direction bit, run (W-76) |
| collection | kind, partition key, body (W-63) |

## 4. Primitive codes

| ID | Claim |
|---|---|
| W-16 | `bits(n)` is the bit length of `n`, 0 for 0. A bounded integer of span `s = max - min` is `value - min` in `bits(s)` bits; span 0 is 0 bits. |
| W-17 | Exp-Golomb of order `k` (EG-k) for `u >= 0`: with `m = (u >> k) + 1` and `L = bits(m) - 1`, write `L` one bits, a zero bit, the `L` low bits of `m`, then the `k` low bits of `u`. EG-0 of 0 is 1 bit, of 1 is 3 bits. `u` is below 2^53; an `L` over 53 is refused. |
| W-18 | Zigzag is `2v` for `v >= 0` and `-2v - 1` for `v < 0`. |
| W-19 | A class code carries an unbounded signed integer: a 4-bit class `c`, the magnitude in `W[c]` bits with `W = {0,1,2,3,4,5,6,8,10,12,16,20,24,32,40,53}`, then a sign bit (1 = negative) only if the magnitude is above 0. The encoder uses the smallest fitting `c`; the decoder refuses any other. Range is plus or minus (2^53 - 1). |
| W-20 | A count or length with declared maximum `M` below 256 is `bits(M)` bits (0 for `M = 0`); otherwise it is EG-0. A count above `M` is refused. |
| W-21 | A count whose smallest possible encoding exceeds the bits left is refused before anything is allocated. |

Costs of W-19 (bits): 0 is 4; 1 is 6; 100 is 13; 1000 is 15; 50 000 is 21; 10^9 is 37.

## 5. Codecs

| ID | Claim |
|---|---|
| W-22 | `boolean`: 1 bit. |
| W-23 | `integer(min, max)`: W-16. A non-whole or out-of-range value is refused at encode. |
| W-24 | `integer()`: W-19. |
| W-25 | `number()`: a 2-bit form. 0: a finite whole value below 2^53 in magnitude, not -0, as a class code. 1: a value float32 holds exactly, infinities included: 32 bits. 2: any other double, its IEEE 754 low 32 bits then high 32 bits. 3: NaN, no payload. The encoder picks the smallest form, ties to the lower number. |
| W-26 | `number(min, max, step)`: `points = floor((max - min) / step + 1e-9) + 1`. The index is `round((v - min) / step)` in `bits(points - 1)` bits; the value is `min + index x step`. A value more than half a step outside the range is refused; otherwise it clamps. |
| W-27 | `number(step)`: a class code of `round(v / step)`; the value is `index x step`. |
| W-28 | `vector2`, `vector3` bare: each component a 32-bit float. With `(min, max, step)`: each component as W-26, x then y then z. |
| W-29 | `angle(step)`: `points = ceil(360 / step - 1e-9)`. The index is `round((v mod 360) / 360 x points) mod points` in `bits(points - 1)` bits; the value is `index x 360 / points`. Bare `angle`: `v mod 360` as W-25. |
| W-30 | `direction(step)`: `b = clamp(ceil(log2(256 / step)), 2, 16)`. Fold the unit vector: `(u, v) = (x, y) / (|x| + |y| + |z|)`, and if `z < 0`, `(u, v) = ((1 - |v|) s(u), (1 - |u|) s(v))` with `s(t) = 1` for `t >= 0`, else -1. Each of `u`, `v` is `round((t + 1) / 2 x (2^b - 1))` in `b` bits. Decode unfolds and normalizes. Bare: the normalized vector as 3 floats. A zero vector is refused. Offline worst error is under `256 / 2^b` degrees. |
| W-31 | `rotation(step)`: `b` as W-30. With the unit quaternion signed so its largest-magnitude component is positive, write that component's index in 2 bits (ties to the lowest), then the other three in index order, each `round((c + s) / (2s) x (2^b - 1))` in `b` bits with `s = 2^-1/2`. The dropped component decodes as `sqrt(max(0, 1 - sum of squares))`. Offline worst error is under `256 / 2^b` degrees. |
| W-32 | Bare `rotation`: 1 bit "axis-aligned" (matrix entries exactly 0 or plus or minus 1). If 1, a 5-bit index into the 24 such rotations ordered lexicographically by their row-major entries, with -1 < 0 < 1. If 0, the 2-bit index and three 32-bit floats. |
| W-33 | `cframe(position, rotation)`: the position codec, then the rotation codec. Bare: bare `vector3`, bare `rotation`. |
| W-34 | `color3(step)`: `points = floor(1 / step + 1e-9) + 1`; red, green, blue each `round(c / step)` in `bits(points - 1)` bits. Bare: 3 floats. |
| W-35 | `string(maxBytes)` and `buffer(maxBytes)`: the length per W-20, then, if it is above 0, zero bits up to the next byte boundary and the raw bytes. |
| W-36 | `enum.X`: the item's index in the generated table's item list sorted by `Value` (never the live item list), in `bits(count - 1)` bits. A value outside the table is refused at encode and decode. |
| W-37 | `oneOf`: the index in ascending byte order of the names, in `bits(n - 1)` bits. |
| W-38 | `instance`: an EG-0 slot, 0 for nil, `i` for the `i`-th instance argument of the call. A typed instance is checked with `IsA` on arrival. An instance the receiver cannot see arrives as nil. |
| W-39 | A record: its fields in ascending name order, concatenated, with no names, tags or padding. No fields is 0 bits. |
| W-40 | `optional`: 1 presence bit, then the value if 1. |
| W-41 | `flags`: one bit per name in ascending name order, 1 for true. |
| W-42 | `union`: the variant index in ascending name order in `bits(v - 1)` bits, then that variant's record. `kind` is implied. |
| W-43 | `array(codec, maxCount)`: the count per W-20, then the elements: gridded elements form one column (W-49), record elements follow W-48. |
| W-44 | `map(key, value, maxCount)` is an array of `{ key, value }` records in strictly ascending key order: numbers by value, strings by bytes, enums and `oneOf` by index. A repeated or out-of-order key is refused. |
| W-45 | `convert(wire, ...)`: the wire codec's encoding. |
| W-46 | A quantized decode is one multiply-add on the integer index and the declared parameters. Change detection compares indices. No codec state depends on two machines agreeing on a float. |

## 6. Column coder

A column is one field's values across the elements of an array, the records of an ADD, or the
slots of an UPDATE.

| ID | Claim |
|---|---|
| W-47 | A codec is gridded when it has at most 4 components, each a finite grid of at most 2^32 points: `boolean`, bounded `integer`, quantized `number`, quantized `vector`, `angle(step)`, quantized `color3`, quantized `direction` (2 components), quantized `rotation` (tag and 3), `oneOf`, `enum`, `flags` up to 32. Everything else is not. |
| W-48 | Record elements are written field by field: for each field in ascending name order, that field's value for every element. A field that is not gridded writes its values element by element. |
| W-49 | A gridded field of 4 or more elements starts with a 2-bit mode: 0 PACKED, 1 RUNS, 2 DELTA, 3 STATE (W-68 only; refused elsewhere). In an UPDATE the mode is always present. With fewer than 4 elements outside an UPDATE there is no mode and the column is PACKED. RUNS, DELTA and STATE add a 4-bit `k`. |
| W-50 | PACKED: each element's indices at their bit widths, component by component. |
| W-51 | RUNS: pairs of (the element's indices, EG-k of run length - 1) until `n` elements are covered. A run past `n` is refused. |
| W-52 | DELTA: the first element as PACKED, then each component as EG-k of `zigzag(index - previous element's index)`. A cyclic grid (`angle`) takes the difference modulo its points into `[-points / 2, points / 2)`. |
| W-53 | STATE: every element as DELTA against the record's current indices; none is PACKED. |
| W-54 | The decoder refuses an index outside its grid. |
| W-55 | The encoder emits the mode with the fewest exact bits, trying each `k` from 0 to 15, ties to the lower mode. A column is never more than 2 bits larger than PACKED. The decoder accepts every mode, so encoder policy never changes decodability. |

## 7. Events, unreliable and latest

| ID | Claim |
|---|---|
| W-56 | An event block carries a run: EG-0 of `count - 1`, then the messages back to back. Consecutive fires of one definition to one recipient share a block. A message with no payload is 0 bits. |
| W-57 | A timestamped block holds, after the count, a 16-bit stamp of its first message, `floor(GetServerTimeNow() x 1000) mod 65536`. Each later message is preceded by EG-2 of its millisecond offset from the previous message, never negative. |
| W-58 | A receiver recovers a stamp as the value congruent to it modulo 65536 nearest its own `floor(GetServerTimeNow() x 1000)`. `sentAt` is that value over 1000. It is right while the clocks agree within 32 s. |
| W-59 | An unreliable event goes on `u` with no sequence. Order and duplicates are unspecified. |
| W-60 | A latest event is a block with no count: header, 8-bit sequence, a stamp if timestamped, one message. A recipient gets at most one per definition per flush, and the newest message wins. |
| W-61 | The sequence counts the latest blocks sent for (definition, recipient) from 0 modulo 256, on either lane. A receiver keeps the last accepted sequence per (definition, sender) and accepts a block when `(s - last) mod 256` is 1 to 127. The first block is always accepted. |
| W-62 | A message that cannot fit an unreliable call alone (W-10) is sent as the same block on `r`. It consumes a sequence number if latest, and is counted as `Oversize`. |

## 8. Collections

Offline (walking trajectories, 14-bit axes): delta coding with `k = 2` cut a vector3 update from 42 to
16.0, 13.6 and 10.8 bits at 10, 20 and 60 Hz (62% to 74%), before the 6-bit column header of W-49.

| ID | Claim |
|---|---|
| W-63 | A collection block is: header, a 3-bit kind (0 ADD, 1 UPDATE, 2 REMOVE, 3 CLEAR, 4 LATEST; others refused), the partition key in its own codec if the collection has a partition field, then the body. One section per block. |
| W-64 | A slot is a small integer per (collection, partition), assigned by the server (lowest free) and identical for every viewer. A client maps id to slot from ADD; REMOVE frees the slot; an unknown slot is refused. |
| W-65 | A SlotSet is: count as EG-0; if the count is above 1, a 4-bit `k` (else `k = 0`); then the ascending slots, the first as EG-k and each next as EG-k of `slot - previous - 1`. |
| W-66 | ADD is: an 8-bit stream sequence if the collection has latest fields; a SlotSet; the ids column (W-67); then each non-partition field per W-48 in slot order, latest fields included with their current absolute values. |
| W-67 | The ids column starts with 1 bit. If 0, each id is a class code. If 1, a 4-bit `k`, the first id as a class code, then EG-k of `zigzag(id - previous id)`. Ids are whole numbers below 2^51 in magnitude. |
| W-68 | UPDATE is: a SlotSet `S`; a mask with one bit per non-partition field in ascending order; if the mask touches a latest field, an 8-bit stream sequence; then, for each set field, a coverage bit (1: every slot of `S` changed it; 0: one presence bit per slot of `S` follows), then the values of the covered slots per W-48. A field is listed only if its indices changed. A gridded non-latest field may use STATE. A write that replaces an existing id is an UPDATE of the differing fields. |
| W-69 | REMOVE is a SlotSet. CLEAR has no body and removes every slot of the keyed partition. |
| W-70 | The partition field is omitted from records in a section. Changing it is REMOVE in the old partition and ADD in the new. |
| W-71 | A section depends only on the partition's state transition, never on the recipient. A catch-up ADD for a new viewer is the only recipient-specific section. |
| W-72 | LATEST (on `u`) is: 8-bit sequence, a SlotSet, a mask over the latest fields, then per set field coverage and values as in W-68, with no STATE. The blocks of one send share one sequence. A receiver accepts `s` when `(s - last) mod 256` is 0 to 127, per (collection, partition), initialised by ADD or settle. |
| W-73 | A latest field is never STATE-coded in any kind, and the decoder refuses it. |
| W-74 | Settle: a latest field sent unreliably and unchanged for 0.5 s (provisional, M-5) is sent once more as a reliable UPDATE carrying the stream's current sequence. The receiver sets its last sequence to it. |
| W-75 | A collection has at most 64 non-partition fields. One with no latest field has no sequences and never uses LATEST. |

## 9. Requests and responses

| ID | Claim |
|---|---|
| W-76 | A request definition's block adds a 1-bit direction after the header (0 request, 1 response), then a run (W-56). Either side may send either direction. |
| W-77 | A request item is an id then its payload. The first id is 12 bits; each later id is EG-0 of `(id - previous - 1) mod 4096`. |
| W-78 | A response item is a 12-bit id, a 1-bit outcome (1: the reply follows, 0: unanswered), then the reply if 1. |
| W-79 | Ids count per (sender, definition) modulo 4096. `Timeout`, `Left` and `Shutdown` never cross the wire. A response with no pending id is dropped. |
| W-80 | Requests and responses are reliable only and keep issue order (W-8). |

## 10. Handshake and schema

The API shares the schema module with both sides, so a client never learns the schema from the
server. The handshake only checks that both hold the same one.

| ID | Claim |
|---|---|
| W-81 | `h` carries only byte-aligned, little-endian messages. HELLO (client to server): u8 protocol version, u8 name length, the namespace name, u32 namespace hash. |
| W-82 | VERDICT: u8 status (0 accept, 1 hash mismatch, 2 version mismatch, 3 namespace unknown, 4 no free slot), u8 slot, u8 server version, u32 server hash. For status 1 it continues with u16 count and that many (u32 name hash, u32 definition hash) pairs. |
| W-83 | DETAIL (client to server, after status 1): u8 version, u8 name length, name, u16 count and the client's pairs. The server names the differing definitions once per distinct client hash. |
| W-84 | An accepted namespace gets the next free slot of that connection, 0 to 15. No schema bytes cross the wire on accept. |
| W-85 | A hash is FNV-1a 32. A definition's descriptor lists its name, kind, delivery flags and canonical codec tree, with every parameter that changes bits and key sets sorted. It omits validators, limits and transform functions. The namespace hash covers the sorted `name:hash` list. |
| W-86 | The protocol version is 1. Any change to a W claim bumps it. A mismatch is status 2. |
| W-87 | A sender sends no block of a namespace before its accept. A client holds up to 64 frames that arrive before the verdict. The server drops frames from clients not admitted. |

**Golden vector G-1.** A namespace of four definitions (`chat` = `string(200)`, `fighters`, `sell`,
`strike`, ids 0 to 3), namespace slot 0. Firing `chat("hi")` to a client gives the 4-byte frame
`08 01 68 69`: P = 0, same-namespace 1, id `00`, run bit 0, length 2 in 8 bits, 1 alignment bit,
`h`, `i`.

## 11. CPU, both ends

| Mechanism | Encoder | Decoder |
|---|---|---|
| Dense fields | One bit write per field (M-3) | One bit read per field |
| EG and class codes | `bit32.countlz`, one or two writes | `bit32.countrz` on the inverted word; no bit loops |
| Column modes | Up to 3 trial passes per column of 4 or more, once per partition per flush (W-71), not per recipient | One pass |
| STATE | One subtraction per value | One addition |
| Strings and buffers | `buffer.writestring` | `buffer.readstring` |
| Exact numbers | Two builtin calls to test float32 | None |
| zstd | None | None |

- Server cost grows with changes, not with changes times viewers. Only the copy of a shared block into
  each recipient's frame is per recipient. Blocks start at any bit, so that copy is a shifted word
  copy, not a memcpy. A frame identical for every recipient is built once.
- Decoding allocates only the output tables; scratch buffers are reused.
- Mechanisms the interpreter pays for on the client are kept only while M-3's return holds (§12).

## 12. Measurement plan

All run in a fresh test place in Studio, never in an existing game. "Ruler" is the method from
research §6: the unreliable drop warning prints `Payload went over by: N bytes`. Append 1100 random
bytes to a frame and fire it on `u`; then `C = N - 107`, within a few bytes, is the frame's
compressed size. Calibrate the 107 (call overhead plus filler) with an empty frame, for which `C = 0`.

| ID | Settles | Script outline | Rule and provisional default |
|---|---|---|---|
| M-1 | D-1, D-2 on real zstd; zstd threshold | For each workload of Appendix A (snapshot, events, delta stream, tiles, columns) and layout (dense, record-aligned, byte-wide), at K = 2, 8, 32, 64, 200: encode the frame and take `C` from the ruler. Run `EncodingService:CompressBuffer` at zstd levels 1, 3, 9, 19 and note which level matches the ruler. Find the smallest repetitive buffer that shrinks. | An aligned layout becomes version 2 if it beats dense by 8% after column modes on two workloads at 128 to 1000 B. Provisional: dense. |
| M-2 | Constants in W-1, W-10, W-11 | With the unreliable ruler and random buffers, find the largest passing size for: remote names of 1, 8 and 32 characters; the remote under a Folder nested 1 and 4 deep; 0, 1, 10 and 64 instance arguments, as variadics and as one table, with a nil in the middle; and the largest argument count that fires. Reliable: `Stats.DataSendKbps` over 20 s at 400 calls/s with 1 B and 1000 B random payloads, each direction. | Fixes the 985 and the 6 per instance, the 64, the name length. Provisional: 985, 6, 64, one character. |
| M-3 | Bit-I/O implementation; mechanism return | On a native server and a play-test client interpreter, with `os.clock`, batches of at least 10 ms, 9 repetitions, median and MAD. Write and read a 12-field record (widths 3, 7, 14, 14, 14, 10, 1 and so on) by `buffer.writebits`/`readbits` per field, by a 32-bit accumulator with `writeu32`, and by whole-byte fields. Time EG-k and class codes over 64 values, the float32 test, a 40-byte string at bit phase 3 (per-byte shifts against align and copy), a shifted copy of a 200 B block, and column-mode selection at n = 64. Confirm `writebits` takes 32 bits. | Picks the writer, not the format. Report bytes saved per microsecond of client decode. A mechanism that costs over 5% of frame decode time for under 3% of bytes saved becomes encoder-off (D-11). Provisional: `writebits`. |
| M-4 | W-9 cap | The server sends frames of 1, 4, 16 and 64 KB of 20-byte ADD records. The client times each decode and logs `gcinfo` growth. | Cap is the largest size that decodes in 2 ms on the interpreter. Provisional: 16 KB. |
| M-5 | Sequence width, settle delay | `NetworkSettings` with 0.5% loss, 100 ms delay, 50 ms jitter. Run a 20 Hz latest stream for 10 minutes with 8-bit sequences: histogram how far an arrival is behind the newest, and count duplicates. Move a record, stop it, and time until the client value equals the server's, for settle delays of 0.25, 0.5 and 1 s. | Keep 8 bits while the worst reorder distance is under 64. Settle is the smallest delay that converges every time. Provisional: 8 bits, 0.5 s. |
| M-6 | Baseline deltas for latest fields (extension) | Record trajectories at 20 Hz for 5 minutes each: walking, jumping, falling, a vehicle (a Humanoid driven by the `character_navigation` MCP tool). Replay offline: bits per update absolute, against bits for a delta against a reliable baseline refreshed every 0.5, 1 and 2 s with a switch delay of half the interval, adding the reliable rebase bytes. Offline on synthetic walks, before baseline traffic: a baseline 1, 2, 4 and 8 sends old saves 64%, 58%, 52% and 46%. | Specify the extension (version 2) if the net saving is 20% or more of the position stream. Provisional: absolute. |
| M-7 | Stamp width (D-8) | In a published place, every 5 s the server sends `GetServerTimeNow()` on `r`; each client logs its own difference for 10 minutes. Collect the maximum absolute skew per platform. | Keep 16 bits if the maximum is under 10 s; else 24 bits (version 2). Provisional: 16. |
| M-8 | Entropy coder return (optional) | Static per-field range-coder tables against EG and packed coding on recorded chat lines and skewed integer fields; client decode cost per symbol on the interpreter. | Adopt per field kind only if it saves 15% of that kind's bytes at 2 microseconds or less per symbol. Provisional: none. |

## 13. What the wire design asks of the API

1. **Enum table.** The generated `Lync.enum` table carries each Enum's item values, sorted, not only
   names (W-36). An item newer than the pinned API dump refuses to encode. Client and server may run
   different Roblox versions, so the live item list cannot size the field.
2. **Limits.** Collection ids are whole numbers below 2^51; at most 64 non-partition fields; at most
   16 namespaces per connection; at most 64 instance arguments per call.
3. **Partition fields** should be refused unless exact: `boolean`, `integer`, `string`, `oneOf`, `enum`.
4. **Defaults are exact.** A bare `angle`, `direction` or `rotation` costs up to 66, 96 and 99 bits
   (`rotation` 6 when axis-aligned). The docs should show the step form first.
5. **No throw on size.** An unreliable or latest message too large for one call is demoted and
   counted as `Oversize` in `Lync.observe`. The `unreliable` contract (lossy, unordered) still holds.
6. **Coalescing is local.** Collection writes coalesce only while consecutive in a frame (W-8). A
   write, an event and another write give two `changed` signals, not one. This keeps cause and
   effect in order.
7. **`latest` collection fields converge** but skip intermediate values (W-74).
8. **`sentAt`** has 1 ms resolution and is right within 32 s of clock skew.
9. **Flush interval.** A per-call overhead of 9 to 14 B dominates small frames. A
   `Lync.configure({ interval })` knob (default 0, every Heartbeat) is worth adding if M-2 shows
   overhead above 25% of typical traffic.
10. **One copy of Lync per place.** The three remotes are fixed names, so two bundled copies would
    collide.

## Appendix A: offline workloads

Python scratch scripts, not kept. Parameters, so M-1 can rebuild them:
- **Snapshot:** id 11 bits, an ascending sample of 2000; x, y, z 14 bits, Gaussian(5120, 900) clamped to
  0..10240; yaw 10 bits uniform; health 7 bits, 70% equal to 100; state 3 bits, 80% equal to 0.
- **Events:** target 8 bits uniform; damage 7 bits, exponential mean 12 capped at 127; crit 1 bit, 10%
  set; kind 2 bits from {0,0,0,1,2,3}.
- **Delta stream:** slot 11 bits, gaps `1 + exponential(mean 2)`; mask 3 bits from {1,2,4,3,5,7,1,1,2};
  each set bit a 10-bit field of `512 + Gaussian(0, 12)`.
- **Tiles:** 5-bit values; each element has a 12% chance of a new value uniform in 0..23.
- **Columns of 256:** sorted ids (11 bits, gaps as above); height walk (10 bits, step Gaussian(0, 3));
  health (7 bits, 80% equal to 100); random 14 bits up to 10240.
- **Trajectories:** a character at 10, 20 and 60 Hz; each update turns with probability 0.05 (sigma 0.8
  rad); speed from {0,0,8,16} studs/s changes with probability 0.03; y jitter sigma 0.1; 0.1-stud grid.
- **Geometry:** 200 000 random unit directions and rotations; plain rounding, no neighbour search;
  worst error 0.93 degrees (direction) and 0.96 (rotation) at 8 bits per component, 0.47 and 0.47 at 9.
- **Stand-in zstd:** CPython 3.14.7 `compression.zstd`, level 3, size taken as `min(raw, zstd)`.
