# Generation methods: what Lync's own build can vary, and what each costs

Researcher brief, 2026-10-15. **What it feeds:** the design pass on client hardening through generation. The author
asked for concrete methods in Lync's own pipeline, not platform facts (those are in `generation-security.md`, cited
`[GS §n]`). Each method below says:
- what `lync build`, the Studio plugin or CI emits differently, and at which grain;
- the generated Luau shape;
- what changes on the wire or in the API, and what stays fixed;
- which attacker route it prices, in `v5-integrity.md` §1's terms;
- its cost, and the refused items it reopens (R-numbers from `security-refusals.md`).

**Grounding.** Read in full: `design/v5.md`, `v5-integrity.md`, `v5-tooling.md`, `v5-collections.md`,
`research/security-refusals.md`, `client-security.md`, `client-security-build.md` (cited `[CSB §n]`) and my
`generation-security.md`. From `research/security-tooling.md` I used only the server-side and Open Cloud sections
(ConfigService, Place Publishing, `restartServers`). From `compression.md` I used only its column-coder findings;
v5.md §4.3 restates that coder exactly. `research/codecs-in-scripts.md` did not exist when I wrote this. I leave
call-site codecs to its author (§3 notes the interfaces only).

**Labels.** **verified** (I ran it or read the source), **documented**, **reported**, **unverified**. Cost
provenance: **measured** (probe), **derived** (arithmetic shown), **asserted**.

**Probes** (`.data/docs/probes/generation-methods/`, reproduced by `run.sh BUILD_DIR WORK_DIR`): Luau 0.742 built
from `.data/projects/luau`; Intel Xeon 2.1 GHz, Linux; CLI figures show scale only.
- `shapes.luau` / `shapes.out`: one generated record codec at seed 0, at a rotated seed, with per-build code
  offsets, and with per-session variant selection. Interpreted and native.
- `enum_rotation.luau` / `enum_rotation.out`: v5 column-block bits for permuted and offset enum codes.
- `gen_defs.py` / `bytecode.out`: bytecode per generated upstream encoder.

---

## 0. What exists, and the rules every method keeps

**Already rotated** [`v5-integrity.md` §2]. A nonzero build seed rotates two things:
- record field order (Fisher–Yates over xorshift32, seeded per record path);
- the upstream tag's two HalfSipHash initialisation constants.

Measured cost is zero: the same opcode sequences [CSB §2.3]. Instruction counts confirmed again here: 22 and 24 for
encoder and decoder at seeds 0 and 7 (`shapes.luau`, verified). Ids are permuted per server from the server seed,
the schema hash and the space number. They are not permuted from the build seed (R12).

**Invariants.** Every method below keeps these, so the protocol, golden frames and types hold.

| # | Invariant | Why it holds |
|---|---|---|
| I1 | **Seed 0 is the identity for every method.** Each derived parameter is the identity when the build seed is 0 (offset 0, identity permutation, the key in clear, fixed names, no decoys) | The golden set (`v5.md` §4.10), the runtime path (always seed 0) and the differential test stay valid unchanged |
| I2 | **Every per-build parameter is a pure function of (build seed, seed-0 schema hash, core version)** | `HELLO` already carries the seed and the hash. A client and server from different runs already get `MISMATCH` (`schemaMismatch`, `seedDiffers` 1). No new field, no hash change |
| I3 | **Types are unchanged** | Field order, offsets, ids and names are wire facts. Generated shard types and `.d.ts` stay the same. The exception is M8, which adds API members on purpose |
| I4 | **Downstream layout is the same for every player of a server** | Encode-once chunks and `FireAllClients` (`v5.md` §4.2) need identical bytes for all recipients. Per-player and per-session methods vary *upstream* code only |
| I5 | **The canonical decode rules (`v5.md` §4.8) are unchanged** | A method changes which code means which value, never which codes are accepted |

---

## 1. Methods

### M1. Ids that mix in the build seed (reopens R12)

**Grain:** per build, combined with the existing per-server seed.

**Emitted.** Today's derivation is xorshift32 seeded by `serverSeed ⊕ hashLow ⊕ space` (`v5.md` §4.5). The build
folds a per-build word `m = low32(HalfSipHash-2-4_0(seed ‖ "ids"))` into the server shard and the client shard as a
constant. `m = 0` when the seed is 0.

```luau
-- before (shard, seed 0 or runtime path)
local s = bit32.bxor(serverSeed, 0x158b86ab, 1)        -- hash low, up space
-- after (seed 7): m folded as a literal; same instructions, one more K constant
local s = bit32.bxor(serverSeed, 0x158b86ab, 1, 0x5c21e0f3)
```

- **Changes:** which permutation a given server seed produces.
- **Fixed:** id widths, the Fisher–Yates rule, the PERM golden vector (seed 0), `WELCOME`.
- **Prices:** static forgers that rebuild a server's permutation from its seed with the published derivation. Each
  build changes the derivation, so such a tool needs this build's constant (`v5-integrity.md` §1, "static forger").
- **Does not price:** anyone holding the client shard, which contains `m`. Alone, it adds little, because the
  server seed arrives in clear in `WELCOME`. With M2 the seed itself is no longer sent.
- **Cost:** zero per message. One `bxor` operand per namespace, once per connection, inside the permutation build
  that already costs 18.3 µs interpreted / 4.3 µs native per 200 ids (measured, `security-refusals` §1). No bytes.
- **Options:** none. The build seed is the switch (`