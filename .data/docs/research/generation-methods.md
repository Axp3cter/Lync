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
- [ ] M2. Per-build tag constants (in the design)
- [ ] M3. Per-build code offsets
- [ ] M4. Id permutation mixed with a per-build value
- [ ] M5. Per-build column-mode choice
- [ ] M6. Per-session variant from a build-time pool
- [ ] M7. Per-player variant delivered through `PlayerGui`
- [ ] M8. Session key and permutation seed derived, not sent in clear
- [ ] M9. Codecs at call sites (composition only)
- [ ] M10. Build-time values in the server shard
- [ ] M11. Per-server values through `ConfigService`
- [ ] M12. Join rule for per-player variants
- [ ] Summary table and Implications
- next unit: per-player tag constants or key derivation bound to the player's variant, so the server can state
  which variant a frame verifies under
- next unit: per-build generated traps, decoys and canaries
- next unit: the no-build (runtime) path with per-session parameters through tables, measured
- next unit: composition with `research/codecs-in-scripts.md` (it now exists; M9 gives only what this run checked)

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
