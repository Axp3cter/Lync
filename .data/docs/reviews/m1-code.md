# Review: milestone 1 code

2026-10-15. Reviews `src/`, `test/`, `bench/` and `docs/codes/` at `07b2ed3` against `v5.md` (draft 3.2),
`m1-plan.md` (including §6), the author's style rules and the luau skill's `reference/style.md`.

Probes are in `.data/docs/probes/review-m1/`. Each starts with what it shows and how to run it: `pN_*.luau` runs on
Lune from that directory, and `*.bench.luau` runs on the Luau 0.740 CLI.

The baseline is clean. `lune run test/run.luau` gives 242 passed and 0 failed. `luau-lsp analyze` on `src` is clean
under both solvers, and `sh test/types/run.sh` passes all 6 proofs. A seeded fuzzer (`p5_fuzz.luau`, seeds 1 to 5,
140,000 cases of random codecs on random and bit-flipped bytes) never made the decoder raise. Every finding below is
something the suite does not catch.

During the review, uncommitted milestone 2 work appeared in the tree from another session: `src/diag/codes.luau` was
modified, and `src/diag/console.luau`, `src/diag/facts.luau`, `src/host/` and `src/session/` were added. None of it is
reviewed here. This review changed no code.

Counts: 1 blocking, 9 major, 9 minor, 5 taste.

---

## Blocking

### B1. A few bytes decode into millions of tables: counts are free when elements cost no bits

**Where:**
- `src/codec/rows.luau:489-516`: `table.create(count)`, then one element per count.
- `src/codec/columns.luau:705-730` and `:490-492`: `table.create(elementCount)` and `Leaves.newRecord` for each
  element, before any element bit is read.
- `src/plan/planner.luau:388-400` (`elementsBitsOf`) and `:345-348`: these bound bits, never element counts.

**Case** (`p2_amplification.luau`):
- The planner accepts `t.array(t.array({}, 65535), 7996)`, which is 524,017,860 empty tables per message.
  - Decoding a **3-byte** payload at N = 64 builds 4,194,240 tables, takes 2.1–2.7 s and grows the heap by 384 MB.
  - At N = 16 it is 1,048,560 tables (125 ms, 96 MB). At N = 4, a 2-byte payload, it is 262,140 tables (34 ms).
- Nesting is not even needed. `t.array(t.bool(), 65535)` filled with `false` is a constant column, so mode 0 codes
  every residual in 0 bits.
  - Its message is 3 bytes and decodes to 65,535 booleans in 2.94 ms.
  - A 16,384 B frame holds 5,461 such messages, which is about 16 s of decode and 358 M array slots per frame.

**Why it matters:**
- `v5.md` §3.3 promises "every count and length has a declared maximum, checked against the remaining bits before
  allocation". No count is checked against remaining bits, and with column mode 0 (or a zero-width element:
  `{}`, `t.int(a, a)`, a one-item enum) no such check could bound anything.
- This is the server's inbound decode path, reachable by any client with three bytes.

**Fix:** this is structural. The design's per-message byte cap bounds bits, not decoded elements.
1. **Planner:** refuse an array or map whose element costs 0 bits at worst. It carries nothing but its count, so a
   `t.int` count serves.
2. **Decode budget:** give the decoder an element budget per frame, for example k × the frame's bytes, held on the
   `Reader` and set by the transport.
   - `Rows.read` and `Columns.read` subtract every array and map count from it before `table.create`, and refuse
     with rule 2 once it runs out.
   - `v5.md` §3.3 and §4.8 need the matching rule and constant (§4.9).

---

## Major

### M1. `t.number` decodes its top code to a value its own encoder refuses (the design's example)

**Where:** `src/wire/quant.luau:381-383` (`unnumber`), `src/codec/leaves.luau:600-606` (`numberCode`),
`src/codec/rows.luau:436-445`, `src/codec/columns.luau:563-573`.

**Case** (`p1_idempotence.luau`):
- `t.number(0, 0.3, 0.1)` is §3.3's own example, with n = 3.
- Code 3 decodes to `0 + 3 × 0.1 = 0.30000000000000004`. That is above `max = 0.3`, so re-encoding the decoded
  value raises `valueRefused: … must be a number from 0 to 0.29999999999999999, got 0.30000000000000004`.
- The same happens for `(0, 0.7, 0.1)` and `(0, 2.3, 0.1)`: 3 of 82 codes in a small scan.

**Why it matters:**
- §3.3's rule, "encode(decode(q)) = q for every code q the decoder accepts", fails, and the design's claim that
  "other quantizers are idempotent by construction" is false.
- The practical failure is the relay case the decision was written for: a server that forwards a client's
  `t.number` value at its maximum raises a caller error in game code.

**Fix:**
- Clamp on decode: `Quant.unnumber` returns `math.min(min + q * step, max)`. `Quant.number(max)` is n, so the
  round trip closes.
- Add the exhaustive idempotence test that §3.3 says exists (M9).

### M2. `t.direction` accepts 511 non-canonical codes at 8 bits

**Where:** `src/wire/quant.luau:357-371`, `src/codec/rows.luau:610-617`, `src/codec/columns.luau:830-844`.

**Case** (`p1_idempotence.luau`):
- At 8 bits, 511 of 65,536 code pairs are not fixed points of encode∘decode. At 10 bits it is 2,047 of 1,048,576.
- These are the pairs on the fold edge, where `|cx| = 1` or `|cy| = 1` with z < 0. The fold zeroes one component
  and with it the sign of the other code.
- For example, (0, 0), (0, 255), (255, 0) and (255, 255) all decode to (−0, −0, −1). Only (255, 255) re-encodes to
  itself, because `signOf(-0)` is +1.

**Why it matters:**
- §4.8 requires canonical decode: one byte sequence per value. The decoder accepts a second encoding of every
  direction on the fold edge.
- This is the class of bug that §3.3's rotation decision was written to rule out, left open in the codec next to
  it.

**Fix:** either of these.
- Refuse (rule 6) a code where the decoded z < 0 and `qx` or `qy` is an end code (0 or 2^bits − 1), unless the
  other code is the one whose re-encoding keeps it. That is the positive-sign member, since `sgn(0) = +1`.
- Or, as rotation does, check E(q) = q with one `Quant.direction` call per decode.

Fix §3.3's sentence "idempotent by construction" as well.

### M3. `t.optional` "allowed everywhere" gives second encodings and silently dropped pairs

**Where:** `src/codec/rows.luau:426-435`, `:508-515` and `:563-567`; `src/codec/columns.luau:627-653`, `:722-729`
and `:757-764`; `src/plan/dsl.luau:890-894`.

**Case** (`p5_fuzz.luau 1 20000 dump`: 8 to 21 such acceptances per 30,000 cases on every seed):
- **Nested optionals.** For `t.optional(t.optional(t.optional(t.bool())))`, the bytes `01` (outer present, inner
  absent) decode to nil, and nil re-encodes as `00`.
- **Arrays of optionals.** For `t.array(t.optional(t.buffer(…)), 5)`, count 1 with an absent element decodes to
  `{}`, which re-encodes as count 0.
- **Maps with optional values.** For `t.map(t.enum(…), t.optional(…), 2)`, two pairs with absent values decode to
  `{}`. A Luau table cannot hold a key whose value is nil, so the pairs vanish.

**Why it matters:**
- These are non-canonical encodings that rule 1–9 never refuse.
- An honest sender cannot produce them. A map pair with a nil value cannot be sent at all; the decoder accepts it
  and loses it.
- `test/support/gen.luau:369` deliberately never generates absent array elements, so the suite never reaches this.
- The column path itself concatenates rows with holes correctly. `p3_array_holes.luau` ran 202 three-row runs with
  no corruption, because `table.move` sizes the array part. The defect is in what the format accepts, not in the
  concatenation.

**Fix:** this is a design gap in §3.3, "allowed everywhere".
- Refuse at declaration (`paramRange`, or a new code) an optional directly inside an optional, and an optional map
  value.
- For arrays, either refuse `t.array(t.optional(…))` or define the count as the highest present index, with the
  decoder refusing (rule 2) a final element that is absent.

### M4. Instance lists are sized with `#list`, but nil entries are the documented input

**Where:** `src/codec/leaves.luau:250`, `:373` and `:515`; `src/codec/rows.luau:642`;
`src/codec/columns.luau:608`.

**Case** (`p4_instance_holes.luau`): a record of three `t.instance()` fields, encoded with the list {p, q, r}, is
decoded with:

| The list | `#list` | Result |
|---|---|---|
| `{p, q, r}` | 3 | accepted |
| `{p, nil, r}`, built by the constructor | 3 | accepted |
| the same list, built by assignment | 1 | rule 0, but bits and tail don't meet |
| `{p, q}` followed by a nil (a trailing unreplicated instance) | 2 | rule 0, but bits and tail don't meet |

**Why it matters:**
- `Rows.read` and `Run.decode` document "a missing instance is nil", which is the unreplicated-instance case in
  §4.2.
- `#` of a table with holes is any border, so index widths and the rule 9 count depend on how the array was built.
  An honest frame is then refused, or misread if the bits happen to meet.

**Fix:** adopt the §6.2 chunk shape now. Pass `count` explicitly (`Chunk = { list, offset, count, … }`) and use
`chunk.count` for widths, bounds and rule 9, never `#list`.

### M5. Encoding without `Run.collect` silently produces bytes the receiver refuses

**Where:** `src/codec/leaves.luau:480-501` (`instanceCode` appends on first reference), `src/codec/rows.luau:296`
(width from `#instances.list` *at that moment*), `src/codec/columns.luau:186`.

**Case** (`p11_encode_without_collect.luau`): call `Rows.encodeValue` on `{ a = p, b = q, c = r }` without collecting
first.
- It writes indices of width 0, 1 and 2 (3 bits) and raises nothing.
- The receiver, knowing all three entries, reads 2 bits each and returns rule 9; the bits and tail don't meet.

**Why it matters:**
- Correctness depends on a call-order convention mentioned only in a doc comment.
- Milestone 2's request rows (§6.2 `Rows.collect` per row) are exactly where it will be missed.

**Fix:** make the encode path read-only on the list.
- `instanceCode` returns nil (an `internal` raise) for an instance not already listed.
- The width comes from a count fixed at chunk start, not from `#instances.list` mid-encode.

### M6. The encoder rollback is partial: raises leave bits, and refusals leave instances listed

**Where:** `src/codec/rows.luau:672-689`, `src/codec/run.luau:127-145`, `src/codec/leaves.luau:655-662`.

**Case** (`p12_partial_state.luau`):
1. A `t.convert` whose `encode` raises, after an 8-bit field, leaves `w.bit = 8`. The plan (§2.1) promises "a
   refused value never leaves partial bits behind". This raise, `custom.encode` raising, and the rotation
   `internal` raise all bypass the reset.
2. In one chunk, message 1 lists instance p and is then refused (`z = 9`). Message 2 references only q. The list
   stays {p, q}, so the receiver refuses the honest message 2 with rule 9 (entry p unreferenced).

**Fix:**
- Mark the writer and `#instances.list` on entry, wrap the encode in one `pcall` on the public entry point (cold
  path only), and on any failure reset both, removing the new entries from `instances.index`.
- If that `pcall` costs too much on the hot path, document that a raise poisons the writer, and have milestone 2
  discard it.

### M7. Exp-Golomb decode runs at 84–105 ns per value interpreted, against the design's 35–58

**Where:** `src/wire/column.luau:225-236` (one cross-module `Ints.readEg` call per value), `src/wire/ints.luau:149-187`
(`Bits.read` for the k-bit remainder), `src/wire/bits.luau:91` (`windowAt` not inlined).

**Case:**
- Recorded: `bench/results/579015b.json` gives `readEg0` 84.6 ns per value interpreted and 56.7 native. §4.3 states
  "35–58 ns per value interpreted".
- `p6_eg_batch.bench.luau` compares this with a batched reader that keeps the cursor in a local and inlines the
  lookup and remainder. It produces the same residuals (asserted).

| Measure | Interpreted | Native |
|---|---|---|
| EG-0 of small values, `Ints.readEg` per value | 104.6 ns | 33.3 ns |
| EG-0 of small values, batched | **53.4 ns** | 22.4 ns |
| Gaussian σ = 50 column (k = 6), whole `Column.read` | 240 ns per value | — |
| The same column, batched residual read | 91 ns per value | — |

**Why it matters:**
- Client decode is interpreted, and this is the inner loop of every column block.
- The design's figure, which justified the column coder's CPU cost, is not met by the code that ships.

**Fix:**
- Add `Ints.readEgMany(r, k, count, out, maxCode): number` with the cursor in a local, the lookup inline while 32
  bits remain, and a fallback to the slow path.
- `readExpGolomb` and `readSparse` call it.
- Re-record the bench at HEAD (m4).

### M8. `Run.collect` encodes the whole run a second time to find instances

**Where:** `src/codec/run.luau:69-72`.

**Case** (`p8_collect_cost.luau`, Lune): an 8-row run of `{ target = t.instance("BasePart"), look = t.rotation(9),
position = t.vector3(…), health = t.int(0, 100) }` costs 210 µs to collect and 441 µs to collect and encode. Collect
is 48% of the total.

**Why it matters:**
- Every definition with `hasInstances` pays a full encode twice on the server, including the rotation encoder's
  canonical iteration (up to 4 smallest-three re-encodes per value) and every column's k search.
- The bits are thrown away.

**Fix:** have `collect` walk the codec for `instance` leaves only. This is a short recursive visitor over
`record`, `optional`, `array`, `map`, `union`, `convert` and `instance`, writing nothing. Alternatively, merge it with
M5's fix by listing instances in the same visitor at chunk start.

### M9. The idempotence property tests that §3.3 says exist do not exist

**Where:** `test/wire/quant.spec.luau` (no exhaustive encode∘decode check for number, angle, direction or colour);
`test/codec/roundtrip.spec.luau:82-92`; `test/codec/mutation.spec.luau:303-338`.

**Case:**
- §3.3 says "Property tests check each one exhaustively at small widths". No test does.
- The round trip starts from decoded values, so it only ever re-encodes codes the encoder chose.
- The mutation property checks only "never raises", not "an accepted payload re-encodes to itself".
- M1, M2 and M3 each fall to a 20-line exhaustive or fuzz check (`p1`, `p5`).

**Fix:**
- Add `p1`'s loops as specs: every code at 8 bits for direction, a declared grid for number and angle, and all 256
  colours.
- Add `p5`'s canonical check to the mutation property, limited to single rows (column mode and k are free).

---

## Minor

### m1. Rotation decode builds every `CFrame` twice

**Where:** `src/codec/rows.luau:379-384`, `src/codec/columns.luau:895-900`, `src/codec/leaves.luau:182-191`.

`canonicalRotation` decodes the code to a `CFrame` (via `rotationOf`) to re-encode it, discards it, and the caller
then calls `rotationOf` again. Each accepted rotation costs two `Quant.unrotation` calls and two `CFrame`
allocations (userdata on Roblox), on top of the design's stated cost of "one more smallest-three encode".

**Fix:** return the checked `CFrame` from the check (`canonicalRotation(...): CFrame?`). For `t.cframe`, add the
position to it.

### m2. Every field read or write costs two calls

**Where:** `src/wire/bits.luau:304-306` (`Bits.write` wraps `write`, not inlined: "too expensive, cost 56") and `:91`
(`windowAt` not inlined, cost 37).

`p7_bits_calls.bench.luau` compares the current calls with the same code in place:

| Field | Current | In place |
|---|---|---|
| u8 read, interpreted | 82.9 ns | 68.7 ns |
| u8 write, interpreted | 102.5 ns | 80.9 ns |
| u8 read, native | 49.1 ns | 34.5 ns |
| u8 write, native | 39.9 ns | 32.1 ns |

**Fix:** put `write`'s body in `Bits.write`, and inline the fast path of `windowAt` into `readChunk`.

### m3. IR types are looser than the IR, which costs casts and asserts

**Where:** `src/plan/ir.luau:44` (`cframe.rotation: Codec`) and `:79` (`Variant.record: Codec`). The workarounds
are `rotationBitsOf` (`src/codec/rows.luau:44-46`), `fieldsOf` (`src/codec/columns.luau:43-45`), the inline cast at
`src/codec/rows.luau:473`, and the type-narrowing `assert`s at `src/codec/leaves.luau:784` and `:907`, which are
defensive checks for impossible states.

**Fix:** follow the `NumberCodec` precedent with `RotationCodec`, `RecordCodec`, `MapCodec` and `CustomCodec`
aliases, and type the parameters with them. All five workarounds go.

### m4. A record field named `_value` is inferred as that field's codec

**Where:** `src/types.luau:51-54`.

**Case** (`p9_infer_value_field.luau`, luau-lsp, new solver): `Infer<typeof({ _value = t.int(0, 9), name =
t.string(8) })>` is `Codec<number>`. Assigning `{ _value = 1, name = "a" }` fails for a missing `newest`, and `5`
fails too.

**Fix:** brand codecs with a property no record can plausibly have, such as `read ["[Lync] value"]: T`.

### m5. Helpers were duplicated across the three units, and some disagree in form

- `isRecord`, `toFinite` and `toName` exist in both `dsl.luau` (`:151-185`) and `planner.luau` (`:149-169`).
- `atOf` exists in `dsl.luau:135` and `init.luau:25`; in `init.luau` it has a single call site.
- `IS_MAP_KEY_KIND` (`dsl.luau:125`) and `IS_KEY_KIND` (`planner.luau:124`) are the same table.
- The −2^52 and 2^52 − 1 constants appear 3 times.
- The f32 spacing is computed twice: `checkVectorStep` at `dsl.luau:244` and `f32SpacingAt` at `leaves.luau:194`.
- There are two idioms for finiteness: `value - value == 0` (`leaves.luau:164`) and `math.isfinite`.
- There are two idioms for integers: `value // 1 ~= value` (`leaves.luau:465`, `:838`) and
  `math.floor(value) ~= value`. `style.md` names `x // 1 ~= x` as the rejected form.

**Fix:** keep one copy of each in the lowest layer that needs it (`wire` or `diag`), using `math.isfinite` and
`math.floor`.

### m6. Kind dispatch chains are open and fail silently

**Where:** `src/codec/columns.luau:957` (`return 0`), `src/codec/rows.luau:657` (`return nil, 0`),
`src/codec/columns.luau:471`, `src/plan/planner.luau:383` and `:489` (`error(…)`), and
`src/plan/serialize.luau:38` (`CODEC_TYPE: { [string]: number }`).

A codec kind added later and missed in `readColumns` decodes as success without reading a bit.

**Fix:** close each chain with `local unhandled: never = codec`, and annotate the lookup tables as
`Complete<{ read [Kind]: … }>` (`style.md`, "Dispatch").

### m7. `Fail.show` prints decimals at 17 digits, golden examples included

**Where:** `src/diag/fail.luau:178`, and `docs/codes/numberStep.md:27`, which renders the user's `0.35` as
`got 0.34999999999999998`.

Luau's `tostring` already gives the shortest round-trip form (`0.35`, `0.1`).

**Fix:** keep `%d` for integers, and use `tostring(value)` otherwise.

### m8. Lync's source prefix has no trailing separator

**Where:** `src/diag/fail.luau:124-128` and `:292`.

**Case** (`p14_lync_prefix.luau`): with Lync at `ReplicatedStorage.Packages.Lync`, the prefix is
`ReplicatedStorage.Packages.Lync`. That also matches `…Packages.LyncNet.client` and `…Packages.Lync2.schema`, so the
caller-position walk skips the user's frame.

**Fix:** capture the separator, `"^(.-[%./\\])diag[%./\\]fail$"`.

### m9. The size and bench checks rest on models and old numbers

- `test/plan/sizes.spec.luau` checks the planner against a second hand-written model of the encoder, not against
  `Run.encode`. The bound does hold: `p10_size_bound.luau` encodes 20,000 random messages and none passes
  `dataMaxBits` or `dataMaxTail`. But a misconception shared by both models would pass. Encode with the real
  encoder in that spec.
- `bench/results/579015b.json` predates every unit's final code. The rotation benchmark that §6.1 asks for
  (`test/codec/rotation.bench.luau`) has no recorded results. Re-run both at HEAD.

---

## Taste (at most 5)

- **t1.** Several parameters and helpers exist only for one caller:
  - `Leaves.rotationCodes(value, bits, maxSteps?)` (`src/codec/leaves.luau:697-701`) carries a test seam in its
    production signature.
  - `Column.write` and `Column.choose` take an unused `_lo`.
  - `init.luau`'s `atOf` has one call site.
  - `src/plan/dsl.luau:325-333` tests `kind == "vector3"` twice in a row.
- **t2.** `Fail` drops `, got <value>` whenever `got` is nil, so a missing required field reads `data.v.x must be a
  boolean` with no `got nil`. §7.1's grammar has the clause unconditionally. Pass a sentinel for "no value" rather
  than overloading nil.
- **t3.** `Ir.Definition` mixes two conventions for an option a kind doesn't take: 0 for `timeout`, `maxRecords` and
  `priority`, and nil for `reliableRate`, `limit` and `key`. Pick nil.
- **t4.** The public types leak `any` (`CustomSpec.encode: (writer: any, …)`, `decode: (reader: any)`), although
  `Bits.Writer` and `Bits.Reader` are available to `types.luau` through `Ir`. `Target` lacks §3.5's groups, `all` and
  `except`.
- **t5.** §4.8 says "column mode and k are free choices", but the decoder (rightly, by §4.3) also accepts any
  frame-of-reference base ≤ min and any width that fits. Name base and width in §4.8 too, so the canonical rule
  matches the code.

---

## What is good, and should survive the revision

- **Bits.** The bit section and tail are clean. `Bits.read` and `readTail` keep the invariant `bit ≤ stop × 8`, so
  bits can never be read from the tail, and `meets` and `readAlign` need no bounds checks. No decode path raised in
  140,000 fuzz cases.
- **Column coder.**
  - It is exact up to n = 2^53, and the costing in `sumEgCosts` equals the written bits.
  - The k search costs at most 2.4x the k = 0 encode (recorded `searchRatio`), within the plan's 3x budget.
- **Rotation canonical rule.** It is implemented as specified and verified exhaustively at 7 and 8 bits. The 2-cycle
  packing (`packedRotation`) is a neat, exact total order.
- **`vectorStep`.** It holds even at the tightest step the rule allows: in `p13_vector_step_margin.luau`, 600,002
  codes of `t.vector3(-3000, 3000, 6000 / 24575999)` all re-quantize to themselves.
- **Planner bound.** The worst-case size bound is correct against the real encoder (`p10`). Hand-computed sizes for
  `chat`, `strike` and `fighters` match.
- **Diagnostics.** Each registry example is executed as a golden message and compared byte for byte. `expectThrow`
  asserts by code, position, subject and path, never prose. The refusal suite checks that the writer is unchanged
  for every refusal in rows and in column blocks.
- **Types.** Both solvers are clean on `src`. The typing proofs record the enum widening, the side-split errors and
  a typo schema without a crash.
