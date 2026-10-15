# Review of the v5 design, draft 3: can milestones 1–2 be built without guessing?

**Scope and method.**
- **Reviewed:** `.data/docs/design/v5.md` draft 3 (878 lines), with the draft-2-to-3 section of `v5-changes.md`.
  The companions were read only where milestones 1–2 depend on them (`v5-integrity.md` §2 for the tag constants).
- **Method:** I acted as the builder. For each milestone 1–2 component I wrote down the encode and decode steps
  the text gives, then implemented the fiddly ones in Luau:
  - integer codes, frames, the tag and the schema hash (`probes/review-3/p1`–`p3`);
  - HalfSipHash, validated against the reference vector (key 00..07, empty message → `a9 35 9f 5b`, matched).
- **Severity:** blocking means a builder cannot proceed. Everything below can be built by picking an answer, but
  each pick is a guess that changes bytes or behaviour, and two builders, or golden frames against the text, would
  disagree. Taste is excluded.
- **Settled, not re-argued:** per-build rotation.

**Count:** 0 blocking, 7 major, 5 minor.

**What builds cleanly from the text:**
- the bit writer and reader (LSB-first, checked in `design-3/bitorder`);
- EG-k below 2^53;
- zigzag;
- every single-row codec except the details in M6;
- `t.number`'s integer step count and clamp;
- the toc and chunk grammar;
- downstream `align` and the backwards tail;
- chunk-local instances;
- the tag input layout, and HalfSipHash with its reference constants;
- the Fisher–Yates permutation;
- request slots and epochs;
- the inbound pipeline order;
- the 17 facts with coalescing and caps;
- counters, console and `Lync.configure`.

## Draft-2 blocking findings: status

| Draft-2 finding | Status | Evidence |
|---|---|---|
| B1: dropped asks leak slots | **Fixed.** Every ask that is read is answered (§5.2, §6.1 step 5); frame-level drops are reclaimed on timeout with a 1-bit epoch. One precedence gap remains (m1). | text |
| B2: milestone 1 wire gaps and numeric edges | **Mostly fixed.** Bit order, EG layout, `align`, flattening, rule 2 and `t.number` are all closed. Still open: EG-0 of 2^53 and `t.int(−2^52, 2^52)` (M5), and a list of byte-level choices (M6). | `p1`, `p3` |
| B3: encode-once against per-player fields | **Fixed** for instances (chunk-local), the tick header (`'11'` when recipients differ) and the tail (per-chunk segments, reverse chunk order). Making the unreliable `seq` server-wide created a new problem (M1). | text |

---

## Major

### M1. A server-wide unreliable `seq` breaks the ack window and the sequence-extension rule

**The case.** §4.4 makes the downstream unreliable `seq` server-wide: "each unreliable frame of a flush gets the
next value, shared by every player sent that frame". Two other rules assume a player's frames are close together
in `seq`:
- **The ack** acknowledges "the newest downstream unreliable seq received, and the 16 before it" (§4.1).
- **Extension.** Stored 12-bit values are extended "to the value nearest the newest seq received" (§4.4). That
  works only while consecutive frames to a client are fewer than 2048 seqs apart.

**Example with 100 players.** Each player gets their own frame per flush (a targeted unreliable event in
milestone 2; per-viewer rows chunks always in milestone 4):
- **Acks.** The seq advances by about 100 between two frames to the same player, so the 16-bit `received` field
  never covers that player's previous frame. Every frame except the newest "leaves the ring unacked" and "counts
  as lost" (`v5-collections.md` notify), so notify re-sends every row every tick.
- **Extension.** At 2 frames per player per state tick the seq passes 2048 in about 10 ticks (0.5 s at 20 Hz). A
  client that receives no unreliable frame for 0.5 s extends the next seq to the wrong 4096-wide window. The
  frame's rows then compare as older and are dropped, while the server sees them acked. That is the idle-record
  freeze review-2 M2 reported, back again with a 0.5 s horizon, contradicting §4.4's "idle records never age out".

**Fix.** Give each player its own unreliable `seq` and write the 20-bit header per player around a shared body:
copy the body, write the header. That costs `FireAllClients` on the unreliable lane only. Alternatively, keep the
shared seq for broadcast frames and add a per-player seq to frames that carry per-player chunks. Either way, pin
it in milestone 2, because the header is milestone 2 wire.

### M2. The control chunk format is undefined, so `HELLO` and `WELCOME` can't be encoded

**The gap.** §4.1 defines a run chunk as `id:u(w) count−1:EG0 [instances:EG0] rows`. §4.6 says "control messages
are the runs of namespace 0, each `type:u3` then its fields". Namespace 0 has no id space. A builder has to choose
between:
1. the run chunk with `type:u3` in place of `id`, where a run is consecutive messages of one type and each row is
   the fields alone;
2. a run chunk with no id, where every row starts with `type:u3`;
3. a run chunk whose id width is 0 and every row starts with `type:u3`.

All three are plausible and give different bytes. Without a choice, golden frames for `HELLO`, `WELCOME`,
`MISMATCH`, `REKEY`, `RATE`, `REPORT` and `BEACON` can't be written. That is every control message and the whole
handshake. Also unstated: whether `HELLO`'s `version u8` is 1, and how a run of two `HELLO`s orders their name bytes
in the tail (the general rule implies reverse decode order).

**Fix.** One line: "a control chunk is `type:u3 count−1:EG0` then `count` rows of that type's fields". Also state
the protocol version's value.

### M3. A welcome and the held sends it releases arrive in an order rule 7 refuses

**The case.**
1. During a join, the server holds `fire(Lync.all, …)` for the joiner (§5.3).
2. When `HELLO` arrives, it queues `WELCOME` and releases the hold, both in the next frame, since there is at most
   one reliable frame per player per flush.
3. Runs go "in call order across namespaces" (§4.1). The held runs were fired *before* the `WELCOME` was queued, so
   they come first in the frame.
4. The client decodes data runs for a namespace it hasn't been welcomed into: rule 7, "a namespace not welcomed on
   this connection". It refuses the whole frame, `WELCOME` included.

**Decode-time state.** Even with `WELCOME` first, the first `WELCOME` carries the permutation seed and the
namespace index. The client's decoder must apply them while decoding the same frame, before it can read later
runs' ids. §6.1's "decode the whole frame before delivering any of it" describes the server and doesn't say this.

**Fix.**
- "A released hold follows the `WELCOME` that releases it."
- "Control messages take effect as they are decoded, for the rest of the frame."

### M4. Wrong-lane messages are no longer detected

**The case.** §4.6: "an id outside the receiving direction's space is malformed, so a wrong-direction or
wrong-lane message has no separate fact". Id spaces are per *direction* (up, down, collections), not per lane. A
reliable-only definition's id is valid in the up space whichever remote it arrives on. Concrete cases:
- a client sends a `buy` ask, a `chat` event or a `HELLO` inside an `UnreliableRemoteEvent` frame;
- it decodes cleanly and is delivered;
- requests then run on a lane that drops frames silently.

§3.4's "a wrong direction or lane can't be produced by an honest client" still holds, but nothing on the server
checks it. Draft 2 had `wrongLane`. The S6/S10 merge removed it on a premise that is true only for direction.

**Fix.**
- Add rule 7b: a definition id on a lane it isn't declared for, a request ask or answer, or a control message on
  the unreliable lane. One comparison on a definition the decoder already looked up.
- Or split the up and down spaces by lane.

### M5. Integer codes at 2^53: the text's formulas lose the top values

From `p1_integer_codes.luau` and `p3_float_params.luau`, run on the Luau 0.740 VM:
- **EG-0 of 2^53.** §3.3 allows `t.int()` up to |v| = 2^52, so zigzag(2^52) = 2^53 is a legal code. Implemented
  as §4.1 writes it, v = u + 2^k = 2^53 + 1 is not a double, and the round trip returns 2^53 − 1. Decode written
  as `2^(z+k) + r − 2^k` fails the same way. Evaluated exactly, as `(u mod 2^(n−1)) + 2^k` and
  `(2^(z+k) − 2^k) + r`, both work.
- **`t.int(−2^52, 2^52)`** is allowed ("−2^52 ≤ min ≤ max ≤ 2^52"). Then max − min + 1 = 2^53 + 1 evaluates to
  2^53, giving width 53, while the code `v − min = 2^53` needs 54 bits.
- **`t.int()` columns use "n = 2^53 + 1"**, which isn't a representable double. Wrapping with it as written turns
  the residual of +2^52 after −2^52 into 0, which decodes as −2^52.
- **The code definition is ambiguous.** The column code is "the unsigned integer its single-row encoding writes,
  before any EG coding (for `t.int()` and Roblox enums, the value itself)". Read literally, the code for `t.int()`
  is zigzag(v); the parenthesis says the signed value. Only the zigzag reading matches n = 2^53 + 1.
- **Roblox enums have no n.** No n is given for a Roblox enum column, so the wrap is undefined.

**Fix.**
- Cap `t.int()` at |v| ≤ 2^52 − 1 and `t.int(min, max)` at max − min ≤ 2^53 − 1. Or keep the caps and state the
  exact evaluation order of the formulas above.
- Define the column code of `t.int()` and Roblox enums as zigzag(v), with no wrap: zigzag the plain difference,
  which is exact to |d| ≤ 2^53.

### M6. Milestone 1 golden frames: byte-level choices the text leaves open

Each of these changes bytes, so milestone 1's golden frames would encode the builder's guess, not the design:
1. **`t.optional` presence bit polarity.** `t.bool` says 1 = true; presence says nothing.
2. **A column over zero rows.** For example, an optional absent in every row, or a union variant no row uses:
   is `mode:u2` written or not?
3. **Bool columns.** Do they take `mode:u2`? Is the XOR value zigzagged (0/2) or used as is (0/1) under EG-k and
   FOR? §4.3 says bool columns XOR, then gives modes for "integer columns (every other column)".
4. **Encoder ties.** "The encoder costs every mode and every k" but gives no tie-break between equal costs. The
   differential test passes because both paths share code, but the bytes aren't the text's. Fix: the lowest mode,
   then the lowest k.
5. **Repeated instances.** Is an instance referenced twice in a chunk listed once or twice? Rule 9 only says
   every entry is referenced.
6. **Axis-aligned rotations.** The 24 rotations are indexed "in the order of the golden table", which milestone
   1 creates, so the builder invents the order. Give a rule, such as lexicographic order of the rounded matrix
   entries.
7. **Smallest-three details.** The order of the three kept components ("x y z w order, skipping the dropped" is
   implied but unstated), and how the quaternion is taken from a CFrame (e.g. Shepperd's method on
   `GetComponents()`). At rounding boundaries, conversions differ by one code.
8. **Decodes not stated.** `t.color3` (q/255?) and the exact `t.direction` decode.
9. **Hash parameter types.** §4.7 types only `t.int`'s parameters (`num`). It doesn't say whether string and
   buffer max, array and map max, direction and rotation `bits`, and angle `step` are `num` or integers.
10. **Hash: collections' `from` and lane.** `from` and lane are written for every definition, but a collection
    has no `from`.
11. **Hash: list enum count.** It is a `u16`, but §3.3 allows 65,536 items.

### M7. Milestone 2 frames: behaviour the text leaves open

1. **Do untagged `HELLO` frames advance the tag count?** "The client counts its upstream reliable frames from 0"
   reads as yes. The server sees them too, but nothing says its expected count e advances. If the two ends
   differ, the first tagged frame is an honest `frameGap`. `p2` golden G4 gives `a4 15 00 67 67 9e 09` at count 0
   and `… 9d 5c` at count 1.
2. **A client's first reliable frame.** It has no previous tick. `'11'` is the only sensible header, but say so.
3. **`received` bit order.** Is bit i seq − 1 − i, or seq − 16 + i?
4. **Starting values.** The first upstream unreliable `seq` (0?), the server-wide downstream `seq`'s start, and
   each slot's initial epoch.
5. **Which frame carries the ack.** The ack goes in "the first upstream frame of a flush", but the order of the
   reliable and unreliable `FireServer` calls within a flush isn't stated.
6. **Inbound and `limit` buckets.** Their initial fill (full?) and their refill rule (continuous, or per flush)
   are unstated.

---

## Minor

### m1. A late answer after a reclaim matches two rules
After an asking-side timeout the slot is reclaimed with a flipped epoch and is free. A late answer carrying the
old epoch is both "an answer whose epoch no longer matches … discarded and counted" and "an answer for a free slot
… `slotConflict`". The second is a fact with "none" as its honest cause, so honest slow handlers would produce it.
**Fix:** check the epoch first. Also map `slotConflict`'s `case` values 1–3 to their triggers.

### m2. Splitting shared runs across 16,384 B frames
A run chunk can exceed 16,384 B (many messages), and a shared chunk can't be split differently per player.
**Fix:** cap run chunks at encode time (for example 16,000 B less the toc), so every chunk fits an empty frame.

### m3. A cited probe disagrees with the rule it supports
`probes/design-3/number_steps.out` lists `t.number(0, 1, 0.3)` with "steps 3". Under §3.3's rule, r = 3.33 is a
`numberStep` declaration error. Re-run the probe under the stated rule.

### m4. "Namespace hash" and "schema hash"
§4.5 seeds the permutation with "the namespace hash", while §4.6 and §4.7 define "the schema hash". Use one name.

### m5. `t.angle` steps stay correct only because ⌈⌉ rounds up
`2π/(2π/1000)` evaluates to 999.99999999999989 and ⌈⌉ gives 1000 (`p3`). A step whose ratio lands just *above*
an integer would gain a spurious step. Apply `t.number`'s 1e-9 integer tolerance to n.

---

## Proposed golden frames

All at seed 0, identity permutation, the §3.4 namespace `arena` as index 1, `columnMinRows` 4. Id spaces by name:
- up: `buy` 0, `chat` 1, `strike` 2 (2 bits);
- down: `announce` 0, `buy` 1 (1 bit).

Built by `probes/review-3/p2_golden.luau` and checked by hand bit for bit.

| # | Frame | Hex | Determined by the text? |
|---|---|---|---|
| G1 | EG-0 codes (stream order): 0 → `1`, 1 → `010`, 2 → `011`, 3 → `00100`, 7 → `0001000` | — | yes |
| G2 | down reliable, first frame after `WELCOME`, T = 0: `announce:fire(all, {kind="round", number=3})` | `03 00 94 06 12 00` | yes, given M7.2's `'11'` for a first frame |
| G2b | down reliable, tick +1: one run of `{round 3}`, `{winner "blue"}` | `95 06 44 30` | yes |
| G3 | down reliable, tick unchanged: answer to `buy`, slot 0, value 250 | `4a 03 03 f4 01 00` | yes, given initial epoch 0 (M7.4) |
| G4 | up reliable `chat:fire("gg")`, key 00..07, tag cover 1024 | `a4 15 00 67 67 9e 09` (count 0) or `a4 15 00 67 67 9d 5c` (count 1) | no: M7.1 |
| G5 | up unreliable ack-only: seq 0, acking seq 5 with 4 and 3 | `00 b0 00 06 00 02 67 f1` | no: M7.3, M7.4 |
| G6 | schema hash of `{ chat = event{from="client", data=t.string(200)} }`, serialization `01 05 00 61 72 65 6e 61 01 00 04 00 63 68 61 74 01 01 01 01 08 <num 200> 00×8` | hash `ab 86 8b 15 cd 9c 16 40` | no: M6.9 (`max` written as `num`) |
| G7 | `HELLO` frame | — | no: M2 |
| G8 | column block, a run of 4 `strike` | — | no: M6.2–4 |
| G9 | `t.int()` value 2^52, single row | — | no: M5 |

---

## Probe index (`.data/docs/probes/review-3/`)

| File | What it does | Result |
|---|---|---|
| `p1_integer_codes.luau` (VM) | EG-k and zigzag as §4.1 writes them, in doubles; the `t.int()` column wrap with n = 2^53 + 1 | EG-0 of 2^53 round-trips to 2^53 − 1; n evaluates to 2^53; the residual of +2^52 after −2^52 becomes 0 |
| `p2_golden.luau` (VM) | bit writer, EG, frames, HalfSipHash (validated against the reference vector), tag, schema serialization and hash | golden frames G1–G6 above |
| `p3_float_params.luau` (VM) | `t.angle` n for common steps; `t.int(−2^52, 2^52)` width | n correct via ⌈⌉; width 53 can't hold code 2^53 |

Run with `~/.cache/luau-skill/luau-0.740-linux-x86_64/luau <file>`.
