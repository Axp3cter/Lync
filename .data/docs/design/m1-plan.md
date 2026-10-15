# Milestone 1 build plan

> **Record.** The code this plan describes was built (to commit `f1fbfd7`) and then removed at the author's
> request. Its rulings, measurements and decisions are folded into `v5.md` draft 3.4; the evidence data is in
> `probes/build/`. Paths below name files that now exist only in git at `f1fbfd7`. Draft 3.5 supersedes this
> plan's vocabulary and some names: "honest" client, model, suite or frames → "unmodified client", `Net.DEFAULT`,
> "unmodified-client suites", "encoder output"; attack cases → modified-client cases; `overBudget` → three codes;
> `clientReport` → three codes; `configInvalid` → five; the 16-bit tag → 32 bits (`v5-changes.md`, draft 3.5).

2026-10-15. Builds `v5.md` §10 item 1 (wire and codecs) against design draft 3.1. This is a plan: the design is
the specification, and every rule is cited, not restated. Where the plan fixes something the design leaves to
implementation, such as file names, function signatures and test helpers, the plan is authoritative for milestone 1.

## 1. Repo scaffolding

Code lives at the repo root: `src/` (the `lync` package), `test/`, `bench/`, and `docs/codes/` (the code registry,
`v5.md` §7.1). Requires are relative string requires. The package root `src/init.luau` reaches its children with
`@self/…`, and every other file uses `./` and `../`. These semantics were checked on Lune 0.11.0 and the Luau 0.740
CLI; on Roblox, `./` starts at `script.Parent` and `@self/` at `script`.

**`rokit.toml`**

```toml
[tools]
lune = "lune-org/lune@0.11.0"
rojo = "rojo-rbx/rojo@7.7.1"
luau-lsp = "JohnnyMorganz/luau-lsp@1.70.1"
stylua = "JohnnyMorganz/StyLua@2.6.0"
selene = "Kampfkarren/selene@0.32.0"
```

The StyLua and selene tags were checked against the repositories on 2026-10-15 (latest releases). The Luau CLI is not managed by rokit; use
`~/.cache/luau-skill/luau-0.740-linux-x86_64/luau`.

**`default.project.json`** (the package, and the source of `sourcemap.json`)

```json
{
	"name": "lync",
	"tree": { "$path": "src" }
}
```

**`stylua.toml`**

```toml
syntax = "Luau"
column_width = 100
line_endings = "Unix"
indent_type = "Tabs"
indent_width = 4
quote_style = "AutoPreferDouble"
call_parentheses = "Always"
collapse_simple_statement = "Never"

[sort_requires]
enabled = true
```

StyLua's output is authoritative. It removes the alignment padding that the luau skill's `reference/style.md` asks
for, so that one rule is not applied; everything else in `style.md` is.

**`selene.toml`** (lints `src/` and `bench/` only, since tests use `@lune/*`)

```toml
std = "roblox"
```

On first run selene generates `roblox.yml`, which needs the network. The Lync `std` file that lints games' use of
Lync is not needed until milestone 3.

**`.gitignore` additions**

```
sourcemap.json
roblox.yml
bench/results/*.tmp
```

**Commands** (run from the repo root)

| What | Command |
|---|---|
| tests | `lune run test/run.luau [filter]` |
| type check, new solver | `luau-lsp analyze --platform=roblox --flag:LuauSolverV2=true --definitions=@roblox=$HOME/.cache/luau-skill/roblox-defs-2857efa82454.luau src` |
| type check, old solver | the same with `--flag:LuauSolverV2=false` |
| typing proofs | `sh test/types/run.sh` (§4.5) |
| benchmarks | `luau -O2 bench/<name>.bench.luau` and `luau -O2 --codegen bench/<name>.bench.luau` |
| format and lint | `stylua --check src test bench`, `selene src bench` |

**Roblox datatypes under Lune.** Lune exposes `Vector3`, `CFrame`, `Color3`, `Instance` and `Enum` only through
`@lune/roblox`. `test/run.luau` copies them into `getfenv(0)` before requiring anything from `src`, which makes them
globals for every module required afterwards (checked on Lune 0.11.0). `src` uses the Roblox globals directly.
`getfenv` appears in `test/run.luau` only, never in `src`: it deoptimises a module and the Creator Store bans it
(`[client-security-build §6.1]`). Lune's
`CFrame` stores f32 components as Roblox does. Benchmarks run on the Luau CLI, which has none of these types, so
benchmarked code must not touch them (§3, unit A).

## 2. Modules

Every file starts with `--!strict`, follows `style.md`'s sections, and ends in `return table.freeze(Name)`. Layers
follow `v5.md` §2: `diag` is below everything, then `wire` → `plan` → `codec`, and `init.luau` is the milestone 1 API.
A file may require only files in its own layer or the layers before it.

### 2.1 Conventions every unit relies on

- **Decode results.** Every decode function returns `(value, 0)` on success and `(nil, rule)` on refusal, where
  `rule` is a `v5.md` §4.8 rule number. Nothing on the decode path raises (`v5.md` §4.8, `[diagnostics §9]`).
  Running out of bits is rule 4; a count, length, index or EG value past its maximum is rule 2.
- **Encode refusals** carry a path that is built only on failure. Internal encode functions return `nil` on
  success, or a `Refusal` that each level extends with its own path segment as it unwinds. The public entry points
  (`Run.encode`, `Rows.encodeValue`) reset the writer to its state at entry and then raise through
  `Fail.caller`, so a refused value never leaves partial bits behind (milestone 2 encodes many messages into one
  writer).
- **Integers.** Every value is an integer in [0, 2^53 − 1] once it is coded (`v5.md` §4.1). Fields wider than 32
  bits are split, low 32 bits first.

### 2.2 `src/diag/` (unit B)

`codes.luau`
```luau
export type Family = "declaration" | "caller" | "fact" | "outcome" | "fault" | "build" | "internal"
export type Code = "unknownOption" | "missingOption" | ...   -- every milestone 1 code, kept equal to docs/codes/*.md
Codes.family: { read [Code]: Family }
```

The milestone 1 codes are listed in §3 (unit B). Later milestones add codes, and never rename or reuse one.

`fail.luau` (requires `./codes`)
```luau
Fail.declaration(code: Codes.Code, at: { line: number, source: string }, subject: string,
	requirement: string, got: any?, fix: string?): never
Fail.caller(code: Codes.Code, subject: string, requirement: string, got: any?, fix: string?): never
Fail.show(value: any): string
```

- Messages follow `v5.md` §7.1: `source:line: [Lync] <code>: <subject> must <requirement>[, got <show(got)>][; <fix>]`,
  one line, at most 200 bytes after the position. They are raised with `error(message, 0)` and are always strings.
- `Fail.caller` positions the message by walking `debug.info` to the first frame whose source is outside Lync and
  whose line is above 0. Lync's prefix is this file's own source with the trailing `diag/fail` (or `.diag.fail`)
  and any extension removed.
- `show` follows `[diagnostics §3.2]`.

### 2.3 `src/wire/` (unit A)

`bits.luau`
```luau
export type Writer = { buf: buffer, bit: number, tail: { string | buffer }, tailBytes: number }
export type Reader = { buf: buffer, bit: number, stop: number }   -- bit: absolute next bit; stop: tail cursor (bytes)
Bits.writer(): Writer
Bits.write(w: Writer, width: number, value: number)               -- 0 <= width <= 53, 0 <= value < 2^width
Bits.align(w: Writer)
Bits.writeTail(w: Writer, value: string | buffer)                 -- tail values in decode order
Bits.parts(w: Writer): (buffer, buffer)                           -- aligned bit section; tail segment (reverse order, v5 §4.2)
Bits.finish(w: Writer): buffer                                    -- parts concatenated
Bits.reader(buf: buffer, startByte: number?, stopByte: number?): Reader  -- defaults 0, buffer.len
Bits.read(r: Reader, width: number): number?                      -- nil: would pass stop * 8
Bits.readAlign(r: Reader): boolean                                -- false: a padding bit is 1
Bits.readTail(r: Reader, length: number, asBuffer: boolean): (string | buffer)?  -- nil: stop - length < ceil(bit / 8)
Bits.meets(r: Reader): boolean                                    -- ceil(bit / 8) == stop, padding zero (rule 4)
```

The bit order is `v5.md` §4.1. The writer doubles its buffer as it grows. `Writer` exposes `bit` and `#tail`, so an
encoder can mark its state and reset to it.

`ints.luau` (requires `./bits`)
```luau
Ints.MAX: number                                    -- 2^53 - 1
Ints.bitLength(x: number): number                   -- 0 for 0
Ints.width(n: number): number                       -- ceil(log2 n) for n >= 1; width(1) = 0
Ints.zigzag(v: number): number
Ints.unzigzag(z: number): number
Ints.egBits(value: number, k: number): number
Ints.writeEg(w: Bits.Writer, value: number, k: number)
Ints.readEg(r: Bits.Reader, k: number): (number?, number)   -- rule 4 (bits ran out) or 2 (z > 53 or > MAX)
```

EG-k is defined in `v5.md` §4.1, and a 12-bit lookup table decodes the common case.

`column.luau` (requires `./bits`, `./ints`)
```luau
Column.MIN_ROWS: number                             -- v5 §4.9; 4 until the benchmark (unit C) sets it
Column.write(w: Bits.Writer, codes: { number }, first: number, count: number, lo: number, n: number)
Column.read(r: Bits.Reader, out: { number }, first: number, count: number, lo: number, n: number): number  -- rule
Column.choose(codes: { number }, first: number, count: number, lo: number, n: number): (number, number, number)  -- mode, k, bits
```

- Codes are integers in [lo, lo + n − 1]. Residuals, modes and the reference encoder's choices are `v5.md` §4.3.
  `count = 0` writes and reads nothing.
- `Column.write` must give exactly the encoding that `Column.choose` costs.
- Bool columns are `lo = 0, n = 2`; `t.int()` columns are `lo = −2^52, n = 2^53`.

`quant.luau` (no requires; pure numbers, so it benchmarks on the Luau CLI)
```luau
Quant.numberSteps(min: number, max: number, step: number): number?        -- n, or nil (numberStep)
Quant.number(v: number, min: number, step: number, n: number): number      -- q; caller checked min <= v <= max
Quant.unnumber(q: number, min: number, step: number): number
Quant.angleSteps(step: number): number
Quant.angle(v: number, n: number): number
Quant.unangle(q: number, n: number): number
Quant.direction(x: number, y: number, z: number, bits: number): (number, number)       -- caller checked finite, non-zero
Quant.undirection(qx: number, qy: number, bits: number): (number, number, number)
Quant.rotation(r00: number, r01: number, r02: number, r10: number, r11: number, r12: number,
	r20: number, r21: number, r22: number, bits: number): (number, number, number, number, number)  -- flag, index, a, b, c
Quant.unrotation(flag: number, index: number, a: number, b: number, c: number, bits: number):
	(number?, number, number, number)                                     -- quaternion x y z w; nil: squares > 1 (rule 6)
Quant.color(c: number): number
Quant.uncolor(q: number): number
Quant.AXIS: { { number } }                          -- the 24 matrices, row-major, in v5 §3.3 order
```

All rules are in `v5.md` §3.3 "Quantizers, exactly". For the flag-1 (axis-aligned) form of `rotation`, `a`, `b`
and `c` are 0.

`halfsiphash.luau` (no requires)
```luau
HalfSipHash.hash(key: buffer, message: buffer, offset: number, length: number, c: number, d: number,
	outBytes: number, iv0: number?, iv1: number?): (number, number)
-- key: 8 bytes, read as two u32le; returns the low u32 and, when outBytes = 8, the high u32 (else 0).
-- iv0 and iv1 default to 0x6c796765 and 0x74656462 (milestone 5's rotation replaces them, v5-integrity.md §2).
```

The schema hash is `hash(zeroKey, bytes, 0, len, 2, 4, 8)` (`v5.md` §4.6). Milestone 2's tag calls
`hash(key, scratch, 0, len, 1, 3, 4)`.

### 2.4 `src/plan/` and `src/types.luau` (unit B)

`ir.luau` (types only; returns a frozen empty table)
```luau
export type Codec =
	{ kind: "bool" }
	| { kind: "int", min: number, max: number, width: number }                   -- t.int(min, max)
	| { kind: "varint" }                                                         -- t.int()
	| { kind: "number", min: number, max: number, step: number, steps: number, width: number }
	| { kind: "f32" } | { kind: "f64" }
	| { kind: "angle", steps: number, width: number }
	| { kind: "string", max: number, width: number }                             -- width: of the length
	| { kind: "buffer", max: number, width: number }
	| { kind: "vector3", axis: Codec }                                           -- axis: a "number" codec
	| { kind: "vector3f32" }
	| { kind: "direction", bits: number }
	| { kind: "rotation", bits: number }
	| { kind: "cframe", position: Codec, rotation: Codec }
	| { kind: "color3" }
	| { kind: "enum", items: { string }, index: { [string]: number }, width: number }  -- index: 0-based
	| { kind: "robloxEnum", name: string, byValue: { [number]: EnumItem } }
	| { kind: "instance", class: string? }
	| { kind: "optional", inner: Codec }
	| { kind: "array", inner: Codec, max: number, width: number }
	| { kind: "map", key: Codec, value: Codec, max: number, width: number }
	| { kind: "union", variants: { Variant }, byName: { [string]: number }, width: number }
	| { kind: "record", fields: { Field } }                                      -- fields in v5 §3.1 order
	| { kind: "custom", name: string, version: number, maxBits: number, maxBytes: number,
		encode: (Bits.Writer, any) -> (), decode: (Bits.Reader) -> (any, number) }
	| { kind: "convert", base: Codec, decode: (any) -> any, encode: (any) -> any }
export type Field = { name: string, codec: Codec, newest: boolean }
export type Variant = { name: string, record: Codec }
export type Definition = {
	name: string,
	kind: "event" | "request" | "collection",
	from: "client" | "server",
	lane: "reliable" | "unreliable",
	data: Codec?, reply: Codec?, key: Codec?,
	limit: { perSecond: number, burst: number }?,
	timeout: number, maxRecords: number, priority: number, reliableRate: number?,
	dataMaxBits: number, dataMaxTail: number, replyMaxBits: number, replyMaxTail: number,
	hasInstances: boolean,
	line: number, source: string,
}
export type Entry = { definition: Definition, role: "event" | "ask" | "answer", id: number }
export type Namespace = {
	name: string,
	definitions: { Definition },                     -- name order
	byName: { [string]: Definition },
	up: { Entry }, down: { Entry }, collections: { Definition },  -- v5 §4.6; element i has id i - 1
	upWidth: number, downWidth: number, collectionWidth: number,
	serialization: buffer, hashLow: number, hashHigh: number,   -- v5 §4.7
	line: number, source: string,
}
```

`dsl.luau` (requires `../diag/fail`)
```luau
Dsl.types: Types.T                                  -- the `t` table: every constructor of v5 §3.3
Dsl.event(options: { [string]: any }): any          -- declaration values, typed in types.luau
Dsl.request(options: { [string]: any }): any
Dsl.collection(options: { [string]: any }): any
Dsl.isCodec(value: any): boolean
```

- Constructors record `debug.info(2, "sl")` once (`v5.md` §7.1) and check their own arguments (for example
  `intBounds`, `numberStep`), raising `Fail.declaration`.
- A codec value is a table with a shared metatable whose `__index` holds `newest`. `:newest()` returns a copy
  marked `newest`.

`planner.luau` (requires `./dsl`, `./serialize`, `../wire/ints`, `../wire/quant`, `../diag/fail`)
```luau
Planner.plan(name: string, definitions: { [string]: any }, at: { line: number, source: string }): Ir.Namespace
```

- Checks options (`v5.md` §3.4), name order (§3.1), placement and width of `:newest()` (§3.3), and union `kind`
  fields.
- Computes widths, the three id spaces (§4.6), worst-case sizes against `v5.md` §4.9's message caps, and the
  serialization and hash (§4.7).
- Declaration errors raise through `Fail.declaration` at the definition's or codec's recorded line.

`serialize.luau` (requires `../wire/halfsiphash`)
```luau
Serialize.bytes(namespace: Ir.Namespace): buffer    -- v5 §4.7
Serialize.hash(bytes: buffer): (number, number)     -- low, high
```

`src/types.luau`
- Exported types and type functions: `Codec<T>`, `Infer<C>`, the definition types (`D & { from: "client" |
  "server" }`, §3.2), `Schema<Defs>`, and the view types `ServerView<S>` and `ClientView<S>`. In milestone 1 the
  views exist as types only, for the typing proofs; their runtime is milestone 2.
- No type function calls `error()` (`v5.md` §3.2). They return marker types instead.

`src/init.luau` (requires `@self/plan/dsl`, `@self/plan/planner`)
```luau
Lync.types: Types.T
Lync.event, Lync.request, Lync.collection                -- Dsl's, typed by types.luau
Lync.schema(name: string, definitions: Defs): Types.Schema<Defs>   -- runs Planner.plan; the value holds `ir: Ir.Namespace`
```

### 2.5 `src/codec/` (unit C)

`rows.luau` (requires `../wire/bits`, `../wire/ints`, `../wire/quant`, `../diag/fail`)
```luau
export type Instances = { list: { Instance }, index: { [Instance]: number } }   -- chunk-local (v5 §4.2)
export type Refusal = { requirement: string, got: any, path: { string } }
Rows.write(w: Bits.Writer, codec: Ir.Codec, value: any, instances: Instances): Refusal?   -- internal
Rows.read(r: Bits.Reader, codec: Ir.Codec, instances: { Instance? }): (any, number)
Rows.encodeValue(w: Bits.Writer, codec: Ir.Codec, value: any, instances: Instances, subject: string)
	-- public: resets w and raises Fail.caller("valueRefused", subject .. " " .. path, ...) on refusal
```

- Single-row encodings come from `v5.md` §3.3; inside a row, an array or map of `Column.MIN_ROWS` or more elements
  becomes a column block (§4.3).
- `Instances` lists each distinct instance once, in order of first reference (§4.2). Decoding checks rule 9.

`columns.luau` (requires `./rows`, `../wire/column`, …)
```luau
Columns.write(w: Bits.Writer, codec: Ir.Codec, values: { any }, first: number, count: number,
	instances: Rows.Instances): Rows.Refusal?
Columns.read(r: Bits.Reader, codec: Ir.Codec, count: number, instances: { Instance? }, out: { any }): number
```

This file implements `v5.md` §4.3's flattening. Codes per column come from §4.3's interval table.

`run.luau` (requires `./rows`, `./columns`, `../wire/column`)
```luau
Run.collect(codec: Ir.Codec, values: { any }, count: number, into: Rows.Instances)
Run.encode(w: Bits.Writer, codec: Ir.Codec, values: { any }, count: number,
	instances: Rows.Instances, subject: string)       -- count < MIN_ROWS: rows; else a column block; resets and raises on refusal
Run.decode(r: Bits.Reader, codec: Ir.Codec, count: number, instances: { Instance? }, out: { any }): number
```

`Run` writes only the payloads. The run chunk header (`id`, `count−1`, `instances`, `v5.md` §4.1) belongs to
milestone 2's transport. Unit C's test helper writes it for the golden frames.

## 3. Builder units

| Unit | Owns | Must not touch | Starts |
|---|---|---|---|
| **A: wire and hash** | `src/wire/*`, `test/wire/*`, `bench/*`, the scaffolding of §1, `test/run.luau`, `test/support/{check,prop,golden}.luau` | `src/plan`, `src/diag`, `src/codec`, `src/types.luau`, `src/init.luau`, `docs/codes` | at once; scaffolding and `halfsiphash.luau` first |
| **B: schema, planner, IR, registry, types** | `src/init.luau`, `src/types.luau`, `src/plan/*`, `src/diag/*`, `docs/codes/*`, `test/plan/*`, `test/diag/*`, `test/types/*` | `src/wire`, `src/codec`, `bench`, `test/support` | at once, in parallel with A |
| **C: interpreter and golden set** | `src/codec/*`, `test/codec/*`, `test/golden/*`, `test/support/{gen,frame}.luau`, the `Column.MIN_ROWS` value | everything else | when A's `bits`, `ints` and `column` and B's `ir` and `planner` pass their own tests |

Interfaces are fixed by §2. A unit that needs an interface changed asks the lead, and the change is made here
first. Until A lands, B may stub `HalfSipHash.hash` in its own tests only.

**Unit A: done when**
- G1, and both halves of G9, are reproduced bit for bit through `Ints` (`v5.md` §4.10).
- `HalfSipHash.hash` with c = 2, d = 4 matches all 64 vectors of the reference `vectors.h` for both 4-byte and
  8-byte outputs (key `00…07`, messages `00`, `00 01`, …).
- Property tests pass:
  - `Bits` round-trips random widths 0–53;
  - EG-k round-trips for k 0–15 and values up to `Ints.MAX`, and rejects z > 53;
  - `Column` round-trips random codes over every interval kind (n = 1, 2, 2^k, 2^k + 1, 2^53, lo = −2^52) and
    counts 0–40, and its output length equals `choose`'s bits.
- Quantizer properties pass:
  - `t.number` error ≤ step/2 on `probes/design-3/number_steps` cases, and `numberSteps` returns nil for
    `(0, 1, 0.3)`;
  - angle round trip;
  - direction and rotation error within `v5.md` §3.3's figures;
  - all 24 axis matrices round-trip exactly;
  - colour round trip.
- `bench/column.bench.luau` reports, interpreted and native, ns per value for column encode with the full k search
  and for decode, on four synthetic columns: constant, ±1 noise, Gaussian σ = 50, and 10% sparse changes. Also ns
  for EG-0 decode, and HalfSipHash on 64 B and 1024 B. Output is one JSON line per result, saved to
  `bench/results/<short sha>.json`. If the k search costs more than 3x the k = 0 encode, the result goes to the lead
  with the one-histogram fallback (`v5.md` §4.3).
- Type check is clean on both solvers; StyLua and selene are clean.

**Unit B: done when**
- G6's serialization bytes and hash are reproduced.
- The arena schema of `v5.md` §3.4 plans with:
  - up ids `buy` 0, `chat` 1, `strike` 2;
  - down ids `announce` 0, `buy` 1;
  - collections `fighters` 0, `round` 1;
  - widths 2, 1, 1;
  - worst-case sizes checked against hand-computed values for `chat`, `strike` and `fighters`.
- Every milestone 1 code has a test that triggers it, asserted by code and position through `expectThrow`. A
  declaration error points at the constructor's line. The codes:
  - declaration: `unknownOption`, `missingOption`, `notACodec`, `intBounds`, `numberStep`, `numberStepIsInt`,
    `paramRange`, `enumItems`, `mapKey`, `newestPlacement`, `newestWidth`, `unionKindField`, `duplicateName`,
    `nameLength`, `messageTooLarge`, `unreliableTooLarge`;
  - caller: `valueRefused` (raised by unit C; B registers it).
- Each code has a page `docs/codes/<code>.md` with front matter (`family`, `since: 5.0.0`, `evidence` for facts)
  and an `example` block.
- `test/diag/registry.spec.luau` fails when:
  - a code in `codes.luau` has no page, or a page has no code;
  - a code has no test that names it;
  - an `example` breaks `v5.md` §7.1's grammar.
- The typing proofs pass (`v5.md` §10 item 1):
  - the request signature checks cleanly;
  - a typo schema gives a diagnostic and no crash, on both luau-analyze and luau-lsp;
  - list enums widen to `string` and Roblox enums give `Codec<unknown>`, recorded as expected output;
  - the side-split error text is recorded as expected output, whether or not it already names the definition.
- Type check is clean on both solvers.

**Unit C: done when**
- G2, G2b, G3, G4 and G8 are reproduced byte for byte. Encode goes through `Run.encode` for the payloads, and
  `test/support/frame.luau` writes headers, toc, run headers, answer-row prefixes and the tag.
- Property round trips pass for every codec of `v5.md` §3.3, alone and nested (optional, array, map, union,
  record), in single rows and in column blocks. Run counts are 1 to 2 × `MIN_ROWS` + 1, including all-absent
  optionals and unused variants. Decoding re-encodes to the same bytes.
- Mutation tests pass: flipping each padding bit, truncating, appending a byte, out-of-order map keys, a
  duplicated or unreferenced instance and an out-of-range code each return the expected rule, never raise.
- `valueRefused` is raised with the right path for each refusal in `v5.md` §3.3, for example
  `arena.strike data.aim`. The writer is unchanged afterwards.
- **`columnMinRows`.** `bench/rows.luau` (run on Lune) prints, for `strike`, `announce`, `fighters`' fields and a
  `{ t.int(0, 100) }` record, the bits of n single rows against one column block for n = 1–8, on the four synthetic
  value patterns. The smallest n where the column block is no larger in at least three of the four patterns becomes
  `Column.MIN_ROWS`. Unit C writes it to `src/wire/column.luau` and reports the table to the lead; the lead updates `v5.md`
  §4.9 (builders never edit the design).
- Type check is clean on both solvers.

## 4. Test conventions

### 4.1 Layout

```
test/
  run.luau                    runner: injects Roblox globals, runs every *.spec.luau under test/ (or those matching
                              the filter), prints failures, exits 1 on any failure
  support/check.luau          expect, expectEqual, expectBytes, expectThrow
  support/prop.luau           property testing (4.3)
  support/golden.luau         reads test/golden/index.json and the .bin files
  support/gen.luau            random values for an Ir.Codec (unit C)
  support/frame.luau          test-only frame pieces for the golden frames (unit C)
  wire/*.spec.luau  plan/*.spec.luau  diag/*.spec.luau  codec/*.spec.luau  golden/golden.spec.luau
  types/*.luau, types/*.expected, types/run.sh
  golden/index.json, golden/G*.bin
```

A spec file returns a table of named test functions:
`return { ["EG-0 round trip"] = function() … end }`. The runner calls each in `pcall`, with no setup or teardown
framework.

### 4.2 Assertions (`support/check.luau`)

```luau
Check.expect(condition: boolean, message: string)
Check.expectEqual(actual: any, expected: any, message: string?)          -- deep equality for tables
Check.expectBytes(actual: buffer | string, expectedHex: string)          -- reports the first differing byte
Check.expectThrow(fn: () -> (), want: { code: string, at: string?, subject: string?, path: string? })
```

`expectThrow` parses the message with `^(.-):(%d+): %[Lync%] (%a+): (.*)$` and compares:
- `code`;
- `at` (`"file:line"`, matched against the end of the source);
- `subject` and `path`, which must appear as whole tokens.

It never compares prose (`v5.md` §9).

### 4.3 Property tests (`support/prop.luau`, under 80 lines)

```luau
Prop.check(name: string, generate: (size: number) -> any, test: (value: any) -> (), options: { runs: number?, seed: number? }?)
```

- **Runs.** The default is 200 runs, at sizes growing from 1 to 100. Randomness is `math.random` after
  `math.randomseed(seed)`, and the seed defaults to the time and is printed on failure.
- **Shrinking.** It regenerates with the failing seed at halved sizes, down to 1, and reports the smallest failing
  value and its seed.
- **Replay.** `LYNC_SEED=<n> lune run test/run.luau <filter>`.

It has no generator combinator library, no statistics and no coverage. The first v5 attempt's harness grew to 19k
lines (`[v5-attempt §10]`).

### 4.4 Golden files

- `test/golden/index.json` is an array of entries
  `{ "id": "G2", "file": "G2.bin", "bits": null, "milestone": 2, "what": "…", "design": "v5.md §4.10" }`.
- `bits` holds a stream-order bit string for vectors shorter than a byte boundary, such as G1. When it is set,
  `file` is null.
- `.bin` files are created once from `v5.md` §4.10's hex, for example
  `printf '03 00 94 06 12 00' | xxd -r -p > test/golden/G2.bin`, and are never regenerated by the code under test.
- A golden test encodes and compares with `expectBytes`, then decodes and compares values.
- G5 and G7 are recorded in the index as milestone 2 and skipped.
- New vectors (quantizer edges, the 24 axis rotations) are added by unit A with `milestone: 1`.

### 4.5 Typing proofs

Each `test/types/<name>.luau` has a `<name>.expected` beside it. `run.sh` runs `luau-analyze --solver=new` and
`luau-lsp analyze` (both solvers, where the proof needs it) on each file and diffs the output against the expected
file, with paths normalised. A crash (exit code 139) is a failure.

## 5. Not in milestone 1

Builders stop at the payload. The following belong to later milestones, and none may appear in `src/`:
- frames, headers, toc, run and control chunk headers, `align` between chunks, the tag, the replay window, the
  permutation, the handshake and control messages, remotes, sessions, request slots and epochs, flushing, holds,
  `limit` and the inbound pipeline (milestone 2; `test/support/frame.luau` writes the few pieces golden frames need,
  as test code);
- `Lync.server` and `Lync.client` at run time, the observer, facts, counters, console and `Lync.configure`
  (milestone 2);
- shards, codegen, `.d.ts`, the CLI, `lync.toml` and the differential test of the two paths (milestone 3);
- collection semantics: state, remove and rows chunks, slots, catch-up and scheduling (milestone 4). The planner only
  validates collection declarations and `:newest()` placement, and gives collections their ids;
- build seeds and rotation, traps, decoys and every other `v5-integrity.md` measure (milestone 5);
- extensions (milestone 7). `t.custom` and `t.convert` are codecs and are in scope.

## 6. Lead notes during the build

- `test/golden/index.json` was created by unit A (G1, G9a, G9b and the `Q-*` quantizer vectors); unit C owns it from
  here and adds its entries.
- selene's `roblox` std can't be generated in this environment (its API-dump fetch bypasses the proxy); `std = "luau"`
  is used until CI.
- `v5.md` §3.3 error figures corrected to the searched worst cases reported by unit A.
- Unit B rulings (lead):
  - Accepted: the IR angle codec carries `step` (the hash input needs it); `vector3.axis` typed `Ir.NumberCodec`.
  - Accepted: `src/types.luau` is `--!nocheck` + `--!nolint UnknownGlobal` (design §3.2 wins over the plan's
    `--!strict`); `from` is typed `{ read from: ... }` and sides are selected with `index<...>` (old-solver widening
    and a luau-analyze crash, exit 139, with a type-function selector).
  - Accepted: `duplicateName` (repeated enum item), `nameLength` (namespace 1–64 B, other names 1–65,535 B),
    `mapKey` for a wrong collection key kind, and `newestWidth` refusing string, buffer, array, map, `t.int()`, Roblox
    enum, instance and custom codecs.
  - Changed: a schema entry not made by `Lync.event`/`request`/`collection` gets its own code, `notADefinition`, not
    `paramRange` (one fact, one code).
  - Changed: worst-case sizes must bound column blocks too (arrays, maps), not only single rows.
  - Changed: each registry page's `example` is compared byte for byte with the message its documented trigger
    produces (design §9 wins; examples are the golden messages, the only prose tests compare).
  - To fold into `v5.md` §4.7 at the next design pass: defaulted options are serialized present with resolved
    values; options a kind does not take are absent; a union variant is a full codec (type byte 23); `hasInstances`
    covers `data` or `reply`.

### 6.1 Design rulings from draft 3.2 (architect)

These change milestone 1 code; the design text is `v5.md` draft 3.2.
- **`columnMinRows` is 3** (`v5.md` §4.9). G8 (4 rows) stays a column block; G2b (2 rows) stays single rows.
- **Serialization** (`v5.md` §4.7) now states unit B's four choices as written in this section; nothing changes in
  code.
- **`t.vector3f32` in a column block** is three raw columns, x, y, z (`v5.md` §4.3), as unit C built it.
- **Codes:** `notADefinition` and unit B's interpretations of `duplicateName`, `nameLength`, `mapKey` and
  `newestWidth` are now design (`v5.md` §3.3, §3.4).
- **`t.rotation` canonical codes** (`v5.md` §3.3, decision "quantizers are idempotent"):
  - `Quant.unrotation` keeps its signature. A new `Leaves.canonicalRotation(flag, index, a, b, c, bits): boolean`
    decodes the code, builds the `CFrame` (`CFrame.new(0, 0, 0, x, y, z, w)`), re-encodes it from
    `GetComponents()`, and compares. Because it builds a `CFrame`, it lives in `src/codec/leaves.luau`, not in
    `quant.luau`, which stays pure.
  - The row and column decoders return rule 6 for a non-canonical code.
  - **Superseded by the lead after unit C's measurement** (2-cycles, `v5.md` §3.3): canonical is the fixed point of
    E(q) = encode(decode(q)) or the lower member of a 2-cycle; `canonicalRotation` checks that (one E, two for a
    cycle code). The encoder iterates E from its first code, stops at a fixed point or a 2-cycle (returning the lower
    member), and raises `internal` past 4 steps. Unit B registers `internal`.
  - Tests:
    - exhaustive at 7 and 8 bits: every code is either refused or re-encodes to itself, and every encoder output is
      canonical;
    - 10^7 random rotations at 9–15 bits;
    - the worst-case error search re-run with the new encoder, its figures written into `v5.md` §3.3.
  - Benchmark: rotation decode with the check, interpreted and native.
- **`t.vector3` f32 rule** (`v5.md` §3.3):
  - The encoder accepts a component up to one f32 spacing past a bound, 2^(⌊log2 |bound|⌋ − 23), and encodes it as
    the end code.
  - The planner refuses `step ≤ 2^(⌊log2 max(|min|, |max|)⌋ − 23)` with the new declaration code `vectorStep`,
    with a registry page and a test.
  - This applies to `t.vector3` and to a `t.cframe` position.
  - Property test: for every code at the bounds and 10^4 random interior codes, decode into a `Vector3`, re-encode,
    and get the same code.

### 6.2 Interfaces fixed for milestone 2 (architect)

Milestone 2's plan adopts these. Milestone 1's code may implement them now; the golden set doesn't change.

```luau
-- Encode: the refusal path's root is a parameter, not hard-wired to `data` (v5.md §7.1 roots).
export type Root = "data" | "reply" | "record" | "patch"
Rows.encodeValue(w: Bits.Writer, codec: Ir.Codec, value: any, instances: Instances, subject: string, root: Root)
Run.encode(w: Bits.Writer, codec: Ir.Codec, values: { any }, count: number, instances: Instances,
	subject: string, root: Root)
Rows.collect(codec: Ir.Codec, value: any, into: Instances)    -- one row's instances, for chunks with row prefixes

-- Decode: a chunk's instances come from the frame's array, by offset and the count in the chunk header,
-- never from #list, since unreplicated instances arrive as nil (v5.md §4.2, §3.3).
export type Chunk = { list: { Instance? }, offset: number, count: number, firstSeen: number }
export type Miss = { row: number, what: number, value: number }   -- what: 1 enum value, 2 nil instance, 3 IsA
Rows.beginChunk(list: { Instance? }, offset: number, count: number): Chunk
Rows.read(r: Bits.Reader, codec: Ir.Codec, chunk: Chunk, row: number, misses: { Miss }): (any, number)
Rows.endChunk(chunk: Chunk): number                          -- rule 9 over the chunk's entries; nil entries count
Run.decode(r: Bits.Reader, codec: Ir.Codec, count: number, chunk: Chunk, misses: { Miss },
	out: { any }): number                                    -- no longer begins or ends the chunk
```

- **Indices.** Instance index widths use `chunk.count`. Rule 9's "repeats an earlier entry" compares non-nil
  entries only.
- **`unresolved`.** A message with an unknown Roblox enum value, a nil required instance or an `IsA` failure decodes
  with rule 0. The decoder appends `{ row, what, value }` to `misses`, the caller's array, which is cleared per chunk
  and allocates only when a row is unresolved; `value` is the enum value or the chunk-local instance index. That
  row's value is undefined.
  - The milestone 2 pipeline drops each missed row.
  - On the server, it reports the fact `unresolved` with `what` and `value`, and answers an ask `rejected`.
  - On a client, it counts `unresolvedMessages` (`v5.md` §7.3, §7.4).
- **Rows with prefixes.** Request and answer chunks call `beginChunk` once, write or read each row's prefix and
  then `Rows.read`, and call `endChunk` once. `Run.decode` callers do the same around it.

## 7. Fix list from the milestone 1 code review

From `.data/docs/reviews/m1-code.md` (cited `[review-m1 …]`), and `v5.md` draft 3.3. Each item names its unit
(A wire, B plan and diag, C codec), the exact change, and the test that proves it. The order inside a unit is the
order to work in. A6 and A1 come first, since B and C use them, and B2 comes before C11.

**Unit E is editing `src/diag/` for milestone 2** (`codes.luau`, `facts.luau`, `counters.luau`, `console.luau`). B's
changes there touch only `fail.luau`. New codes are appended to `codes.luau` and `docs/codes/` after E's changes land,
as entries only, without reordering.

### 7.1 Unit A (wire)

| # | Finding | Change | Proof |
|---|---|---|---|
| A6 | m5 | New `src/wire/limits.luau`: `Limits.INT_MIN = -2^52`, `Limits.INT_MAX = 2^52 - 1`, `Limits.f32Spacing(m: number): number` (2^(⌊log2 m⌋ − 23)), `Limits.isInteger(x): boolean` (`math.floor(x) == x` and finite), `Limits.isFinite(x): boolean` (`math.isfinite`). It is the one copy, and B and C switch to it (B4, C13). | `test/wire/limits.spec.luau`: boundaries, ±0, NaN, ±inf |
| A1 | B1 | `Bits.Reader` gains `budget: number`, the decode element allowance: `Bits.reader(buf, startByte?, stopByte?, budget?)`, defaulting to `math.huge`. New `Bits.charge(r: Reader, n: number): boolean` subtracts n and returns whether the budget is still ≥ 0. | A spec: charging past the budget returns false; the default never runs out |
| A2 | M1 | `Quant.unnumber(q, min, step, max)` returns `math.min(min + q * step, max)`. | Exhaustive idempotence (A5) over every code of the `number_steps` cases and `(0, 0.3, 0.1)`, `(0, 0.7, 0.1)`, `(0, 2.3, 0.1)` |
| A3 | M2 | New `Quant.directionIsCanonical(qx: number, qy: number, bits: number): boolean`: true when `Quant.direction(Quant.undirection(qx, qy, bits))` returns `(qx, qy)`. | Exhaustive at 8 bits: exactly 511 codes are not canonical, and every encoder output is; 10^5 random codes at 16 bits |
| A5 | M9 | Exhaustive idempotence specs in `test/wire/quant.spec.luau`: every `t.color3` code; every `t.direction` code at 8 bits (with A3); every code of a declared grid for `t.number` and `t.angle` (the `number_steps` cases, `math.rad(1)`, `2π/1000`, `2π/256`). | The specs themselves; each fails on the code before A2 or A3 |
| A4 | M7 | `Ints.readEgMany(r: Reader, k: number, count: number, out: { number }, first: number, maxCode: number): number` (rule) keeps the cursor in a local, inlines the 12-bit lookup and the remainder while 32 bits remain, and falls back to `Ints.readEg` otherwise. `Column.read`'s Exp-Golomb and sparse paths use it. | A property: equal to per-value `readEg` on random columns, k 0–15, including the fallback; `bench/column.bench.luau` shows EG-0 decode ≤ 60 ns interpreted |
| A7 | m2 | `Bits.write` holds `write`'s body; `windowAt`'s fast path is inlined into the read path. | Existing tests; `p7_bits_calls` numbers re-run and recorded |
| A8 | t1 | Remove the unused `_lo` parameter from `Column.write` and `Column.choose`, and update callers in C's files in the same change. | Type check |
| A9 | m9 | Re-run `bench/column.bench.luau` at HEAD after A4 and A7, and record `bench/results/<sha>.json`. | The file |

### 7.2 Unit B (plan and diag)

| # | Finding | Change | Proof |
|---|---|---|---|
| B1 | B1, M3 | The planner computes each definition's worst-case element count W (`v5.md` §4.8) into new IR fields `dataMaxElements` and `replyMaxElements`, and refuses: W > 65,536 (`elementsTooMany`); an array or map whose element is 0 bits at its worst (`zeroWidthElement`); an optional directly inside an optional, as an array element or as a map value (`optionalPlacement`). Registry pages for the three codes are added after E's changes. | `expectThrow` for each code at the constructor's line; `t.array(t.array({}, 65535), 7996)` gives `zeroWidthElement`; `t.array(t.bool(), 65535)` plans with W = 65,536; W is hand-checked for `chat`, `strike`, `announce` and `buy` |
| B2 | m3 | `ir.luau` adds `RotationCodec`, `RecordCodec`, `MapCodec` and `CustomCodec` aliases, as `NumberCodec` was added, and types `cframe.rotation`, `Variant.record`, map keys and custom specs with them. | Type check on both solvers; C11 removes the workarounds |
| B3 | m4 | The codec brand becomes `read ["[Lync] value"]: T` in `types.luau`. | A new typing proof: a record with a field named `_value` infers its record type; the six proofs still pass |
| B4 | m5, t1 | `dsl.luau`, `planner.luau` and `init.luau` use `Limits` (A6). `IS_KEY_KIND` and the `isRecord`, `toFinite` and `toName` helpers keep one copy, in `dsl.luau`, which the planner requires. `init.luau`'s single-use `atOf` is inlined, and the repeated `kind == "vector3"` test is removed. | Existing tests |
| B5 | m6 | Kind dispatch in `planner.luau` and `serialize.luau` ends in `local unhandled: never = codec`; `CODEC_TYPE` is `Complete<{ read [Kind]: number }>`. | Type check; a test codec kind missing from a table is a type error, demonstrated in `test/types/` |
| B6 | m7 | `Fail.show` keeps `%d` for integers and uses `tostring` for other numbers. Registry examples are regenerated, so `numberStep` shows `got 0.35`. | The registry spec compares examples byte for byte |
| B7 | m8 | Lync's source prefix keeps its separator: `"^(.-[%./\\])diag[%./\\]fail$"`. | `p14`'s cases as a spec: `…Packages.LyncNet.client` is not skipped |
| B8 | t2 | `Fail` takes `Fail.NONE` for "no value"; `nil` renders `got nil`. | A missing required field reads `… must be a boolean, got nil` |
| B9 | t3 | `Ir.Definition` holds nil for every option its kind doesn't take (`timeout`, `maxRecords` and `priority` included). Serialization is unchanged. | G6 bytes unchanged; planner specs |
| B10 | t4 | `CustomSpec.encode` and `decode` take `Bits.Writer` and `Bits.Reader`. `Target`'s groups, `all` and `except` are milestone 2 (unit F). | Type check |
| B11 | m9 | `test/plan/sizes.spec.luau` encodes 20,000 random messages per definition with `Run.encode` and checks bits and tail against `dataMaxBits` and `dataMaxTail`, and decoded element counts against W. | The spec |

### 7.3 Unit C (codec)

| # | Finding | Change | Proof |
|---|---|---|---|
| C1 | M4 | Adopt `m1-plan.md` §6.2 now: `Chunk = { list, offset, count, … }` with `Rows.beginChunk` and `Rows.endChunk`, `Run.decode` taking a `Chunk`, `misses`, the `root` parameter, and `Rows.collect`. Widths, bounds and rule 9 use `chunk.count`, never `#list`. Milestone 2's unit D no longer does this (`m2-plan.md` §3.1). | `p4`'s four lists as a spec: built by constructor and by assignment, with holes and a trailing nil, all decode alike; every golden test passes unchanged |
| C2 | M5 | Encoding is read-only on the instance list. `Instances` gains `count`, fixed when collection ends, and widths use it. An instance not already listed raises `internal`. | `p11` as a spec: encoding without `Rows.collect`/`Run.collect` raises `internal` and writes nothing |
| C3 | M8 | `Run.collect` and `Rows.collect` walk the codec for `instance` leaves only (`record`, `optional`, `array`, `map`, `union`, `convert`, `cframe` and `instance`), and write nothing. | A property: the same list as the previous collect on random values; `p8` shows collect ≤ 10% of collect plus encode |
| C4 | M6 | `Rows.encodeValue` and `Run.encode` mark the writer (bit, tail count, tail bytes) and the instance list's length on entry, and run the encode in one `pcall`. On a raise or a refusal they reset the writer, truncate the list, remove the new entries from `instances.index`, and then rethrow the raise unchanged, or raise `valueRefused`. | `p12`'s cases: a raising `t.convert` leaves `w.bit` unchanged; a refused message removes its instances, so an honest second message passes rule 9; the cost of the `pcall` on success is recorded |
| C5 | B1 | Every array, map and run count is charged with `Bits.charge` before `table.create` or `newRecord`; when the budget runs out the frame is refused with rule 10. | `p2`'s payloads with `budget = 65,536`: rule 10 in under 1 ms, with no tables beyond the budget; with the default budget they decode as before (the client case) |
| C6 | M1 | Rows and columns call `Quant.unnumber` with `max`. | A codec-level idempotence property for `t.number` and `t.vector3` at the bounds |
| C7 | M2 | Rows and columns refuse a non-canonical direction code with rule 6, using `Quant.directionIsCanonical`. | A mutation spec: `(0, 0)` at 8 bits gives rule 6; `(255, 255)` decodes |
| C8 | M9 | The mutation property also checks that a single-row payload the decoder accepts re-encodes to the same bytes (`p5`'s canonical check). It is single rows only, because column mode, k, base and width are free. | The property, with seeds 1–5 at 30,000 cases, and zero second encodings after B1 |
| C9 | m1 | `Leaves.canonicalRotation(...)` returns the checked `CFrame` or nil, so an accepted rotation is decoded once. | Rotation specs; `test/codec/rotation.bench.luau` recorded at HEAD |
| C10 | m6 | `rows.luau` and `columns.luau` close their kind dispatch with `local unhandled: never = codec`. | Type check |
| C11 | m3 | Remove `rotationBitsOf`, `fieldsOf`, the inline cast and the two narrowing `assert`s, using B2's aliases. | Type check; existing tests |
| C12 | t1 | `Leaves.rotationCodes` loses its `maxSteps` test seam; the test uses a test-local copy. | Rotation specs |
| C13 | m5 | `leaves.luau` uses `Limits` (A6): one f32-spacing function, `math.isfinite`, `math.floor`. | Existing tests |

### 7.4 Lead rulings during the fixes

- **B5 and C10 are replaced.** A `never`-closed dispatch and `Complete<{ read … }>` are type errors under the old solver,
  and Lync's own source stays clean on both solvers (principle 3; users' luau-lsp may check `Packages`). Exhaustiveness
  is proved by tests instead: one spec builds a codec of every IR kind and runs it through every kind dispatch
  (planner widths and worst cases, serialization, row and column encode and decode), failing on any kind a dispatch
  doesn't handle. B owns the planner and serialization half, C the codec half.
- **W for answers** is `1 + E(reply)`; kinds without answers have 0 (`v5.md` §4.8 to say so at the next design pass).
- **Direction encoder:** it always returns a canonical code, iterating E and taking the lower member of a 2-cycle,
  like rotation (unit A, in progress); C7's rule-6 refusal waits for it.
- **C's interpretations accepted:** `Instances.count` is the number of entries committed by encodes (an encode fixes
  it at `#list` on entry; a failure truncates back), which satisfies both C2 and C4; `Chunk.offset` is the count of
  frame-array entries before the chunk; `root` is required. The lead updated the two stale calls in B's files
  (`docs/codes/valueRefused.md`, `test/plan/sizes.spec.luau`).
- **Milestone 1 closed:** 362 tests pass, default suite about 37 s; `LYNC_FULL=1` runs the full property counts.
