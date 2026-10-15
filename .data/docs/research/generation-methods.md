# Generation methods: what the build can emit so a game's protocol costs a modified client more

Researcher findings, 2026-10-15. **Decision it feeds:** which generation methods the architect puts into the v5
design. Each method states what `lync build`, the Studio plugin or CI emits differently, at which grain, what it
changes and keeps fixed on the wire, which modified-client capability it prices, and its measured cost.

**Scope of this run.** Methods M1–M12 of an earlier draft (written after a model fallback, so none of its text
was accepted as is) are re-checked against its probes, re-run, and against new probes. The "going further" items
are listed in the checklist as **next unit** for a later agent.

**Labels.** **verified**: I ran it or read the source. **documented**: official docs or the design say so.
**reported**: a third party says so. **unverified**: inference, or nothing found.

**Tools.** Luau 0.742 built from `.data/projects/luau` (`luau`, `luau-compile`), CLI on an Intel Xeon 2.1 GHz,
4 cores, shared machine. Interpreted figures stand for clients (no native code on Roblox clients,
`[generation-security §4.1]`); native figures for servers. CLI timings show scale only; phones are slower by an
unmeasured factor.

**Probes** (`.data/docs/probes/generation-methods/`). Earlier ones, re-run with Luau 0.742: `shapes.luau` →
`shapes.out` (re-run gave different numbers from the draft's within noise; the file now holds the re-run),
`enum_rotation.luau` → `enum_rotation.out` (identical on re-run), `gen_defs.py` → `bytecode.out` (identical),
all by `run.sh BUILD_DIR WORK_DIR`. New in this run:
- `opcodes_gen.py` + `opcodes.sh` → `opcodes.out`: opcode streams of seed-differing record codecs and tag functions;
- `offsets.luau` → `offsets.out`: per-field cost of code offsets, encode and decode separately, 8 fields;
- `column_offset.luau` → `column_offset.out`: column bits of offset codes under two first-row baselines, and exact
  offset arithmetic up to n = 2^53;
- `dispatch.luau` → `dispatch.out`: the cost of reaching a per-session variant's encoder;
- `gen_defs2.py` + `bytecode2.sh` → `bytecode2.out`: bytecode per generated encoder and decoder, plain and offset;
- `free_choice.luau` → `free_choice.out`: column bits when a build fixes the column mode.

**Capability classes** (`client-security.md` §1.2, grouped as in `security-tooling.md` §9), cited below as:
**code** (decompile, `getscriptbytecode`, `getconstants`: reading the client's own code); **mem** (`getgc`,
`filtergc`, `debug.getupvalues`/`setupvalue`: reading and writing Lync's live state); **api** (`require` and
calling Lync's own API); **hook** (`hookfunction`, `hookmetamethod`); **signal** (`getconnections`,
`firesignal`); **packet** (`raknet` send and receive hooks below Luau); **identity** (`setthreadidentity`);
**naming** (`loadstring` chunk names, `setstackhidden`, `newcclosure`); **clock** (`setfpscap`, clock control);
**state** (reading replicated state); **share** (`request`, `WebSocket`, files: carrying artefacts between
machines and accounts). Routes A0–A8 are `client-security.md` §1.4's.

## Checklist

- [x] 0. Findings that cut across methods
- [x] M1. Per-build field order (in the design), with a private rotation seed
- [x] M2. Per-build tag constants (in the design)
- [x] M3. Per-build code offsets
- [x] M4. Id permutation mixed with a per-build value
- [x] M5. Per-build column-mode choice
- [x] M6. Per-session variant from a build-time pool
- [x] M7. Per-player variant delivered through `PlayerGui`
- [x] M8. Session key and permutation seed derived, not sent in clear
- [x] M9. Codecs at call sites (composition only)
- [x] M10. Build-time values in the server shard
- [x] M11. Per-server values through `ConfigService`
- [x] M12. Join rule for per-player variants
- [x] Summary table and Implications
- [x] M13. Per-player tag binding: one output mask per variant, fact `tagVariant` (was: next unit)
- [x] M15. Per-build generated traps, decoys and canaries (was: next unit)
- [x] M14. The runtime (no-build) path with per-server and per-session parameters through tables, measured (was:
  next unit)
- [x] M16. Composition with `research/codecs-in-scripts.md` (was: next unit; M9 gives only what the first run checked)

---

## 0. Findings that cut across methods

**0.1 The build seed is public, and so is the derivation** (verified by reading the design). `HELLO` carries the
build seed as a u32 (`v5.md` §4.6), every shard header and `manifest.json` carry it (`v5-integrity.md` §2), and
field order and tag constants are pure functions of it: Fisher–Yates under xorshift32 seeded by seed XOR the
record path's hash, and the first two xorshift32 outputs of the seed. The planner is open source and pure Luau. So a
tool that runs Lync's own planner on the shared schema module and the seed from a captured `HELLO` reproduces every
per-build value with no per-build work. The design's claim "rebuilt per release, or written to re-derive layout and
constants from each shard" (`v5-integrity.md` §2) holds only for tools that hard-code a layout. M1 below gives the
change that makes re-derivation need the shard's code each build; M2–M4 and M8 inherit it.

**0.2 Downstream encodings must stay per build** (derived from `v5.md` §4.2). Downstream chunks are encoded once
per flush and copied to every recipient, and identical frames go through `FireAllClients`. A layout that varies per
session or per player downstream breaks both: the server would encode each shared chunk once per distinct layout
among its recipients, and lose `FireAllClients` whenever more than one layout is present. Every per-session or
per-player method below therefore varies **upstream** layouts (client encoders, server decoders) and the tag only.

**0.3 Layout methods price encoders outside Lync, and only as recurring work** (derived). A client using Lync's
own API (route A4, class **api**) gets every variation applied for it. A layout method prices only a tool that
builds or reads frames itself: a static forger (A2), an extractor that encodes outside `fire` (A3: it skips the
caller probe and the client-side `limit`), and byte scripts shared between accounts (**share**). Any such tool can
re-derive a layout by (a) running the planner on public inputs, which M1's private seed removes; (b) reading the
shard's code (**code**); or (c) finding the shard's internal encoder (**mem**) and encoding known values through
it. (b) and (c) can be automated once, so each method's real price is the work to keep that automation working when
the generator changes shape, plus whatever it must redo per grain (per build, per server, per session, per player).

**0.4 What every method keeps fixed.** At build seed 0 and identity permutation every method below reduces to
today's wire, so the golden set (`v5.md` §4.10: G1–G11, PERM) is unchanged; methods that alter a vector's shape at
nonzero values say so. The schema hash is computed at seed 0 over the schema alone (`v5.md` §4.7), so no method
changes it. Generated types depend on codecs, never on layout, so `.d.ts` and Luau types are unchanged by all of
them. The runtime (no-build) path runs at seed 0 and gets none of them unless a method says otherwise.

**0.5 Grains** (mechanisms from `security-tooling.md` §1, §4 and `generation-security.md` §2).

| Grain | Vehicle | What can vary | Limit |
|---|---|---|---|
| per build | `lync build` draws values; CI publishes and calls `restartServers` | shard code: order, constants, pools | one republish; old servers keep the old build until restarted |
| per server | values drawn at server start, or `ConfigService` (server-only, yields, 15 s–1 min to propagate) | values sent in `WELCOME`; server-only policy | no code: clients have no compiler (`LoadStringEnabled` is server-only) |
| per session | values in the first `WELCOME` | key, permutation seed, an index into a build-time pool | the client must already hold every shape it may be asked to use |
| per player | a variant `ModuleScript` cloned into `PlayerGui` (`PlayerReplicated`) | which pre-built variant one client holds | one instance per player; arrival order against the first send is undocumented |

---

## M1. Per-build field order, with a private rotation seed

**Status.** In the design (`v5-integrity.md` §2). Re-checked; one change proposed (the private seed).

**What the build emits.** Grain: per build. Each record's fields are written in a Fisher–Yates order of the name
order. Generated encoder for `{ ammo = t.int(0, 255), health = t.int(0, 100), team = t.enum({ "red", "blue" }) }`
(`shapes.luau`):

```luau
-- seed 0: name order                          -- seed 7: rotated order
writebits(b, bit,      8, r.ammo)              writebits(b, bit,     1, TEAM[r.team])
writebits(b, bit + 8,  7, r.health)            writebits(b, bit + 1, 8, r.ammo)
writebits(b, bit + 15, 1, TEAM[r.team])        writebits(b, bit + 9, 7, r.health)
```

**Proposed change: the seed that rotates is not the seed that is published** (from §0.1). Each build run draws two
independent values:
- `buildId`, u32, public: it takes the seed's place in `HELLO`, the shard headers and the manifest, and is what the
  server compares (`schemaMismatch`, `seedDiffers`);
- `rotationSeed`, 64 bits, written only to `manifest.json` (which never ships). Each record's xorshift32 seed is the
  low 32 bits of HalfSipHash-2-4 keyed by `rotationSeed` over the record's path, replaced by `0x9E3779B9` if 0.

With a 32-bit secret, one record order read from the shard would let a tool search all 2^32 seeds offline and then
derive every other record and constant; 64 bits removes that search. `buildId` 0 and `rotationSeed` 0 mean
identity, so G7 (`HELLO` at seed 0) is unchanged.

The design draws the seed from "the host's random generator seeded from the clock" because the seed is public
(`v5-integrity.md` §2). A private seed must come from OS entropy (the Rust host's `getrandom`, `security-tooling.md`
§6): a clock-seeded draw is searchable from the build's approximate time.

**Changes / fixed.** Changes the order of field writes in single rows and the order of a record's columns in
column blocks (`v5.md` §4.3 flattens in field order), on both lanes. Fixed: the set of fields and codecs, ids,
union variant order, list-enum order, the schema hash, every golden vector, types, downstream encode-once (one
order per build). A record of one field, a bare codec (`chat = t.string(200)`) or a union's variant index gains
nothing from M1; of the §3.4 example's client-sent definitions only `strike` (2 fields) has an order to rotate.

**What it prices.** A2 static forgers and byte scripts carried between builds (**share**), and A3 extractors that
encode outside `fire`: each must re-derive the order per build. With today's public seed that is automatic once a
tool runs the planner on (schema, seed); with `rotationSeed` it needs the shard's code each build (**code**) or a
calibration through the shard's internal encoder (**mem**, §0.3). It does not price **api**, **hook**, **state**,
or any tool that calibrates against the loaded shard.

**Cost.**
- CPU: zero. The 8-field codec pair has 116 instructions at both seeds with an identical opcode sequence, and
  1012 B of bytecode at both (`opcodes.out`). Timings differ within noise: 282.4 against 296.7 ns per encode+decode
  interpreted, 242.7 against 238.9 native (`shapes.out`, re-run).
- Bytes: zero on the wire (v5's tail makes string bytes position-independent).
- Build: one Fisher–Yates per record, plus one HalfSipHash per record path with `rotationSeed`.
- Developer: with `rotationSeed`, a captured `HELLO` no longer suffices for offline decoding; `lync replay` and the
  inspector must take the layout from the build's manifest. Every build already writes one; CI must keep it per
  release.

**Composition.** M2, M3 and M4 derive their per-build values from the same `rotationSeed`; M6 and M7 are pools of
builds that differ in it. Reopens nothing. Bears on R5 (no seed on the runtime path): a runtime-path seed would
have to reach clients in `WELCOME`, so it would be public by construction and price only hard-coded tools.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `build.seed` | `"release"`, or a fixed value as 16 hex digits | — | `"0000000000000000"` (identity) to `"ffffffffffffffff"` | `"release"` | none at run time; `"release"` draws `rotationSeed` and `buildId` per build run from OS entropy |

**Changed from the draft.** Its timing pair (285/280 ns) was re-run (282/297, noise either way); an opcode-level
check was added; the public-seed finding and the private seed are new; the draft did not note that one-field
records and unions gain nothing.

---

## M2. Per-build tag constants

**Status.** In the design (`v5-integrity.md` §2). Re-checked; kept, with what it prices narrowed.

**What the build emits.** Grain: per build. The client and server shards' HalfSipHash-1-3 initialisation uses two
constants drawn from the build's rotation seed (M1) in place of the reference ones (`opcodes_gen.py`):

```luau
-- seed 0 (reference)                                   -- nonzero seed
local v0, v1 = k0, k1                                   local v0, v1 = k0, k1
local v2, v3 = bxor(k0, 0x6c796765), bxor(k1, 0x74656462)   local v2, v3 = bxor(k0, 0x9f3a21c4), bxor(k1, 0x0b77e1d3)
```

Both land in the tag function's constant table and are used through `FASTCALL2K` (`opcodes.out`:
`FASTCALL2K 32 R2 K0 L0 [2671387076]`), exactly as `generation-security.md` §3.2 found for large literals.

**Changes / fixed.** Changes the 32-bit tag of every upstream frame at a nonzero seed. Fixed: the tag width, its
input (count, lane, length, instance count, the first `tag.cover` bytes), the key, the count rules, the 4-count
lookahead and the replay window. G4, G5 and G8 are seed-0 vectors and are unchanged; the runtime path uses the
reference constants.

**Further constants (U2), re-checked.** Replacing v0's and v1's zero initialisation too gives four constants, but
v0 = k0 ⊕ c0 is the reference structure under the key k0 ⊕ c0 with v2's constant c0 ⊕ c2 (derived from the
initialisation equations), so four constants are two constants plus a whitening of a key that is already random
per session: one more constant to read in the same pass, nothing more. Rotation amounts are the other U2 lever; the
PRF's analysis depends on them, and no analysis of altered amounts was found (unverified), so they stay fixed. Any
two nonzero constants keep v0 ≠ v2 and v1 ≠ v3; xorshift32 never outputs 0 from a nonzero state, so drawn
constants are nonzero. Whether arbitrary constants preserve HalfSipHash's security margin is unverified; the
reference constants are asymmetry breakers with no stated structure.

**What it prices.** A tag reimplementation written against an earlier build, in a tool that does not call Lync's
own tag function: it must read two constants per build (**code**: `getconstants` on the tag function returns them
directly once the function is found). With the public seed of today they are computable from `HELLO` (§0.1).
It does not price an extractor (**mem**): one that holds the key can call the shard's own tag function. It does not
price **api** (`fire` tags for the caller), **hook** or **packet** edits outside `tag.cover` (none at the default
cover of 16,384 B).

**Cost.** Zero. A full HalfSipHash-1-3 with each constant set compiles to 445 instructions with an identical
opcode sequence and 2037 B of bytecode (`opcodes.out`). Zero bytes. Build: two xorshift32 draws.

**Composition.** One more value from M1's rotation seed. M7 makes the constants per player (next unit: binding a
frame to the variant it verifies under). Reopens U2 in part: four constants add nothing over two; rotation amounts
stay out on PRF quality.

No option: the constants follow `build.seed`.

**Changed from the draft.** The opcode identity is now verified on a full tag function rather than cited; the draft
did not say that an extractor calls Lync's own tag function, so M2 prices reimplementations only; U2's four-constant
form is shown equivalent to two.

---

## M3. Per-build code offsets

**Status.** New. Re-checked: the cost holds, the column result was misread by the draft, and its R12 link is wrong.

**What the build emits.** Grain: per build (per session or per player only upstream, §0.2). Every bounded code
q in [0, n − 1] travels as w = (q + c) mod n, with c drawn per codec site from the rotation seed and folded into
the generated code as a constant. Applies to `t.int(min, max)` (q = v − min), `t.number`, `t.angle`,
`t.color3` channels, `t.direction` and `t.rotation` components, list-enum indices, union variant indices, bools
(n = 2: an XOR), and string, buffer, array and map lengths and counts (Roblox enums are EG-coded and excluded). From
`offsets.luau`:

```luau
-- seed 0                                   -- offsets c = 173 (n 256), 58 (n 101), 1 (bool)
wb(b, bit, 8, r.a)                          wb(b, bit, 8, band(r.a + 173, 255))
wb(b, bit + 8, 7, r.b)                      local x = r.b + 58; if x >= 101 then x -= 101 end; wb(b, bit + 8, 7, x)
wb(b, bit + 15, 1, if r.c then 1 else 0)    wb(b, bit + 15, 1, if r.c then 0 else 1)
-- decode                                   -- decode
a = rb(b, bit, 8)                           a = band(rb(b, bit, 8) - 173, 255)
```

For n near 2^53 the sum q + c can pass 2^53 and round, so the generated form is
`if q >= n - c then q - (n - c) else q + c` and its inverse `if w < c then w + (n - c) else w - c`: exact for
n = 2^53, 2^53 − 1 and 2^52 + 1 at the edge codes (`column_offset.out`). The decoder checks w < n (rule 2), then
inverts, then applies range, refusal and canonical checks to q (rules 3 and 6), so canonical decode is unchanged;
`offsets.out` round-trips every code of all eight fields.

Not applicable: `t.int()` (EG-0 of zigzag: an offset turns small values into long codes), string and buffer bytes,
`t.f32`/`t.f64`/`t.vector3f32` raw bits (an XOR mask on the raw u32 words would be zero bytes; not measured),
instance indices (n is per chunk), and everything the protocol fixes: headers, toc, ids (permuted per server
already), control rows.

**Column blocks** (`column_offset.out`, 64 rows, 200 trials; v5's residual coder of `v5.md` §4.3). Residuals are
taken modulo n, so (q_i + c) − (q_{i−1} + c) ≡ q_i − q_{i−1}: an offset changes only the first row's residual.
Two protocol rules are possible:

| n | pattern | identity bits | offset, first row against 0 | offset, first row against c |
|---|---|---|---|---|
| 4 | sequential | 137.0 | 73.2 | 137.0 |
| 32 | sequential | 137.0 | 185.1 | 137.0 |
| 32 | walk ±1 | 135.9 | 150.4 | 135.9 |
| 101 | sparse 10% | 89.3 | 96.8 | 89.3 |
| 4096 | constant | 14.0 | 22.1 | 14.0 |
| 4096 | sequential | 137.0 | 214.2 | 137.0 |
| any | uniform | equal | equal | equal |

- **Against 0** (today's rule): the offset is visible in every value of the block, at up to +77 bits per column in
  these patterns, sometimes fewer bits (n = 4).
- **Against c**: the residual stream is identical to identity's in every trial (verified), so zero bits; but then a
  decoder that ignores c reads the block's values exactly, so the offset protects nothing inside column blocks
  and acts on single rows only.

The draft read "offset 137 → 176" as a small cost of the offset; it is the first-row effect under rule "against 0",
and rule "against c" removes it along with the protection. Which rows are single: request and control runs always;
runs of fewer than 3 messages; at the busy model's 70 upstream frames for 70 messages a second (`v5.md` §4.1), most
upstream messages travel as single rows.

**R14 answered** (bit cost of permuted variant and enum indices under v5's coder, `security-refusals.md` R14):
a per-build *permutation* of an index's codes costs 137 → 331 bits for a sequential n = 32 column and 135 → 292 for
a ±1 walk (`enum_rotation.out`); an *offset* costs 0 (against c) or the table above (against 0). So index variation
should be an offset, never a permutation.

**Changes / fixed.** Changes the value-to-code map of every bounded code per build. Fixed: n and every width, the
decoder's rule set, field order (M1's), ids, the hash, golden vectors (c = 0 at seed 0), types.

**What it prices.** The same tools as M1, with one niche M1 lacks: definitions whose payload is one field, a bare
codec or a union (in the §3.4 example `buy`'s `item` enum and `announce`'s variant index), where M1 rotates
nothing. Limits: one known value per field (a spawn's `health = 100`) gives c, and a tool calibrating through the
shard's encoder (§0.3) gets every c at once; with the public seed of today every c is computable (§0.1). Does not
price **api**, **hook**, **state**.

**Cost** (`offsets.out`, 8 fields; `bytecode2.out`, 3-field definitions):
- CPU: +5.0 ns per field to encode and +7.3 ns to decode, interpreted (client); +5.0 and +5.9 native (server).
- Bytecode: an encoder grows from 224 to 356 B per definition, a decoder from 223 to 351 B (+59%, -O2 -g0).
- Bytes: zero for single rows; columns as in the table, by the rule chosen.
- Build: one draw per codec site.

**Composition.** Same seed as M1, read by a tool in the same pass. In M6 and M7 it is a second dimension of
variation for definitions M1 cannot vary. Reopens R14 (answered above). It does not bear on R12 (build-time id
rotation), contrary to the draft: offsets act on payload codes, not ids.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `build.offsets` | boolean | — | — | `true` (offsets apply only at a nonzero seed) | +5.0 ns encode and +7.3 ns decode per bounded field interpreted; +59% codec bytecode; column bytes per the protocol rule |

The column rule is a protocol constant, not an option: "first row against 0" or "against c" has to be chosen once
in the wire specification.

---

## M4. Id permutation mixed with a per-build value

**Status.** New (the generation note of `security-refusals.md` R12). Re-checked: the draft's reason is wrong; a
narrower one holds, and only with M1's private seed.

**What the build emits.** Grain: per build × per server. Both shards carry a 32-bit constant P drawn from the
rotation seed, and the permutation's xorshift32 seed gains one term (`v5.md` §4.5):

```luau
-- today (runtime path, and P = 0)                       -- generated, nonzero seed
local s = bxor(permSeed, hashLow, space)                 local s = bxor(permSeed, hashLow, space, 0x5be0cd19)
if s == 0 then s = 0x9E3779B9 end                        if s == 0 then s = 0x9E3779B9 end
```

**Changes / fixed.** Changes which wire id each canonical id gets, per build as well as per server. Fixed:
Fisher–Yates over xorshift32, id widths (a permutation keeps u(⌈log2 count⌉)), the three spaces, the hash, the PERM
vector (P = 0), encode-once (one table per server).

**What it prices, re-checked.** The draft said M4 stops id tables captured on one build from working on the next
build "of the same server seed". In production that case does not arise: every server draws its seed at start,
and a new build reaches players only through new servers (`restartServers`, `security-tooling.md` §4), so ids
already change at every build. What M4 changes is the inputs: today the permutation is computable from public data
alone, the seed from `WELCOME` (sent in clear; **packet**), the hash from the shared schema module and the
algorithm from Lync's source. With P, a packet-only tool also needs P from the shard each build (**code**). With
today's public build seed, P derived from it is computable too and M4 prices nothing (§0.1). It does not price
**mem** (the live table), **api**, or a tool that learns wire ids by observing its own client's sends once per
session.

**Cost.** Zero bytes. One more XOR per namespace and space at the permutation build, which costs 18.3 µs
interpreted and 4.3 µs native per 200 ids once per namespace per server (`security-refusals.md` §1, from
`probes/review-redundancy-2/inbound_hotpath.out`). Build: one draw.

**Composition.** M8 derives the permutation seed from a per-build secret and a nonce; with M8, M4 adds nothing and
should be dropped. Reopens R12 with a corrected reason: the per-server shuffle subsumes per-build ids in frequency,
not in which inputs a tool needs.

No option: P follows `build.seed`.

**Changed from the draft.** The "same server seed" case is removed as not occurring in production; the protection
is restated as non-derivability from public inputs, conditional on the private seed; M8 subsumes it.

---

## M5. Per-build column-mode choice

**Status.** New in the draft. Re-checked and measured: it prices no capability class.

**What the build emits.** Grain: per build. Column mode, k, and the frame-of-reference base and width are free
choices that every decoder accepts (`v5.md` §4.3, §4.8). The generated column encoder would take them from the
seed instead of choosing the fewest bits:

```luau
-- reference encoder (golden frames)           -- per-build choice for this column site
local mode, k = bestMode(residuals)            local mode, k = 2, bestKFor(2, residuals)  -- sparse, fixed by seed
```

**Changes / fixed.** Changes the bits of multi-row blocks only. Fixed: the decoder and every rule, single rows,
the hash, types; golden frames if seed 0 keeps the reference encoder. The planner must own the choice so the
differential test (`v5.md` §2, which compares both paths at fixed nonzero seeds) still agrees.

**What it prices.** Nothing that decodes or forges. A decoder accepts every choice, so a static decoder or forger
needs no knowledge of it; a tool that matches frame bytes against a pattern would notice, but no class in
`client-security.md` §1.2 works that way, and Lync's frames are already identified by their remote.

**Cost** (`free_choice.out`, 64 rows, mean over modes 1–3 each at its best k, against the reference choice): +82
bits on a constant column (+588%), +92 to +239 bits on 10%-sparse columns (+113% to +192%), +13 to +14 bits on ±1
walks (+10%), +56 to +58 bits on uniform columns (+7% to +18%). CPU: none (the encoder already costs every mode).

**Composition.** Independent of the others. Reopens nothing. Listed so the menu is complete; nothing in it prices
a modified client, so no option is proposed.

**Changed from the draft.** The draft guessed the byte cost from the k-shortcut's 6–14%; measured, it is 7% to
588% by pattern. Its "prices static byte-pattern tools" is restated: no class in §1.2 is such a tool.

---

## M6. Per-session variant from a build-time pool

**Status.** New in the draft, offered as reopening R4 (runtime field shuffling). Re-checked: the cost record of R4
is corrected, its protection verdict stands, and the draft's "free" selection is not free.

**What the build emits.** Grain: per build (the pool) × per session (the pick). The client shard carries K
upstream encoders per client-sent definition, each generated under its own rotation seed (M1 order, M3 offsets, M2
tag constants); the server shard carries the K matching decoders. The pick is i = (low 32 bits of the session key)
mod K + 1, so `WELCOME` is unchanged (G10 holds) and a `REKEY` re-picks. From `shapes.luau` and `dispatch.luau`:

```luau
-- one shape per build                         -- pool of K, picked once per session
Net.shoot = View.new(encShoot)                 local ENC_SHOOT = { encShoot1, encShoot2, encShoot3, encShoot4 }
                                               -- at WELCOME and at REKEY:
                                               view.enc = ENC_SHOOT[keyLow % 4 + 1]
```

Downstream codecs stay one per build (§0.2).

**Changes / fixed.** Changes the upstream layout and tag constants per session. Fixed: the protocol (each variant is
a valid layout of the same schema), the hash, types, downstream encode-once, golden vectors (K = 1 at seed 0).

**What it prices, re-checked against R4's 3.5 verdict** ("a forger who reads the per-session key reads a
per-session order in the same pass", `v5-changes.md` part 2). With the pick derived from the key, that is true by
construction; with a separate `WELCOME` field it would be the same read of the same frame. Over M1, a tool must
carry K layouts instead of one, and all K are in the client shard, so a code reader (**code**) or a calibrating
tool (**mem**) gets all K in the pass it already makes. A keyless sender fails the tag whatever the layout, and a
replayed frame fails the tag or the replay window. So no class pays a recurring per-session cost it does not
already pay for the key. M6 corrects R4's *cost* record (the 2–3x was a table-driven writer,
`security-refusals.md` §1); it does not change R4's protection verdict.

**Cost.**
- Client CPU (`dispatch.out`, one-`writebits` encoder so the dispatch dominates): a build-fixed encoder costs
  56.7 ns per fire interpreted because the compiler inlines it (`luau-compile --remarks`: "inlining succeeded" for
  that form only); a view field set at `WELCOME` costs 78.4 ns and a per-call pool index 76.5 ns. So a session pick
  costs about +20 ns per fire interpreted (+9 to +11 ns native) where the fixed encoder would have been inlined, and
  nothing where it would not; field and index differ within noise. The draft's "free" compared only those two.
- Bytecode: K × 224–356 B per definition for client encoders and K × 223–351 B for server decoders
  (`bytecode2.out`). For 200 client-sent definitions at K = 4 with offsets, about 214 KB more client bytecode,
  loading in roughly 0.1–0.5 ms per join on this Xeon at 0.5–2.4 ns per byte (`generation-security.md` §5.1).
- Source size: 200 offset encoders are 58,440 B of source (`bytecode.out`), so the 200,000-character script cap
  (reported, `generation-security.md` §2.4) fits about 680 encoder copies per `ModuleScript`: each variant must be
  its own module.
- Server memory: one index per player; the K decoder sets are shared.

**Composition.** M7 delivers one variant per player instead of all K. Reopens R4's cost record only.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `build.sessionVariants` | integer | variants | 1–16 | 1 | K× upstream codec bytecode on both sides; +about 20 ns per fire interpreted where the fixed encoder would inline |

**Changed from the draft.** "Selection is free" is corrected to about +20 ns per fire against an inlined fixed
encoder; the pick moved from a new `WELCOME` field to the key, so G10 holds; downstream is excluded; the protection
is re-judged against the 3.5 verdict the draft did not address, and comes out as no recurring cost.

---

## M7. Per-player variant delivered through `PlayerGui`

**Status.** In the draft as reopening R7 (refused in 3.5: "no work is added"). Re-checked: the refusal holds for a
tool working on its own client and fails for artefacts carried between accounts; downstream must be excluded.

**What the build emits.** Grain: per build (the pool of N) × per player (the assignment). `lync build` writes N
client variant `ModuleScript`s to `ServerStorage`, each holding what varies, and the server shard holds all N
counterparts and the assignment code:

```luau
-- server shard, generated (sketch)
local VARIANTS = ServerStorage.LyncVariants        -- N ModuleScripts, never replicated
local DECODERS = { decodersV1, decodersV2, ... }   -- N upstream decoder sets and tag constants
Players.PlayerAdded:Connect(function(player)
	local v = rng:NextInteger(1, N)                 -- or round-robin, so concurrent players differ
	assigned[player] = v
	local gui = Instance.new("ScreenGui"); gui.ResetOnSpawn = false; gui.Enabled = false
	VARIANTS[tostring(v)]:Clone().Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")
end)
```

What a variant holds is a choice with different costs:
- **tag-only**: the two tag constants (M2) and nothing else; layouts stay per build. The variant is a module of a
  few constants, and frames can be encoded before it arrives (M12).
- **upstream**: the client-sent definitions' encoders under the variant's rotation seed (M1, M3), plus its tag
  constants. Downstream layouts stay per build in every case (§0.2).

**Changes / fixed.** Changes which upstream layout and tag constants a client holds. Fixed: the protocol, the hash,
types, downstream encode-once, golden vectors (N = 1 at seed 0). The server decodes and verifies each player's
frames with that player's variant.

**What it prices.** The **share** class: a byte script, layout or set of constants extracted on one account fails
on accounts holding other variants, so tools built outside one client must be rebuilt per player variant, and an
artefact that contains variant data names the variant, which the server's assignment log ties to the players who
held it (attribution, `generation-security.md` §2.2; unique per player only while N is at least the concurrent
player count). Unlike M6, a client holds only its own variant, so reading its shard reveals no other player's. It
does not price **code** or **mem** on one's own client: a tool reading the loaded variant pays nothing extra (the
3.5 reason for R7 holds there), nor **api**, **hook** or **state**.

**Cost** (sizes from `bytecode2.out`, load from `generation-security.md` §5.1):
- Place: tag-only, N small modules; upstream, N × 356 B of encoder bytecode per client-sent definition (200
  definitions, N = 16: about 1.1 MB).
- Server: N decoder sets loaded in the server shard (N × 351 B per definition; the same 1.1 MB at 200 × 16), one
  variant index per player, and a lookup per frame (about +10 ns native, `dispatch.out`'s field form).
- Per join: one clone of one variant and its load, 0.5–2.4 ns per bytecode byte (a 71 KB variant: about
  35–170 µs on this Xeon), one `ScreenGui` per player.
- Client CPU: as M6's pick, about +20 ns per fire interpreted where a fixed encoder would inline; none for
  tag-only.
- Developer: client start depends on the variant's arrival (M12); arrival order against `ReplicatedStorage` is
  undocumented and must be measured in Studio and live (`generation-security.md` §2.3).

**Composition.** Needs M12. M10 is where the N counterparts live. Per-player tag constants are the base for the
next unit (a fact stating which variant a frame verifies under). Reopens R7, restated: 3.5's reason holds against
work on one's own client and does not hold against **share**; the "join-time dependency" becomes M12's rule.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `build.playerVariants` | integer | variants | 1–256 | 1 | as above, linear in N |
| `build.playerVariantScope` | `"tag" \| "upstream"` | — | — | `"tag"` | `"upstream"`: N× upstream codec bytecode in the place and the server, and the join hold of M12 for values |

**Changed from the draft.** Downstream is excluded; the tag-only form is new; the protection is narrowed to
**share** and attribution, with the 3.5 reason accepted for one's own client; server memory and the per-frame
lookup are stated.

---

## M8. Session key and permutation seed derived, not sent in clear

**Status.** New in the draft. Re-checked: the draft put the secret in the server shard, but the client must derive
the key too, so the secret is in the client shard and the method is per-build extraction plus a per-session nonce.

**What the build emits.** Grain: per build (a 64-bit secret S, from the rotation seed) × per session (a nonce).
Today the first `WELCOME` carries the key as two u32 and the permutation seed as a u32, in clear (`v5.md` §4.6).
With M8 the same fields carry a server-drawn nonce, and both shards derive:

```luau
-- today: key = (w.key0, w.key1); permSeed = w.permSeed
-- M8 (S0, S1 are client- and server-shard constants; 0, 0 on the runtime path and at seed 0):
local n = nonceBytes(w.key0, w.key1, w.permSeed)          -- 12 B as received
local key0, key1 = halfsiphash24x64(S0, S1, n, 1)         -- 64-bit output mode
local permSeed = halfsiphash24x64(S0, S1, n, 2)           -- low 32 bits
-- S = 0 means identity: key and permSeed are the fields themselves, so G10 is unchanged
```

A derived permutation seed of 0 is replaced by 1, since seed 0 means the identity permutation (`v5.md` §4.5).

`REKEY` carries a new nonce the same way.

**Changes / fixed.** Changes the meaning of three `WELCOME` fields and one `REKEY` field at a nonzero seed, not
their widths. Fixed: the tag, the count rules, the permutation algorithm, every frame after `WELCOME`, the hash,
G10 and the other vectors (S = 0).

**What it prices.** A tool that reads the key and permutation seed from the received `WELCOME` with a receive hook
(**packet**), without a memory read: it must now also extract S from the shard each build (**code**). The draft
claimed the secret ships to no client; it must ship to every client, since the client derives the key. Not
priced: **mem** (the derived key is in Lync's state after `WELCOME`), **api**, and any tool already reading the key
from memory. The question `security-refusals.md` left open (does the clear key in `WELCOME` change the stated
tamper cost "read the key every session"?) is answered yes: today a packet-level tool reads it with no memory
read; M8 restores "read memory, or read the shard per build". No third party sees `WELCOME`: the engine's transport
carries it to the client's own process (`v5-changes.md` part 2), so M8 is about tools in that process only.

**Cost.** One HalfSipHash-2-4 call of two 64-bit outputs per connection and per `REKEY`, on each side: about
1.8–3.5 µs interpreted (client) and 0.26–0.42 µs native (server) per 64 B (`v5.md` §4.5; 2-4 rounds cost somewhat
more than the 1-3 rounds measured, unmeasured). Zero bytes. Build: S from the rotation seed. With M1's public seed of
today, S would be computable from `HELLO` and M8 would price nothing (§0.1).

**Composition.** Needs M1's private seed. Subsumes M4 (the permutation seed is already per-build-keyed). With M7,
S can be per player variant, which is the next unit's binding. Bears on the R3 generation note
(`security-refusals.md` R3: key and seed reach the client in clear) and on R3's 3.5 verdict, whose "same memory
read" premise holds for memory readers and not for packet readers.

No option: on at any nonzero seed.

**Changed from the draft.** The secret is in both shards, not the server shard only; G10 is unchanged (the draft
said it must be rebuilt) because S = 0 is the identity; `WELCOME` keeps its size (the draft said it shrinks).

---

## M9. Codecs at call sites (composition only)

**Status.** Owned by `research/codecs-in-scripts.md`, which now exists (its §0 and §6–§9 were unwritten when read).
Composition with it is a next-unit item; this section corrects only the draft's figures.

- The draft cited "one 3-field offset encoder is ~470 B" from `bytecode.out`'s `defs_1` (474 B). That figure
  includes the module's own overhead; the marginal size is 224 B per plain encoder and 356 B per offset encoder
  (`bytecode2.out`).
- The draft carried `[client-security-build §3.2]`'s 5.0x bytecode. `codecs-in-scripts.md` §1 reproduces it as the
  worst case of one shape and reports 0.43x to 2.3x of the unwoven client total for realistic shapes, and 4.8x only
  when 50 sites fire one definition.
- It also reports woven sites 1.2–3.0x faster per call than a shard without the rollback `pcall`
  (`codecs-in-scripts.md` §1, §6.3). That bears on M6's and M7's dispatch cost (+about 20 ns per fire): a woven
  site resolves its encoder at build time, so a per-session pick would reintroduce exactly the dispatch weaving
  removes.
- Every method here is a choice of *what* the generator emits; weaving is a choice of *where* it lands. M1–M3 apply
  unchanged to woven encoders. M6's pool multiplies woven bytecode by K at every site, and M7's upstream scope
  would need N woven copies of every script that fires (inferred), which `codecs-in-scripts.md` §8 is to cover.

---

## M10. Build-time values in the server shard

**Status.** In the draft as the home of M8's secret and as reopening R29. Re-checked: M8's secret cannot live only
there; what remains is the server-side half of the pools and a delivery question for R29.

**What the build emits.** Grain: per build. The server shard (`ServerScriptService`, never replicated,
`security-tooling.md` §1) holds values the server needs and no client may hold:
- M7's N counterparts and the assignment table (each client receives one variant; the server holds all N);
- M6's K decoders (these are also in every client shard, so they are not private);
- the reachability lists of `v5-integrity.md` §3 (already planned);
- optionally, server-only policy written by the build as one `Lync.configure` call at the top of the server shard:

```luau
-- server shard header, generated from a server-only file named in lync.toml (sketch)
Lync.configure(require(script.Parent.LyncPolicy))   -- the same call game code makes; applies as configure does
```

**Changes / fixed.** No wire change. Fixed: everything; values carried in `WELCOME` still reach clients there.

**What it prices.** Nothing new by itself. Server-only options are already server-only through `Lync.configure`;
the shard is another place to put the same call. Its one necessary use is M7: a client must hold its own variant
and no other, so the full pool must live server-side.

**R29 re-checked** ("integrity policy in `lync.toml` or shared modules", refused because the runtime path needs it
without a build, server policy must never ship in shared code, and the client learns what it needs at the
handshake). On the generated path the server shard does not ship, so "never ship in shared code" does not apply
to it; the other two reasons stand, and a policy file in the build would be a second way to set one option
(principle 4) unless the build emits the same `Lync.configure` call, as above. `lync.toml` itself stays build-only
(in Studio-only projects a `StringValue` in `ServerStorage`), so it ships to no client either.

**Cost.** None at run time beyond the `configure` call. Server memory: the size of whatever the shard holds (M7's
N decoder sets dominate, about 351 B per definition per variant).

**Composition.** Required by M7; holds M6's server half. Reopens R29 on one of its three reasons only.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `namespace.serverPolicy` (`lync.toml`) | path to a server-only Luau module returning a `Lync.configure` table | — | — | none: no call emitted | one `configure` call at server shard load |

**Changed from the draft.** M8's secret is removed from M10 (the client needs it); the protection claim is
withdrawn; M7's pool is named as the use that needs it.

---

## M11. Per-server values through `ConfigService`

**Status.** In the draft as "the server runtime reads `ConfigService` at start" and as adjacent to R30. Re-checked:
Lync should emit nothing; the game's own `configure` call is the vehicle; R30 is not reopened.

**What the build emits.** Nothing. Grain: per server (or per player, through `GetConfigForPlayerAsync`). Game
code reads a config key and passes it to the existing call:

```luau
-- game server code (recipe, not generated)
task.spawn(function()
	local snapshot = ConfigService:GetConfigAsync()          -- server only; yields
	Lync.configure(snapshot:GetValue("lync"))               -- a JSON value; its Luau shape is unverified
end)
```

`ConfigSnapshot:GetValue` exists (API dump 0.741.19, verified). `ConfigService:GetConfigAsync` is server-only and yields; values are at most 100,000 characters; a publish reaches
servers in about 15 s to 1 min, or over a 15-minute gradual rollout (documented, `security-tooling.md` §1, §4).
Lync's `require` never yields (`v5.md` §3.5), so Lync must not make this read itself; `configure` never throws for
being late, and its options apply to later connections or from the next flush (`v5.md` §7.5).

**Changes / fixed.** No wire or code change. Values carried in `WELCOME` (`tag.cover`, `callerProbe.*`,
`clock.beacon`) still reach each client at its handshake; server-only values (`clock.reportSlope`,
`clock.reportFits`, `earlyAnswer.factor`, `canary.scanBytes`, budgets) never do.

**What it prices.** A tool tuned to stay just under a documented default threshold (a clock accelerated just
below `clock.reportSlope` 0.01, say, class **clock**) faces a per-server value it cannot read, and must stay under
the lowest value the game might set. That is the game's policy, not Lync's; every fact keeps an exact trigger,
because the threshold in effect on that server is the one the game set and knows. It prices nothing on the wire.

**R30 re-checked.** R30 kept tag width, lookahead, desync count, replay window and fit constants as constants, not
options. Those are protocol constants: they change what a decoder accepts and are versioned by the protocol
version in `HELLO` (`v5.md` §4.9). Varying them per server would need them in `WELCOME` and in the decoder, which
M11 does not do; it varies existing options only, so R30 is not reopened.

**Cost.** One yielding read per server start (or per player), and whatever the values cost by their own rows in
`v5.md` §7.5 and `v5-integrity.md`. Developer: the Configs API (publish 10 per minute, with rollback) to rotate
values from CI.

No option.

**Changed from the draft.** Lync does not read `ConfigService` itself (it would make start yield); the per-server
seed the draft suggested delivering this way is dropped, since servers already draw one; R30 is not reopened.

---

## M12. Join rule for per-player variants

**Status.** In the draft ("the bootstrap loader does `HELLO`; the variant does data"). Re-checked against the join
hold: the draft's rule fails for upstream-scope variants, because held sends are encoded bytes.

**The constraint** (`v5.md` §5.3, §4.5, §3.5). The client holds a namespace's reliable sends until its `WELCOME`,
up to 32,768 B: the hold is measured in bytes, so sends are encoded at `fire`. Unreliable sends before `WELCOME` are
dropped (`sendDropped` cause 2). `HELLO` frames are untagged and the first tagged frame has count 0. `require`
never yields. Whether a server-parented `PlayerGui` child arrives before the client's first send is undocumented
(`generation-security.md` §2.3); the `RemoteEvent` queue keeps a `WELCOME` sent before the listener connects
(documented, `security-tooling.md` §1).

**The rule, by M7's scope.**
1. `HELLO` comes from the shared client shard, which carries the build id and the hash; it never waits for the
   variant.
2. The client binds its variant without yielding `require`: a thread waits for the variant under `PlayerGui` and
   installs it.
3. **Tag-only scope.** Encoding at `fire` uses the per-build layout, as today. The tag is computed when a frame is
   sent, so the variant's constants are needed only then. The join hold's release condition becomes "`WELCOME`
   received and variant installed"; nothing else changes.
4. **Upstream scope.** The encoders arrive with the variant, so a send before it cannot be encoded. Held sends are
   kept as deep copies of their values, each charged its definition's worst-case encoded size (the planner's
   `messageTooLarge` bound, `v5.md` §3.4) against the 32,768 B hold, and encoded on release. Encoding them with a
   shared bootstrap layout instead would require the server to accept that layout from every player, which a tool
   would then always use, undoing M7.
5. Unreliable sends before both conditions are dropped as `sendDropped` cause 2, with the trigger widened to
   "before `WELCOME` or before the variant".
6. **Server.** It assigns the variant before cloning it, so it decodes and verifies the first tagged frame under
   that variant; a frame tagged under another variant fails as `tagMismatch` (stating which variant it verifies
   under is the next unit).
7. **A variant that never arrives** on an unmodified client: a local client fact by the pattern of
   `remotesMissing`, say `variantMissing` after 10 s, keeps waiting. It is a new code with its own trigger.

**Changes / fixed.** Changes the client's start sequence and the hold's release condition; with upstream scope,
the hold's unit (values charged at worst case). Fixed: the handshake, the tag rules, the count, the hash, golden
vectors (N = 1 means no variant).

**What it protects.** Nothing by itself; it makes M7 correct whatever the arrival order.

**Cost.** Tag-only: none beyond waiting for the variant, by an unmeasured delay after `WELCOME`. Upstream: a deep
copy per held message until the variant arrives (unmeasured), and a hold that fills sooner, since worst-case sizes
exceed actual ones.

**Composition.** Required by M7. Reopens nothing; it answers R7's "join-time dependency" with a defined hold.

No option.

**Changed from the draft.** The draft held frames until the variant without saying what the hold stores; held
sends are encoded bytes, so its rule works only for tag-only variants; the value-hold rule, the widened
`sendDropped` trigger and `variantMissing` are new.

---

## Summary

| Method | Grain | Prices (classes) | Wire bytes | Client CPU (interpreted) | Server CPU (native) | Bytecode | R/D/U |
|---|---|---|---|---|---|---|---|
| M1 field order, private seed | build | **share**; A2, A3 encoding outside `fire`; needs the private seed to require **code** | 0 | 0 | 0 | 0 | R5 noted |
| M2 tag constants | build | tag reimplementations only | 0 | 0 | 0 | 0 | U2 in part |
| M3 code offsets | build | as M1, plus one-field and union definitions | 0 single rows; columns by rule | +5.0 ns/field enc, +7.3 dec | +5.0, +5.9 | +59% per codec | R14 answered |
| M4 id seed mixing | build × server | **packet**-only tools; needs the private seed | 0 | 0 | one XOR per table | 0 | R12 |
| M5 column-mode choice | build | nothing | +7% to +588% per column | 0 | 0 | 0 | — |
| M6 session pool | build × session | no recurring cost beyond the key read | 0 | ≈ +20 ns/fire where inlinable | ≈ +10 ns/frame | K× upstream codecs | R4 cost record |
| M7 player variants | build × player | **share**; attribution | 0 | 0 (tag) or ≈ +20 ns/fire | ≈ +10 ns/frame | N× in place and server | R7 restated |
| M8 derived key and seed | build × session | **packet**-only tools; needs the private seed | 0 | ≈ 2–4 µs per session | ≈ 0.3–0.5 µs per session | 0 | R3 note, open question answered |
| M9 call sites | — | composition: next unit | — | — | — | — | R6 |
| M10 server-shard values | build | nothing new; holds M7's pool | 0 | 0 | 0 | server only | R29 in part |
| M11 `ConfigService` | server, player | **clock** tools tuned under a default | 0 | 0 | one read | 0 | not R30 |
| M12 join rule | — | makes M7 correct | 0 | copies while held (upstream) | 0 | 0 | R7 timing |

Every per-build row assumes M1's private seed; with today's public seed, M1–M4 and M8 price only tools that
hard-code values (§0.1).

## Implications

1. Replace the published build seed with a public `buildId` and a private 64-bit `rotationSeed` drawn from OS
   entropy; without it, M1–M4 and M8 price only hard-coded tools (§0.1, M1).
2. Keep M1 and M2 as specified, with the narrowed statement of what each prices (M1, M2).
3. Adopt M3 offsets for bounded codes, with `build.offsets` and its stated cost, and choose the column first-row
   rule once: "against 0" keeps protection in blocks at up to +77 bits per column, "against c" is free and
   protects single rows only (M3).
4. Close R14 with M3's measurement: vary enum and variant indices by offset, never by permutation (M3).
5. Adopt M8 together with the private seed, and drop M4, which M8 subsumes (M4, M8).
6. Record M5 as pricing no capability class; do not specify it (M5).
7. Correct R4's cost record (variant pick: about +20 ns per fire, not 2–3x) and keep its protection verdict; do
   not add M6 (M6).
8. If per-player variants are wanted, specify M7 in tag-only scope first, with M10 for the pool and M12's hold
   rule; its price is on **share** and attribution only (M7, M10, M12).
9. Never vary downstream layouts per session or per player; it ends encode-once and `FireAllClients` (§0.2).
10. Leave `ConfigService` to game code through `Lync.configure`; Lync's start must not yield (M11).
11. Next unit: per-player tag binding (builds on M7 and M8), generated traps, decoys and canaries, the runtime
    path's per-session parameters, and composition with `codecs-in-scripts.md` (checklist).

---

## M13. Per-player tag binding: one output mask per variant

**Status.** New (checklist "next unit"). It changes what M7's tag-only variant holds: one 32-bit output mask in
place of two initialisation constants, because only a mask lets the server name the other variant without
re-hashing. Probe: `tagbind.luau` → `tagbind.out` (Lync's own HalfSipHash from git `f1fbfd7`, exported by
`run3.sh`; 32-bit output over the `v5.md` §4.5 input, all bytes covered).

**The binding.** Grain: per build (N masks) × per player (the assignment). The build draws m_1 … m_N, each the low
32 bits of HalfSipHash-2-4 keyed by M1's `rotationSeed` over `"mask"` and the variant number as u16le, redrawn while
it is 0 or repeats an earlier one. Variant v's module (M7, `PlayerGui`) holds m_v and nothing else; the server
shard holds all N (M10). With N = 1, or at seed 0, there is no variant and m = 0. The tag becomes:

```luau
-- client, M7 tag-only today                         -- client, M13
local tag = H13(key, input, IV0_v, IV1_v)            local tag = bxor(H13(key, input, IV0, IV1), MASK)   -- IV per build (M2)

-- server, today                                     -- server, M13 (v = assigned[player])
for j = 0, 4 do                                      local other, jAt = 0, 0
	if H13(key, inputAt(e + j)) == tag then          for j = 0, 4 do
		return accept(j)                                 local d = bxor(H13(key, inputAt(e + j)), tag)
	end                                                  if d == MASK[v] then return accept(j) end
end                                                      if other == 0 then other = VARIANT_OF[d] or 0; jAt = j end
tagMismatch(e)                                       end
                                                     if other ~= 0 then tagVariant(other, v, jAt) else tagMismatch(e) end
```

The server already computes H13 at every candidate count; d is one XOR and `VARIANT_OF[d]` one table lookup per
candidate. Unreliable frames do the same at the extended seq and its two neighbours, before the replay window.
While a `REKEY` is pending, the candidates under the new key (counts 0 … 4) are looked up too.

**The fact.**

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `tagVariant` | a tagged upstream frame whose tag fails under the player's assigned mask at every candidate (reliable: counts e … e + 4; unreliable: the extended seq and its two neighbours), and for which tag XOR H13 at one candidate equals another variant's mask; reported in place of `tagMismatch` for that frame | frame dropped; e unchanged; counts as a failure toward `desync` | `lane`, `variant` (the matching mask's variant), `assigned` (the player's), `skipped` (reliable: j, the candidate's offset from e; unreliable: −1, 0 or 1, the neighbour of the extended seq) | chance: a frame failing for a `tagMismatch` cause matches one of the N − 1 other masks with probability (N − 1) × 5 × 2^−32 (reliable) or (N − 1) × 3 × 2^−32 (unreliable); a Lync bug installing a variant other than the one assigned |

What a `tagVariant` states: the frame's tag is this session's keyed hash at a count within the lookahead, masked
with variant u's mask. Short of chance, its sender held this session's key and u's mask. Who held u is the
assignment: the server knows it for its own players, and games that log a server API `Lync.variantOf(player)`
(0 when there are no variants) can find it across servers. It names a player uniquely only while N is at least
the number of concurrent players and assignment is round-robin (M7).

Chance matches, at the full default frame budgets (120 reliable × 5 candidates + 240 unreliable × 3 candidates
per second, `v5.md` §7.5) for a sender without the key (`tagbind.out`, computed): N = 2, one per 904 h;
N = 16, one per 60 h; N = 64, one per 14 h; N = 256, one per 3.5 h. A carried mask matches on every frame it is
used for, while chance matches come one at a time and name variants at random. The `count` and `variant`
fields show which of the two a game is seeing; Lync states both, and does not choose between them.

**Changes / fixed.** Changes the value of every upstream tag for N ≥ 2. Fixed: zero bytes; the tag width, its input,
`tag.cover`, the count rules, the lookahead, the replay window; the M2 constants (per build, shared by every
variant); the hash, types; G4, G5 and G8 (m = 0). `tagMismatch`'s trigger gains "and no other variant's mask
matches".

**What it prices.** **share**: a tag routine, mask or byte tool carried from one account to another now produces
a fact naming the source variant on each frame, instead of a `tagMismatch` that does not say why. That moves
M7's attribution from "an artefact names its variant, if someone finds the artefact" to "the server states the
variant per frame". Not priced: a tool that reads its own client's variant (**code**, **mem**); a tool holding
the key that also sees its own client's tagged frames (**mem** with **packet**), which can learn its own mask
from them; **api** and **hook** (`fire` tags with the client's own mask); a sender without the key, which gets
chance facts only.

**Rejected alternatives, measured** (`tagbind.out`, best of 7 on a shared Xeon):

| Server work per frame | 64 B interpreted | 64 B native | 1024 B native |
|---|---|---|---|
| accepted at e, today | 2.60 µs | 0.45 µs | 4.02 µs |
| accepted at e, mask | 2.53 µs | 0.43 µs | 3.93 µs |
| failing (5 counts), today | 12.57 µs | 1.97 µs | 20.33 µs |
| failing, mask and 5 lookups | 13.07 µs | 2.21 µs | 19.75 µs |
| failing, re-hash under 15 other variants' constants (N = 16) | 199.0 µs | 31.4 µs | 314.1 µs |

- **Per-variant initialisation constants** (M7's tag-only form as written). The variant's constants change the
  hash's initial state, so naming the other variant needs 5 × (N − 1) full hashes per failing frame: 31.4 µs native
  per 64 B frame at N = 16, about 534 µs at N = 256 (× 255/15, derived). At 120 failing 1 KB reliable frames a
  second, N = 16 costs 37.7 ms of server CPU a second for that player (derived). Usable only sampled, for example
  at most once per `desync`.
- **Per-variant key secret** (M8's S per variant). The key differs per variant, so naming needs the same re-hash,
  plus N key derivations per session (0.26–0.42 µs each, native). It prices **share** no more than the mask: both
  are one value read from the same variant module. S stays per build.

The mask costs nothing measurable: accepted frames differ by one XOR (within noise in all three columns) and
failing frames by 5 lookups (+0.5 µs interpreted, +0.24 µs native at 64 B, below noise at 1 KB).

**Memory.** Server: `VARIANT_OF`, 13,312 B for 256 masks (`tagbind.out`), plus the N masks, once per server. Per
player: the variant index M7 already keeps. Client: one u32.

**Composition.**
- **M7.** Tag-only scope now holds the mask; upstream scope holds the mask and its encoders. The join rule is
  unchanged: tags are computed at send, so frames wait for "`WELCOME` received and variant installed" (M12
  rule 3). M12 rule 6's open item ("stating which variant it verifies under") is `tagVariant`.
- **M2.** Unchanged and shared: the constants are per build, the mask per variant.
- **M8.** The key is derived per session from the per-build S, then masked. A `tagVariant` therefore also states
  that the sender derived this session's key.
- **M10.** Holds the N masks and `VARIANT_OF`. **M16's** composition row (tag-level, like M2 and tag-only M7) holds.
- **Runtime path.** Masks are data, not code: a runtime-path server could draw N masks at start and give each
  player one through `PlayerGui`, which binds per server instead of per build. A per-session mask sent in
  `WELCOME` binds nothing: it reaches the same client in the same frame as the key, so it is only a longer key.

No option: masks follow `build.playerVariants` ≥ 2. One server API (`Lync.variantOf`), one fact code.

**Implications.** Specify M7 tag-only as one output mask per variant, not constants (table above). Add
`tagVariant` with its chance rate in the known causes. Keep S per build. Expose `Lync.variantOf(player)` so games
can log assignments.

---

## M14. The runtime (no-build) path: per-server and per-session parameters through tables

**Status.** New (checklist "next unit"; reopens R5, "the runtime path always runs at seed 0"). Measured on Lync's own
runtime interpreter, not a model of one. Probe: `runtime_path.luau` → `runtime_path.out`, run by `run3.sh`, which
exports git `f1fbfd7:src` (the milestone build: planner, `codec/rows.luau`, `wire/bits.luau`) into the work
directory. `patch_rows.py` writes a copy of `rows.luau` whose int, bool and enum branches read an offset from the
IR. Each figure is the best of 7 runs of 200,000 rows on a shared Xeon. Run-to-run noise is about ±5% interpreted
and up to ±20% native, so differences under about 80 ns are noise.

**What the runtime path can vary without `loadstring`.** Anything the interpreter reads from the IR, which is a
table:
- **field order**: a permuted `fields` array in a copy of a record's IR (M1's Fisher–Yates);
- **code offsets**: `offset` and `n` on int, enum and bool codecs (M3), with the patched branches;
- **tag constants**: the runtime's `HalfSipHash.hash` already takes `iv0, iv1` as parameters (read in
  `f1fbfd7:src/wire/halfsiphash.luau`), so per-connection constants need no code change.

It cannot vary anything that is code shape (M5, M15's generated traps, or pools of encoder bodies), and it has no
private value: the client has no build, so every parameter must reach it in `WELCOME` or be derived from what
`WELCOME` carries.

```luau
-- runtime path today: one IR at seed 0             -- M14: an IR copy per server (or per session)
Rows.write(w, def.data, value, instances)           Rows.write(w, conn.layout[def], value, instances)
                                                    -- conn.layout built once, at the first WELCOME:
                                                    --   variantIr(def.data, xorshift32(layoutSeed ⊕ pathHash))
-- interpreter's int branch gains (patch_rows.py):
local offset = codec.offset
if offset ~= nil then
	local n = codec.n
	code = if code >= n - offset then code - (n - offset) else code + offset
end
```

**Grain and wire.** One field in the connection's first `WELCOME`, `layout` u2: 0 off (identity, all golden
vectors), 1 per server, 2 per session. The parameters are derived, not sent:
- **per server**: the layout seed is the low 32 bits of HalfSipHash-2-4, zero key, over the permutation seed
  (already in `WELCOME`) and `"layout"`. Upstream and downstream layouts are both per server, so every client of
  a server shares one downstream layout, and encode-once and `FireAllClients` hold (§0.2).
- **per session**: the upstream layout seed is derived the same way from the first `WELCOME`'s key; downstream
  stays per server. A `REKEY` keeps the layout, so decoders never switch in the middle of a session.

Fixed: the hash (computed at seed 0), types, widths, ids (already permuted per server), `HELLO` (seed 0), the
tag's input. G10 gains the 2-bit field (value 0); the other golden vectors are unchanged. The differential test's
seed seam (`v5.md` §2) becomes the production path, which answers R5's question "is the seam safe in production":
it is the same pure-Luau xorshift32 and Fisher–Yates on both ends. One conflict: a generated shard built at
`build.seed = 0` also sends seed 0, cannot follow a varied layout, and would mis-decode. Seed-0 shards exist only
in tests, so the test fixture sets `layout` 0. A `HELLO` bit would remove the conflict for one bit per `HELLO`.

**Measured: the runtime path against the generated path** (`runtime_path.out`; ns per row, harness included, which
alone is 35–45 ns interpreted and 23–25 native; s3 = 3 bounded fields, s8 = 8 bounded fields, sm = enum, string,
int and optional):

| Form | s3 enc / dec, interpreted | s8 enc / dec, interpreted | sm enc / dec, interpreted | s3 enc / dec, native | s8 enc / dec, native |
|---|---|---|---|---|---|
| I: `Rows.write`/`Rows.read`, as built | 742 / 831 | 1747 / 1852 | 1112 / 1004 | 325 / 447 | 780 / 894 |
| C: closure tree built from the IR | 487 / 629 | 1337 / 1516 | 864 / 817 | 216 / 387 | 546 / 814 |
| Cf: closures, bit positions fixed at plan time | 333 / 369 | 768 / 791 | n/a | 203 / 274 | 452 / 551 |
| G1: generated straight line on `Bits.write` | 396 / 515 | 915 / 1102 | 663 / 621 | 166 / 267 | 345 / 670 |
| G2: generated straight line, inline `writebits` at constant positions | 229 / 184 | 447 / — | n/a | 134 / 161 | 274 / — |

- **The interpreter as built** is 3.2–3.9x the fastest generated form (G2) to encode and 4.5x to decode (s3)
  interpreted, and 2.4–2.9x to encode native. That matches the earlier 3.2–4.6x (`v5.md` §0) for this form. Against
  a generated encoder on the same writer (G1), it is 1.7–1.9x interpreted and 1.9–2.3x native.
- **A table-driven runtime path need not be that slow.** With bit positions fixed at plan time and one growth check
  per row (Cf), it is 1.45–1.72x G2 to encode and 2.0x to decode interpreted, 1.5–1.65x to encode native. It beats G1 interpreted (0.84x) but not native
  (1.2–1.3x). Most of the generated path's advantage comes from constant bit positions, not from straight-line
  code. Cf applies to fixed-width rows; rows with strings, optionals or arrays need a running cursor, and there the
  closure tree (C) is 1.3x G1 (sm).
- So the earlier figures are right for today's interpreter and too high as a bound on the runtime path. The
  2–3x of R4 compared a closure loop with straight-line code (`security-refusals.md` §1); Cf is that loop with
  constant positions.
- Scale (derived): at the busy model's 70 upstream messages a second, I against G2 on s3 costs
  (742 − 229) × 70 = 36 µs/s of client CPU; Cf against G2 costs 7 µs/s. The tag on the same 70 frames costs
  2.2 µs × 70 = 154 µs/s (64 B, interpreted, from the same output).

**Measured: what per-session parameters add on the runtime path**:
- **Order** (Ip against I): −48 to +19 ns encode interpreted, +2 to +16 native: zero within noise. The interpreter
  already iterates a field array, which verifies CSB's assertion (R5 "costs cited").
- **Offsets**, interpreter (Io against I): +6, +59 and +77 ns encode interpreted for 3, 8 and 3 bounded fields; +42,
  +77 and +22 native. That is 2–26 ns per bounded field, limited by noise, the order of M3's +5.0 / +7.3 ns on
  the generated path. Decode moves −30 to +76 ns, within noise.
- **Offsets**, closures (Co against C, Cfo against Cf): −70 to +39 ns, within noise. Cf does the offset arithmetic
  even at offset 0, so Cfo − Cf is 0 by construction.
- **Tag constants from a table**: 2.21 against 2.17 µs (64 B) and 27.4 against 29.1 µs (1 KB) interpreted;
  0.32 against 0.33 µs native: zero.
- **Set-up per definition** (once per connection on the client; on the server once per server, or once per player
  per session): an IR copy takes 1.5–4.3 µs interpreted and 0.8–3.0 µs native, and holds 1.7–3.8 KB. A closure
  tree takes another 0.9–2.0 µs and 1.5–2.9 KB. These are full copies, an upper bound; sharing the unchanged
  string and optional nodes would shrink them (not measured). For 200 definitions: about 0.3–0.9 ms and
  0.34–0.76 MB per client connection (derived). On the server, per session means the same for each player: 34–76
  MB at 100 players (derived). Per server means it once.
- **Per frame on the server**: the player's layout table is one more lookup (+about 10 ns native, M6's
  `dispatch.out`). Per server needs none.

**What it prices.** The parameters come from `WELCOME` fields, which a **packet** tool reads, and from Lync's own
planner, which any tool can call (**api**). So M14 prices only tools that hard-code a no-build game's layout or
the reference tag constants: static forgers (A2) and byte scripts carried between servers (**share**), which
today work against every no-build game with no change. That is the same verdict as M1 under today's public seed
(§0.1), at per-server grain instead of per-build grain, and the same reason the id permutation stays on by default
(`client-security.md` §3.4: no run-time cost, and copy-paste byte scripts are removed as a class). Per session
prices nothing more than per server: whoever reads the key reads the layout in the same pass (R4's 3.5 verdict).
It does not price **mem**, **code**, **api**, **hook** or **state**.

**Composition.** Uses M1's order and M3's offsets as data; M3's column rule ("first row against 0 or against c")
applies unchanged. M2's constants become per-server values derived from the key or the permutation seed.
M6, M7, M8 and M15 are generated-path only. M13's masks can reach a runtime-path client as data (M13).
Downstream varies at most per server (§0.2).

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `layout.vary` (`Lync.configure`, runtime path only; u2 in `WELCOME`) | `"off" \| "server" \| "session"` | — | — | `"server"` | `"server"`: per definition, once per server and once per client connection, 1.5–4.3 µs and 1.7–3.8 KB (IR copy); offsets +2 to +26 ns per bounded field per message; order and tag constants 0. `"session"`: the same per player on the server (34–76 MB at 200 definitions × 100 players), and +about 10 ns native per frame |

**Implications.** Reopen R5: let the runtime path vary order, offsets and tag constants per server through IR
tables, on by default, with its protection stated as hard-coded tools only. Do not offer `"session"` unless a use
appears that `"server"` does not cover. Record the runtime path's cost as 1.7–1.9x a generated encoder on the same
writer and 3.2–3.9x the inline form for the interpreter as built, and let the runtime team decide whether to adopt
Cf's plan-time bit positions (1.45–1.72x).

---

## M15. Per-build generated traps, decoys and canaries

**Status.** New (checklist "next unit"). Three parts that differ in grain: traps can be generated per build,
canaries can be made per viewer at run time, and decoys gain only a generated value helper. Probe:
`generated_integrity.luau` → `generated_integrity.out` (`run4.sh BUILD_DIR`; Luau 0.742, `taskset -c 3`). The
HalfSipHash-1-3 in the probe is a cost model with the reference structure, not checked against test vectors.

### M15a. Generated trap definitions (reopens R13)

**What the build emits.** Grain: per build. With `build.traps = T`, the planner adds T client-sent definitions to
each complete namespace (see below), never to the shared schema module. Each takes the codec of a real client-sent
definition of the same namespace, drawn by the rotation seed, so its encoder is generated by the same emitter under
M1 and M3 and differs from its source only in constants and order. Each gets a name drawn by the build from the
namespace's own name tokens (a rule the lead must fix; unverified that any rule yields names a reader cannot
separate). Ids: canonical order puts the T traps among the real up-space ids by name, then the per-server
permutation applies as for every id (`v5.md` §4.5).

```luau
-- client shard, T = 0                         -- client shard, T = 1 (generated; not in the schema module)
Net.strike = View.new(encStrike, 3)            Net.strike = View.new(encStrike, 3)
Net.buy    = View.new(encBuy, 1)               Net.buy    = View.new(encBuy, 1)
                                               Net.swap   = View.new(encSwap, 4)  -- strike's codec, own order and offsets
-- server shard: TRAP[4] = true; decoder decSwap (to find the next message's start)
```

The exported Luau and `.d.ts` types omit traps, so strict game code cannot name them; the runtime table holds them.

**Fact.** `unreachable`, with `declared` widened to 0 (inferred), 1 (`:trap()`), 2 (generated). Exact trigger: a
message on a generated trap's id. Action: dropped, ask `rejected`, as a declared trap (`v5-integrity.md` §3).
Evidence: `declared`. Known causes on an unmodified client: none from scripts in the built place (no game code
can name a definition the build invented after the scan); in Studio, the command bar or a plugin calling it; and
game code that iterates the namespace or indexes it by a computed name. The last is why traps go only into
**complete** namespaces (`codecs-in-scripts.md` §4.2, including its iteration fix): in an incomplete namespace a
generic loop over `Net` would fire them from unmodified code.

**What it protects, and what it does not.** It prices **api** drivers that browse the namespace and fire what they
find. Reachability already catches any real definition client code never fires, so T > 0 adds bait only where a
namespace has few such definitions. It does not price drivers that fire only what game code fires (the caller
probe and M16's site ids cover those), **packet** or blind senders (an unknown id is already `malformed`), or a
tool that separates generated entries from real ones by reading the build's outputs (**code**). R13's reasons,
re-checked: "two ways to declare traps" holds only if `build.traps` were a second declaration; it is a generator
setting with its own `declared` value, so principle 4 is kept. "Reachability is the automatic trap" holds, and is
why the default is 0.

**Cost.**
- Bytes: zero per honest message unless D + T crosses a power of two in the up space (`generated_integrity.out`
  (e)): D = 20 takes T ≤ 12 free; D = 32 pays +1 bit per upstream run for any T ≥ 1; D = 7 pays +1 bit at T ≥ 2.
- Bytecode: one encoder per trap in the client shard, 224 B plain or 356 B with offsets (`bytecode2.out`), and one
  decoder in the server shard (223 or 351 B).
- CPU: none on honest traffic; the trap flag is the check `unreachable` already makes (`v5-integrity.md` §3).
- Fixed: the schema hash (traps are not schema), types, golden vectors (T = 0 at seed 0). The trap set is a
  function of the build, so client and server shards must come from one run, and the handshake must cover it
  (M16, `weaveHash`).

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `build.traps` | integer | definitions per complete namespace | 0–8 | 0 | as above; ignored (build diagnostic) for incomplete namespaces |

### M15b. Decoys: a generated value helper, never generated placement

**What the build can and cannot emit.** Placement decides whether honest rendering ignores a decoy, and only the
game knows that (`v5-integrity.md` §8; Activision's "behavior generator", `anticheat-design.md` §2.1). So the build
generates no behaviour. What it can generate is the value part of the copy-and-update form: per collection, a
helper that clones a live record's fields, leaves key and placement to the behaviour, and keeps every value inside
the real codec because it is a real value.

```luau
-- today: the behaviour builds every field
return { [key] = { pos = p, health = 100, team = 2, ammo = 31, skin = 4 } }
-- generated helper (server shard, per collection): values from a live record, placement from the behaviour
return { [key] = Net.fighters:decoyFrom(sourceKey, { pos = p }) }   -- clone of sourceKey's record, pos replaced
```

Codec-uniform draws are the other generated form; they are worse on both counts: their values follow the codec's
range, not the game's distribution (a uniform `health` against mostly-full real health), and they cost more
(`generated_integrity.out` (d), 6 fields: clone-and-offset 118–138 ns interpreted, 81–85 native; uniform draws
242–244 and 195–199).

**Interest rule kept.** The helper produces values only; every decoy still passes the viewer's interest test, and
one that fails throws `decoyOutsideInterest` in the behaviour's thread (`interest-rewind.md` §6.1). A cloned source
inside the viewer's block does not make the decoy's own placement pass; the test is on the decoy's filed cell.

**Facts.** Unchanged: `decoyReferenced` (`v5-integrity.md` §10). `decoyFrom` with an unknown key, or with a
placement field the record lacks, throws `unknownField` at the caller; a key equal to a live one is `decoyKeyLive`
as today.

**What it protects, and what it does not.** It narrows one signal a **state** reader could use (values out of the
game's distribution), at no extra wire cost. It changes nothing about placement or about the tell of two accounts
comparing key sets (**share**, R15), and nothing per build: decoys are run-time values, so a build-time variant adds
no recurring work.

**Cost.** The clone (above) per decoy per state tick, inside the existing 236 ns behaviour-and-diff figure's
budget; zero bytes over today's decoys; no option (an API method).

### M15c. Canaries unique per viewer

**What Lync emits.** Grain: per viewer, at run time; the build contributes nothing but the generated code. Today a
canary is one 12-character value per record per server, shared by every viewer (`v5-integrity.md` §9), so an echo
names the record and the server, and is reported only when it arrives from a player it was sent to. With
`canary.perViewer`, the value is 8 shared characters plus a 4-character suffix that carries the viewer's join number
j (23 bits) masked by a server-only key:

```luau
-- today: one value for every viewer               -- perViewer: prefix shared, suffix per viewer
value = base12                                      value = base8 .. enc4(bxor(j, prf(key, slot, adds)) % 2^23)
-- prf: HalfSipHash-1-3 keyed by a per-server key drawn at start (never sent); enc4: 4 chars of [A-Za-z0-9]
```

On an echo, the prefix finds the slot through the existing server-wide map; one PRF recovers j, and the per-viewer
bitset says whether the add went to that viewer. The probe round-trips 2,001 suffixes exactly.

**Wire.** Same 12 bytes per add. Strings live in the tail (`v5.md` §4.2), so the bit section of a state chunk is
identical across viewers and only 4 tail bytes differ: the chunk is encoded once and each viewer's copy is patched.
Frames carrying such adds differ per viewer, so they leave `FireAllClients` for those flushes, as decoys do.

**Fact.** `canaryEchoed` with its trigger widened to "a live canary sent to any player", and two evidence numbers:
`sentToUserId` (the `UserId` the value was sent to) and `sameViewer` (1 if that is the sender). Known causes on an
unmodified client: for `sameViewer` 1, those of today (game code sending a record's fields back); for 0, chance
only: about 62^−8 × (viewers sent the add) / 2^23 per 12-byte window (5.5 × 10^−20 at 100 viewers), since an
unmodified client never receives another viewer's suffix. A value found outside the game names the session it was
sent to, which is the attribution `anticheat-design.md` §6 asked for.

**What it protects, and what it does not.** It prices **share**: values carried between accounts, or out of the
game, now name their source session, where today a relay through a second account is not reported at all. It
prices **state** readers that echo, as today. It does not detect a reader that never sends values back or that
normalises them before sharing (`anticheat-design.md` §6's limit); and per-build generation adds nothing to it,
since a canary that varied per build but not per viewer would name only the build.

**Cost** (`generated_integrity.out`, server native): PRF and suffix 220 ns per (viewer, add) (1,008 interpreted);
the patched copy 67 ns per viewer (79 interpreted); recovery 312 ns per hit only. For 100 viewers and 10 canary
adds a second: about 0.29 ms of server CPU a second. Memory: one 64-bit key per server; the bitset is today's.
Chance hits: as above. Today's 12-character draw is 415–452 ns in the CLI with `math.random` standing in for
`Random`.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `canary.perViewer` | boolean | — | — | false | about 290 ns native per (viewer, canary add); those flushes leave `FireAllClients`; server-only |

**Composition.** M15a needs the reachability scan and complete namespaces; with M16's site ids every closed
definition already reports its generic id, so traps add least to woven builds. M15b and M15c are downstream and
untouched by M1–M8 (§0.2 forbids per-viewer layouts, and neither changes a layout). Reopens R13 as an option with
default 0; leaves R15 and R17 refused.

**Changed from the draft.** Not in the draft.

---

## M16. Composition with codecs in game scripts

**Status.** New (checklist "next unit"); replaces M9's pointer. Inputs: `codecs-in-scripts.md` §6–§9 (cited CIS)
and its probes, `dispatch.out`, `bytecode2.out`. No new probe: every figure below is from those outputs. M13 was not
in this file when this was written; it is taken as the checklist states it (per-player tag constants or key
derivation bound to the player's variant).

**Rule.** The methods choose *what* the generator emits; weaving chooses *where* it lands. One planner run at one
seed writes the shards, the woven fragments and the site table (CIS §8), so every per-build value below reaches a
woven site from the same IR as the shard encoder, and the CIS §4.3 differential (woven bytes equal shard bytes)
runs at fixed nonzero seeds with every method on.

### Method by method

| Method | At a woven site | Rides site-bound ids | Cost change from weaving |
|---|---|---|---|
| M1 field order | the site encoder writes the rotated order; a site layout is its definition's rotated layout minus the constant fields | yes: the site's remaining fields in rotated order | none (same opcodes, `opcodes.out`) |
| M2 tag constants | untouched: the tag is computed by the runtime at flush; woven code only writes rows (CIS §8) | n/a: site ids are frame bits under `tag.cover` | none |
| M3 offsets | variable fields carry the offset as at the shard; at a literal site it folds into the constant word at build time | yes for remaining fields; a constant field elided by `weave.ids = "site"` has no code on the wire, so no offset | +5.0 ns encode per bounded variable field interpreted, as for shards; 0 at literal sites |
| M6 session pool | re-adds the dispatch weaving removes (below) | possible, not useful | +about 20 ns per fire, K× woven bytecode |
| M7 player variants | upstream scope does not compose: woven scripts in starter containers are copied to every player (CIS §8); tag-only scope composes | site ids are the same for every player | tag-only: none |
| M8 derived key and seed | handshake only; site ids permute under the derived seed like any id | yes | none |
| M13 per-player tag binding | tag-level, like M2 and tag-only M7 | n/a | none from weaving |
| M15a generated traps | a trap has no sites, so it is closed by construction and has only its generic id; `weave.dropClosed` must keep trap encoders, since traps exist to be in the shard | no: a site id would need a site | none |
| M15b, M15c decoys, canaries | downstream; nothing woven | n/a | none; the canary scan reads decoded string and buffer fields of site-id messages, and elided constant fields are build literals that cannot carry an echo |

**What each method gains from site ids.** With `weave.ids = "site"`, the wire id names the site, and the closed-
generic fact (CIS §7.1) already reports an **api** driver on every closed definition. Two consequences:
- **M15a adds least to woven builds.** In a complete woven namespace every closed real definition's generic id
  is already a reporting path, so generated traps add bait only where definitions stay open (unwoven sites). The
  `build.traps` default of 0 fits; a woven project with many open definitions may set it.
- **M1 and M3 now vary per site layout, not only per definition.** A tool encoding outside `fire` must re-derive
  site layouts per build (CIS §7.2: "reading the woven bytecode of the game's own scripts", class **code**), the
  same pass in which it reads M1's order and M3's offsets. So the methods add no separate work on top of site ids;
  they stay zero-cost and keep their own value for unwoven definitions.

### M6 under weaving: the pick brings the dispatch back

Weaving's gain over a check-then-write shard is the payload table and the method dispatch, 50–170 ns per variable
site, and checks folded at literal sites, 85–165 ns (CIS §6.3). A per-session pick at a woven site needs either an
indexed call or K inlined copies under a branch:

```luau
-- woven, K = 1 (built)                           -- woven with a session pool (not recommended)
__lync_begin(3); __lync_wb(b, bit, 40, x)         local e = __lync_ENC_STRIKE[__lync.pick]; e(b, bit, x, d)
```

- CPU: the indexed form costs the dispatch M6 measured, about +20 ns per fire interpreted where the fixed encoder
  would have been inlined (`dispatch.out`: 56.7 against 76.5–78.4 ns), and the encoder can no longer be inlined
  into the site, which is weaving's W2 form.
- Bytecode: K inlined copies multiply the about 650 B per inline site (CIS §6.1) by K; the indexed form needs K
  encoders per definition in the shard (224–356 B each, `bytecode2.out`) and loses inlining.
- Protection: none recurring (M6). So woven builds keep K = 1. If both are wanted, only W3 sites (scalar call into
  the shard) avoid K× script bytecode: the pick lives in the shard's scalar entry and every woven script stays one
  copy.

### What `weaveHash` in `HELLO` must cover

`HELLO` already compares the build id (M1's public `buildId`) and the seed-0 schema hash. `weaveHash` (u32, CIS
§7.3) must cover what both shards must agree on that those two do not pin. Two runs at one fixed `build.seed` can
differ in it (CIS §7.3), so it cannot be left to the seed.

| Covered | Why |
|---|---|
| id mode (`generic`, `definition`, `site`) | it sets the up-space size |
| the site table in canonical order: (script instance path, line) → definition canonical id | it sets which ids exist and what each delivers as |
| per site, the constant fields and their values | the server fills them; a disagreement is a silent wrong value |
| the generated trap set (M15a): count, canonical positions, source codec of each | it sets the up-space size and the server's trap flags; T can differ between runs at one fixed seed |

| Not covered | Why |
|---|---|
| M1 order, M2 constants, M3 offsets | pure functions of (schema, `rotationSeed`), so the build id pins them |
| M7 and M13 variant data | they differ per player by design; the server verifies under the assigned variant |
| `rotationSeed`, M8's S, M15c's key | secrets: a public hash over a secret gives an offline check value for guesses |
| per-server permutation seed | per server; sent in `WELCOME` |

Form: HalfSipHash-2-4, zero key, low 32 bits, over a canonical serialization of the covered items, as the schema
hash is formed (`v5.md` §4.6). It is 0 when there are no site ids and no generated traps, so G7 and every unwoven
`HELLO` stay as they are; because traps are covered, an unwoven build with `build.traps` > 0 also sends a nonzero
value, and the name could become `layoutHash` (the lead's choice). A mismatch is `MISMATCH`, `schemaMismatch`
evidence `weaveDiffers` 1 (CIS §7.3). Cost: 4 B per namespace per connection, already counted in CIS §7.3.

### What Studio-only projects keep (no weaving)

The plugin's "Prepare release" writes shards (`v5-integrity.md` §2), so everything that lives in shards is
available; everything that lives in game scripts is not (CIS §2: a plugin cannot weave without rewriting the open
place).
- **Kept:** M1, M2, M3, M8 (shard values); M7 in tag-only scope and M10 (the plugin writes the variant modules to
  `ServerStorage`); M15a (traps need only the shards and the reachability scan, which the design specifies as a text
  scan the plugin can run over script sources); M15b and M15c (run time).
- **Caveat on the private seed.** M1's `rotationSeed` must come from OS entropy. A plugin has `Random.new()` and
  `HttpService:GenerateGUID()` (security None, API dump 0.741.19, verified); the entropy source of either is
  undocumented (unverified). Until it is checked, Studio-only builds should be described as having a public-quality
  seed, with §0.1's consequences.
- **Lost:** site-bound ids and the closed-generic fact, literal elision (1 to 8 bits per message at the CIS shapes,
  the whole payload at fully literal sites), woven speed (1.3–3.5x per client call, CIS §6.3), handler unpacking.
  `weaveHash` is 0 unless `build.traps` > 0.
- **Consequence.** In Studio-only projects the build-time bait for **api** drivers is reachability plus M15a;
  M15a is worth more there than in woven builds.

### Implications for M15 and M16

These add to the list above without editing it.
1. Offer `build.traps` (0–8, default 0) only for complete namespaces, with `unreachable` `declared` 2; record R13 as
   reopened in that form (M15a).
2. Fix the iteration gap of `v5-integrity.md` §3 before any generated trap ships; without it, unmodified code
   iterating the namespace fires traps (M15a, CIS §4.2).
3. Generate no decoy placement; add `decoyFrom` (clone-and-update values), keeping `decoyOutsideInterest` on the
   decoy's own cell (M15b).
4. Offer `canary.perViewer` (default false) and widen `canaryEchoed` with `sentToUserId` and `sameViewer`; it is the
   one method here that prices **share** by naming a source session (M15c).
5. Emit every method at woven sites from the same IR as the shard, and run the CIS differential at nonzero seeds
   with M1, M3 and M15a on (M16).
6. Do not combine M6 with weaving; if combined, only through W3 sites (M16).
7. Restrict M7 to tag-only scope in woven builds (M16, CIS §8).
8. Make `weaveHash` cover id mode, the site table, constant fields and generated traps, and never a secret or
   per-player data (M16).
9. Check the Studio plugin's entropy source before claiming a private seed for Studio-only builds (M16).
