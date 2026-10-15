# Lync v5 spec: wire format

What a frame holds and how it is read. W-1 to W-87 carry over the claims of
the original wire design with their numbers, adjusted for the decisions recorded in [README.md](README.md). Where an original claim held several independent sentences, the first keeps its
number and the others take new ids from W-88 up, so the order of ids in this file follows the topic, not the
number. The numbers of limits are in [limits.md](limits.md), what a refusal does is in
[failures.md](failures.md), and the id scheme and the claim grammar are in [README.md](README.md).

Four terms. To **refuse** at decode is to drop the rest of the frame (W-103) and count it (F-27, F-28). To be
**refused at encode** is to make the call throw and queue nothing (F-7, F-12). `S` is the sequence width
(L-15) and `T` is the stamp width (L-16). A block's body is defined by its kind: events by W-56, latest events
by W-60, requests and responses by W-76 and collections by W-63.

## 1. Transport and framing

| ID | Claim |
|---|---|
| W-1 | A copy of Lync must have exactly three remotes, each a direct child of that copy's own module instance and named with one character: `r`, a RemoteEvent for the reliable lane; `u`, an UnreliableRemoteEvent for the unreliable lane; and `h`, a RemoteEvent for the handshake (provisional M-2). |
| W-88 | Two copies of Lync in one DataModel must not share a remote (provisional M-2). |
| W-89 | The server must create the three remotes before it answers any HELLO. |
| W-2 | Every call on `r` and `u` must pass the frame buffer first and then its instances as variadic arguments, not as a table (provisional M-2). |
| W-3 | Stream bit `i` of a frame is bit `i mod 8` of byte `i div 8`. |
| W-90 | A field of width `w` at stream offset `p` fills stream bits `p` to `p + w - 1`, with the field's own least significant bit first. |
| W-91 | Fields are packed back to back with no padding between them, except before string and buffer bytes (W-35) (provisional M-1). |
| W-4 | A field wider than 32 bits, at most 53, is written as its low 32 bits and then the rest. |
| W-92 | A mask wider than 32 bits is written in 32-bit chunks, the low chunk first. |
| W-5 | A frame's first 3 bits hold `P`, the number of padding bits in its last byte, and the stream ends at bit `8 * length - P`. |
| W-93 | A sender must set every padding bit to zero. |
| W-94 | A receiver must refuse a frame with a nonzero padding bit. |
| W-95 | A receiver must refuse a frame whose last block runs past the end of the stream. |
| W-6 | A frame holds blocks back to back until the stream ends. |
| W-96 | A sender must never send a frame with no block. |
| W-97 | A receiver must refuse a frame whose stream holds no block, a zero-length frame included. |
| W-7 | A flush must send every block queued for a recipient and lane in one call, except where W-9, W-10, W-99 or W-100 requires a cut or A-122 leaves blocks queued. |
| W-8 | Reliable blocks must keep the order in which they were issued, across definitions and across events, requests, responses and collection sections. |
| W-98 | A collection section must be open to coalescing only while it is the last block queued for the recipient and lane, and any later block must close it. |
| W-9 | A block that would pass the reliable call cap (L-6) must start the next call, and calls must go out in order. |
| W-99 | A run (W-56) must be cut only between messages, and a collection section only between slots. |
| W-10 | A block that would pass the unreliable call cap (L-7) must start the next call, cut as in W-9 and W-99. |
| W-11 | Instance arguments must be deduplicated by identity within a call. |
| W-100 | A block that needs more instance arguments than L-4 allows must start a new call. |
| W-12 | A block header is a same-namespace bit, which is 1 when the block's namespace slot equals the previous block's; if the bit is 0, a 4-bit namespace slot; then the definition id in `bits(n - 1)` bits, `n` being the number of definitions of that namespace. |
| W-101 | The first block of a frame must be compared with namespace slot 0. |
| W-13 | Definition ids must follow the ascending byte order of definition names within a namespace. |
| W-102 | A request and a collection must each take one id. |
| W-194 | A decoded definition id of `n` or more, `n` being the number of definitions of the namespace, must be refused. |
| W-14 | One id table must serve both lanes, so that every block is valid on either lane. |
| W-15 | Blocks have no length prefix. |
| W-103 | A refusal inside a block must drop the rest of the frame. |
| W-104 | Messages decoded before a refusal must still be delivered. |

## 2. Primitive codes

| ID | Claim |
|---|---|
| W-16 | `bits(n)` is the bit length of `n`, and 0 for 0. |
| W-17 | Exp-Golomb of order `k` (EG-k) of `u >= 0` writes, with `m = (u >> k) + 1` and `L = bits(m) - 1`, `L` one bits, a zero bit, the `L` low bits of `m`, and then the `k` low bits of `u`. |
| W-105 | EG-0 of 0 takes 1 bit and EG-0 of 1 takes 3 bits. |
| W-106 | `u` must be below 2^53 when writing, and a decoded `u` of 2^53 or more must be refused. |
| W-18 | Zigzag of `v` is `2 * v` for `v >= 0` and `-2 * v - 1` for `v < 0`. |
| W-19 | A class code carries an unbounded signed integer as a 4-bit class `c`, the magnitude in `W[c]` bits with `W = {0,1,2,3,4,5,6,8,10,12,16,20,24,32,40,53}`, and then a sign bit, 1 for negative, only if the magnitude is above 0. |
| W-107 | A class-code encoder must use the smallest class whose width holds the magnitude, and a decoder must refuse any other class for a magnitude. |
| W-108 | A class code must carry the values from `-(2^53 - 1)` to `2^53 - 1`, and a value outside that range must be refused at encode. |
| W-109 | Class codes of 0, 1, 100, 1000, 50000 and 1000000000 must take 4, 6, 13, 15, 21 and 37 bits. |
| W-20 | A count or length with a declared maximum `M` below 256 must be written in `bits(M)` bits, 0 bits for `M = 0`, and any other count or length as EG-0. |
| W-110 | A count above its declared maximum must be refused. |
| W-21 | A count whose smallest possible encoding exceeds the bits left in the stream must be refused. |
| W-203 | A count of more than L-25 elements that take 0 bits each must be refused. |
| W-202 | Withdrawn. L-26 states it. |

## 3. Codecs

| ID | Claim |
|---|---|
| W-22 | `boolean` is 1 bit. |
| W-23 | `integer(min, max)` writes `value - min` in `bits(max - min)` bits, so a span of 0 takes 0 bits. |
| W-111 | A non-whole or out-of-range value of `integer(min, max)` must be refused at encode. |
| W-24 | `integer()` is a class code (W-19). |
| W-25 | Bare `number` starts with a 2-bit form: 0, a finite whole value below 2^53 in magnitude that is not -0, as a class code; 1, a value float32 holds exactly, infinities included, as 32 bits; 2, any other double as its IEEE 754 low 32 bits and then its high 32 bits; 3, NaN with no payload. |
| W-112 | The encoder of bare `number` must pick the form with the fewest bits, ties to the lower form number. |
| W-26 | `number(min, max, step)` has `points = floor((max - min) / step + 1e-9) + 1`, writes the index `round((v - min) / step)` in `bits(points - 1)` bits, and decodes to `min + index * step`. |
| W-113 | A quantized value that is NaN, infinite or more than half a step outside its range must be refused at encode, and any other value outside the range must clamp, for `number`, for each component of a vector and for each channel of `color3`, whose range is 0 to 1. |
| W-27 | `number(step)` writes a class code of `round(v / step)` and decodes to `index * step`. |
| W-28 | Bare `vector2` and `vector3` write each component as a 32-bit float. |
| W-200 | A bare `vector2` or `vector3` must write NaN and infinite components as 32-bit floats without refusing them. |
| W-114 | Quantized `vector2` and `vector3` write each component as W-26 does, x then y then z. |
| W-29 | `angle(step)` has `points = ceil(360 / step - 1e-9)`, writes `round((v mod 360) / 360 * points) mod points` in `bits(points - 1)` bits, and decodes to `index * 360 / points`. |
| W-115 | Bare `angle` writes `v mod 360` as bare `number` (W-25). |
| W-30 | `direction(step)` has `b`, the smallest integer from 4 to 16 for which `step * 2^b >= 256`, or 16 when there is none, folds the unit vector to `(u, v) = (x, y) / (abs(x) + abs(y) + abs(z))` and, if `z < 0`, to `((1 - abs(v)) * s(u), (1 - abs(u)) * s(v))` with `s(t) = 1` for `t >= 0` and -1 otherwise, writes each of `u` and `v` as `round((t + 1) / 2 * (2^b - 1))` in `b` bits, and decodes by unfolding and normalizing. |
| W-116 | A decoded `direction(step)` must differ from the encoded vector by less than `256 / 2^b` degrees. |
| W-117 | Bare `direction` writes the normalized vector as 3 floats. |
| W-118 | A zero vector must be refused for any `direction` at encode. |
| W-199 | An `angle`, a `direction` or a `rotation` with a NaN or infinite component must be refused at encode. |
| W-31 | `rotation(step)` has `b` as in W-30 and, with the unit quaternion signed so that its largest-magnitude component is positive, writes that component's index in 2 bits, ties to the lowest, and the other three in index order, each as `round((c + s) / (2 * s) * (2^b - 1))` in `b` bits with `s = 2^-0.5`, and the dropped component decodes as `sqrt(max(0, 1 - sum of squares))`. |
| W-119 | A decoded `rotation(step)` must differ from the encoded rotation by at most `281 / (2^b - 1)` degrees. |
| W-32 | Bare `rotation` starts with 1 bit, 1 when every matrix entry is exactly 0 or plus or minus 1, which is followed by a 5-bit index into the 24 such rotations ordered lexicographically by their row-major entries with -1 < 0 < 1. |
| W-120 | A bare `rotation` that is not axis-aligned must be written as W-31 writes a quaternion, with the 2-bit index of the largest component, the sign rule and the component order of W-31, and the other three components as 32-bit floats instead of `b`-bit integers. |
| W-33 | `cframe(position, rotation)` writes the position codec and then the rotation codec, and bare `cframe` is bare `vector3` and then bare `rotation`. |
| W-201 | A CFrame whose rotation vectors are not unit length and mutually perpendicular within 0.001 must be refused at encode. |
| W-34 | `color3(step)` has `points = floor(1 / step + 1e-9) + 1` and writes red, green and blue each as `round(c / step)` in `bits(points - 1)` bits. |
| W-121 | Bare `color3` writes 3 floats. |
| W-35 | `string(maxBytes)` and `buffer(maxBytes)` write the length per W-20 and then, when it is above 0, zero bits up to the next byte boundary of the stream and the raw bytes. |
| W-36 | `enum.X` writes the index of the item's `Value` in the ascending list of that Enum's item values, in `bits(count - 1)` bits. |
| W-122 | The item list and its count must come from the generated table, never from the running engine's Enum. |
| W-123 | An item whose `Value` is not in the generated table must be refused at encode. |
| W-124 | A decoded `enum.X` value for which the running engine has no item must be refused. |
| W-37 | `oneOf` writes the index of the name in the ascending byte order of the names, in `bits(n - 1)` bits. |
| W-38 | `instance` writes an EG-0 slot, 0 for nil and `i` for the `i`-th instance argument of the call. |
| W-125 | A slot above the number of the call's instance arguments, counted with a trailing nil argument included, must be refused (provisional M-2). |
| W-126 | A typed instance must be checked with `IsA` on arrival, and an instance of another class must be refused. |
| W-127 | An instance argument that the engine delivers as nil, including a trailing one, because the receiver cannot see it, must decode as nil (provisional M-2). |
| W-39 | A record is its fields in ascending name order, concatenated, with no names, tags or padding. |
| W-128 | A record with no fields takes 0 bits. |
| W-40 | `optional` writes 1 presence bit and then the value if the bit is 1. |
| W-41 | `flags` writes one bit per name in ascending name order, 1 for true. |
| W-42 | `union` writes the variant index in ascending name order in `bits(v - 1)` bits, `v` being the number of variants, and then that variant's record, with `kind` implied. |
| W-129 | A union variant index of `v` or more must be refused. |
| W-43 | `array(codec, maxCount)` writes the count per W-20 and then its elements, gridded elements as one column (W-49) and record elements per W-48. |
| W-130 | Elements of any other codec must be written one after another. |
| W-44 | `map(key, value, maxCount)` is an array of `{ key, value }` records in strictly ascending key order, numbers ordered by value, strings by bytes, and enums and `oneOf` by index. |
| W-131 | A repeated or out-of-order key must be refused. |
| W-45 | `convert(wire, ...)` writes the wire codec's encoding. |
| W-46 | A quantized value must decode as one multiply-add on its integer index and the declared parameters alone. |
| W-132 | Change detection for a quantized value must compare indices, not floats. |

## 4. Column coder

| ID | Claim |
|---|---|
| W-47 | A codec is gridded when it has at most 4 components, each a finite grid of at most 2^32 points, which are `boolean`, bounded `integer`, quantized `number`, quantized `vector2` and `vector3`, `angle(step)`, quantized `color3`, `direction(step)` (2 components), `rotation(step)` (a tag and 3 components), `oneOf`, `enum`, and `flags` of up to 32 names, and every other codec is not. |
| W-48 | Record elements must be written field by field: for each field in ascending name order, that field's value for every element, and a field that is not gridded writes its values element by element. |
| W-49 | A gridded field of 4 or more elements must start with a 2-bit mode: 0 PACKED, 1 RUNS, 2 DELTA, 3 STATE. |
| W-133 | In an UPDATE the mode must always be present. |
| W-134 | Outside an UPDATE, a column of fewer than 4 elements must have no mode and be PACKED. |
| W-135 | RUNS, DELTA and STATE must add a 4-bit `k`. |
| W-136 | STATE must be refused outside an UPDATE (W-68). |
| W-50 | PACKED writes each element's indices at their bit widths, component by component. |
| W-51 | RUNS writes pairs of the element's indices and EG-k of the run length minus 1, until `n` elements are covered. |
| W-137 | A run that passes `n` must be refused. |
| W-52 | DELTA writes the first element as PACKED and then each component as EG-k of `zigzag(index - previous element's index)`. |
| W-138 | A cyclic grid (`angle`) must take the difference modulo its points into `[-points / 2, points / 2)`. |
| W-53 | STATE writes every element as DELTA against the record's current indices, with none PACKED. |
| W-54 | A decoded index outside its codec's grid must be refused, in a column or alone. |
| W-55 | By default (`columns` true, A-117) the encoder must emit the mode and `k` with the fewest exact bits, ties going to the lower mode and then to the lower `k`. |
| W-139 | A column must never be more than 2 bits larger than PACKED. |
| W-140 | A decoder must accept every mode, including PACKED for a column that another mode would make smaller. |
| W-174 | Withdrawn. It could not fail a test; a claim is added if M-8 adopts an entropy coder. |

## 5. Events, unreliable and latest

| ID | Claim |
|---|---|
| W-56 | An event block carries a run: EG-0 of `count - 1` and then the messages back to back. |
| W-141 | Consecutive fires of one definition to one recipient, with no other block between them in that recipient's queue, must share one block. |
| W-142 | A message with no payload is 0 bits. |
| W-57 | A timestamped block holds, after the count, a `T`-bit stamp of its first message, `floor(now() * 1000) mod 2^T`, taken at the call that fired it, `now()` being the clock's. |
| W-143 | Each later message of a timestamped block must be preceded by EG-2 of its millisecond offset from the previous message, measured at their fire calls and clamped to 0 if the clock stepped back. |
| W-58 | A receiver must recover a stamp as the value congruent to it modulo `2^T` that is nearest the receiver's own `floor(now() * 1000)`. |
| W-144 | `sentAt` of a block's first message must be the recovered stamp divided by 1000, and of each later message the previous message's `sentAt` plus its offset divided by 1000. |
| W-145 | A recovered stamp must be right while the sender's and receiver's clocks agree within 32 seconds (provisional M-7). |
| W-59 | An unreliable event must travel on `u` with no sequence. |
| W-60 | A latest event is a block with no count: the header, an `S`-bit sequence, a stamp if timestamped, and one message. |
| W-146 | A recipient must get at most one block per latest definition per flush, carrying the newest message. |
| W-196 | A latest event must travel on `u` unless it is demoted (W-62). |
| W-61 | The sequence of a latest event must count the latest blocks sent for that definition and recipient from 0, modulo `2^S`, on either lane. |
| W-147 | A receiver must keep the last accepted sequence per definition and sender, and accept a block when `(s - last) mod 2^S` is from 1 to `2^(S - 1) - 1`. |
| W-148 | A receiver must always accept the first block it gets for a definition and sender. |
| W-62 | A message that cannot fit an unreliable call alone (L-7) must be sent as the same block on `r`. |
| W-149 | A demoted latest message must consume a sequence number. |
| W-150 | A demoted message must be counted as `Oversize` (F-41). |
| W-151 | A message too large for an unreliable call must not cause a throw while it fits L-8. |

## 6. Collections

| ID | Claim |
|---|---|
| W-63 | A collection block is the header, a 3-bit kind (0 ADD, 1 UPDATE, 2 REMOVE, 3 CLEAR, 4 LATEST), the partition key in its own codec if the collection has a partition field, and then the body. |
| W-152 | A kind of 5 to 7 must be refused. |
| W-153 | A collection block must hold one section. |
| W-64 | A slot is a non-negative integer per collection and partition, assigned by the server as the lowest free slot and identical for every viewer. |
| W-154 | A client must map an id to its slot from ADD. |
| W-155 | REMOVE must free the slot. |
| W-156 | An unknown slot must be refused. |
| W-65 | A SlotSet is the count as EG-0; if the count is above 1, a 4-bit `k`, else `k = 0`; then the ascending slots, the first as EG-k and each next as EG-k of `slot - previous - 1`. |
| W-66 | ADD is, in order: an `S`-bit stream sequence if the collection has latest fields; a SlotSet; the ids column (W-67); then each non-partition field per W-48 in slot order, latest fields included with their current absolute values. |
| W-67 | The ids column starts with 1 bit: if 0, each id is a class code; if 1, a 4-bit `k`, the first id as a class code and each next as EG-k of `zigzag(id - previous id)`; the ids are in slot order. |
| W-157 | A decoded id outside L-1 must be refused. |
| W-68 | UPDATE is, in order: a SlotSet; a mask with one bit per non-partition field in ascending name order; if the mask touches a latest field, an `S`-bit stream sequence; then for each set field a coverage bit (1: every slot of the SlotSet changed it; 0: one presence bit per slot of the SlotSet follows) and the values of the covered slots per W-48. |
| W-158 | A field must be listed in an UPDATE only if its indices changed, and a write that changes no field's indices must send nothing. |
| W-159 | A decoder must accept STATE for a gridded non-latest field in an UPDATE. |
| W-160 | A write that replaces an existing id must be an UPDATE of the differing fields. |
| W-69 | REMOVE is a SlotSet. |
| W-161 | CLEAR has no body and removes every slot of the keyed partition. |
| W-70 | The partition field must be omitted from the records of a section. |
| W-162 | Changing a record's partition field must be REMOVE in the old partition and ADD in the new. |
| W-71 | For one state transition of a partition, a section's bits must be identical for every recipient. |
| W-163 | A catch-up ADD for a viewer who gains sight of a partition must be the only recipient-specific section. |
| W-72 | LATEST, on `u`, is, in order: an `S`-bit stream sequence; a SlotSet; a mask over the latest fields; then for each set field coverage and values as in W-68, with no STATE. |
| W-195 | A write that changes a latest field must send that field in LATEST on `u`, and must not list it in an UPDATE except as a settle (W-74). |
| W-164 | The blocks of one send must share one sequence. |
| W-165 | A receiver must accept a collection sequence `s` when `(s - last) mod 2^S` is from 0 to `2^(S - 1) - 1`, per collection and partition, with `last` initialised by ADD or settle. |
| W-73 | A latest field must never be STATE-coded in any kind, and the decoder must refuse it. |
| W-74 | A latest field sent unreliably and unchanged for the settle delay (L-17) must be sent once more as a reliable UPDATE carrying the stream's current sequence. |
| W-166 | A receiver must set its last sequence to the sequence carried by a settle. |
| W-75 | A collection with no latest field must have no sequences and never use LATEST. |
| W-197 | A decoder must refuse a LATEST block for a collection that has no latest field. |
| W-167 | While a collection section is open (W-98), writes to it must merge into the net transition from the state the receiver held when the section opened to the state after the last write. |
| W-168 | An insert and then an update of the same id in an open section must arrive as one ADD with the later values. |
| W-169 | An insert and then a removal of the same id in an open section must arrive as nothing. |
| W-170 | An update and then a removal of the same id in an open section must arrive as one REMOVE. |
| W-171 | A removal and then an insert of the same id in an open section must arrive as an UPDATE of the differing fields, or as nothing if no field differs. |
| W-172 | Two updates of the same id in an open section must arrive as one UPDATE holding each changed field's later value. |
| W-173 | A latest value must be sent as its absolute value, with no delta against an earlier send (provisional M-6). |

## 7. Requests and responses

| ID | Claim |
|---|---|
| W-76 | A request definition's block must add a 1-bit direction after the header, 0 for a request and 1 for a response, and then a run (W-56). |
| W-175 | A receiver must accept either direction bit from either side. |
| W-77 | A request item is an id and then its payload. |
| W-176 | The first request id of a run must be 12 bits, and each later id must be EG-0 of `(id - previous - 1) mod 4096`. |
| W-78 | A response item is a 12-bit id, a 1-bit outcome (1: the reply follows, 0: unanswered), and the reply if the outcome is 1. |
| W-79 | Request ids must count per sender and definition, modulo 4096, and an allocation must skip every id that is pending or that timed out within the last 2048 allocations. |
| W-207 | A receiver must drop a request whose id is already pending from the same sender, that request alone, as `Malformed`. |
| W-177 | `Timeout`, `Left` and `Shutdown` must never cross the wire. |
| W-178 | A response with no pending id must be dropped. |
| W-80 | Requests and responses must be reliable only and keep issue order (W-8). |

## 8. Handshake and schema

| ID | Claim |
|---|---|
| W-81 | `h` must carry only byte-aligned, little-endian messages. |
| W-179 | HELLO, from client to server, is: u8 protocol version, u8 name length, the namespace name, u32 namespace hash. |
| W-82 | VERDICT is: u8 status, u8 slot, u8 server version, u32 server hash. |
| W-180 | VERDICT's status must be 0 accept, 1 hash mismatch, 2 version mismatch, 3 namespace unknown or 4 no free slot. |
| W-191 | A server must answer a HELLO with status 3 when no view of that namespace has been taken in its instance. |
| W-192 | A client that receives status 3 must send its HELLO again after the backoff delay (L-23), until the deadline (L-24) has passed since its first HELLO for that namespace, and any other status must end the retries. |
| W-181 | For status 1, VERDICT must continue with a u16 count and that many pairs of u32 name hash and u32 definition hash. |
| W-198 | HELLO byte 0, the protocol version, and VERDICT bytes 0 to 2, the status, the slot and the server version, must have the same layout and meaning in every protocol version, so that status 2 can always be delivered. |
| W-83 | DETAIL, from client to server after status 1, is: u8 version, u8 name length, the name, u16 count and the client's pairs. |
| W-182 | The server must name the differing definitions once per distinct client hash. |
| W-84 | An accepted namespace must get the next free slot of that connection, 0 to 15 (L-3). |
| W-193 | A repeated HELLO for an admitted namespace must be answered with the same slot and must take no new slot. |
| W-208 | A repeated HELLO for an admitted namespace that carries a different hash must be answered with status 1 and must leave the admitted namespace unchanged. |
| W-183 | No schema bytes must cross the wire on accept. |
| W-85 | A hash must be FNV-1a, 32 bits, and a name hash is taken over the definition's name. |
| W-184 | A definition's hash must change when its name, kind, delivery flags or any parameter that changes the bits of its codec tree changes, and must not depend on the order in which a key set was written. |
| W-185 | A definition's hash must not change when only a validator, limit, timeout, rate or transform function changes. |
| W-186 | The namespace hash must be computed over the definitions' `name:hash` entries sorted by name. |
| W-86 | The protocol version is 1. |
| W-187 | A version mismatch must be answered with status 2. |
| W-87 | A sender must send no block of a namespace before the accept of that namespace. |
| W-188 | A client must stall the reliable lane at the first block whose namespace slot it has not admitted: the blocks before it must be delivered, and that frame from the block's bit offset, together with every frame behind it, must be held, up to L-12 held frames per connection. |
| W-205 | The stalled reliable lane must resume at the accept of the slot that stalled it, decoding the held remainder from its bit offset and then the later held frames in arrival order, and must stall again at the next block whose slot is unadmitted. |
| W-206 | A client must drop at once, as `NotAdmitted` and without holding it, the rest of an unreliable frame from its first block whose namespace slot is unadmitted. |
| W-204 | A held frame, or held remainder of a frame, that still names an unadmitted slot when L-30 has passed since it was held must be decoded block by block in order, its admitted blocks delivered, and the rest of it from the first block whose slot is unadmitted dropped as one `NotAdmitted` drop, since later blocks cannot be located. |
| W-189 | A server must drop the rest of a frame at the first block whose namespace slot is not admitted for the client that sent it. |
| W-190 | Firing `chat("hi")` to a client, in a namespace of four definitions `chat` (`string(200)`), `fighters`, `sell` and `strike` with ids 0 to 3 at namespace slot 0, must send the 4-byte frame `08 01 68 69`. |
