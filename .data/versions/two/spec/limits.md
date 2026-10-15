# Lync v5 spec: limits

Every number and bound in v5. The wire mechanics that use them are in [wire.md](wire.md), and what happens
at a refusal is in [failures.md](failures.md). The id scheme and the claim grammar are in
[README.md](README.md).

A **single message** is one fired event, one request, one response, or the part of a collection section
that belongs to one slot. A claim marked provisional holds its value until the named measurement settles it.

## 1. Decided limits

| ID | Claim |
|---|---|
| L-1 | A collection id must be a whole number whose magnitude is below 2^51, and a write with any other id must throw. |
| L-2 | A collection must have at most 64 fields besides its partition field, and declaring one with more must throw. |
| L-3 | A connection must carry at most 16 namespaces, and the HELLO for a seventeenth must be answered with status 4 (W-180). |
| L-4 | A call on `r` or `u` must carry at most 64 instance arguments. |
| L-5 | A single message that needs more than 64 distinct instances must be refused at the call site by throwing. |

## 2. Call sizes

| ID | Claim |
|---|---|
| L-6 | A reliable call must carry at most 16384 bytes of frame, except for a single message that travels alone (L-8) (provisional M-4). |
| L-7 | An unreliable call must carry at most `985 - 6 * I` bytes of frame in either direction, `I` being the number of its instance arguments (provisional M-2). |
| L-8 | A single message that does not fit one reliable call must travel alone in one reliable call whose frame is at most 1048576 bytes. |
| L-9 | A single message whose frame would exceed 1048576 bytes must be refused at the call site by throwing. |
| L-28 | A receiver must refuse a frame longer than 1048576 bytes. |

## 3. Identifiers and widths

| ID | Claim |
|---|---|
| L-10 | A namespace name must be at most 255 bytes, and `Lync.namespace` must throw for a longer one. |
| L-29 | A namespace must have at most 65535 definitions, and `Lync.namespace` must throw for more. |
| L-11 | A sender must have at most 4096 requests of one definition pending to one peer, and a further invoke must wait for a free id, one that is neither pending nor in the quarantine of W-79, its timeout counting from the call. |
| L-12 | A client must hold at most 64 frames per connection while the reliable lane is stalled, the partly delivered frame included, and must drop a further frame as `NotAdmitted`. |
| L-27 | A node must hold at most 1024 blocks per peer and namespace while it waits for an accept, and a further block must be dropped as `NotAdmitted`. |
| L-30 | A held frame, or held remainder of a frame, must wait at most 30 seconds, counted from when it was held. |
| L-13 | A bound of `integer(min, max)` must be a whole number from -(2^53 - 1) to 2^53 - 1 with `max - min` at most 2^53 - 1, and a declaration beyond that must throw. |
| L-31 | An `integer` value of magnitude above 2^53 - 1 must be refused at encode. |
| L-14 | A quantized codec with a range must have at most 2^53 grid points and a declaration with more must throw, while `number(step)`, which has no range, is exempt and refuses an index beyond the range of W-108 at encode. |
| L-25 | An array or map whose elements take 0 bits each must have at most 128 elements, and a decoded count above that must be refused as `Malformed`. |
| L-26 | Decoding one frame must allocate at most 1024 bytes of memory per byte of frame plus 16384 bytes, and never more than 67108864 bytes, and a frame whose decoding would pass that must be refused as `Malformed` (provisional M-4). |

## 4. Sequences, stamps and settle

| ID | Claim |
|---|---|
| L-15 | A sequence number must be 8 bits wide (provisional M-5). |
| L-16 | A time stamp must be 16 bits of milliseconds (provisional M-7). |
| L-17 | The settle delay of a latest field must be 0.5 seconds (provisional M-5). |

## 5. Time and reporting constants

| ID | Claim |
|---|---|
| L-18 | The reporting window of a key must open at the first occurrence for that key after its previous window closed, and must close 30 seconds later. |
| L-19 | At most 16 observer events must be delivered per key per window. |
| L-20 | A client must retry finding its remotes for 10 seconds. |
| L-21 | Withdrawn. It duplicated A-70. |
| L-22 | Automatic flushing must apply no byte budget (provisional M-9). |
| L-23 | The delay before a HELLO retry after status 3 must start at 0.5 seconds, double at each further status 3 and be capped at 4 seconds, with no jitter. |
| L-24 | The deadline for HELLO retries must be 30 seconds from the client's first HELLO for the namespace. |
