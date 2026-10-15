# Client self-checks: three measures the docs never decided (U1, U2, U7)

Researcher findings, 2026-10-15. Re-judges items U1, U2 and U7 of `research/security-refusals.md` §4 for the
design pass. Each item states how it works in Lync, what it prices (capability classes of
`research/client-security.md` §1.2, named as in `research/security-tooling.md` §9), what it doesn't, its measured
cost, how it fails on an unmodified client, and its options where it adds any. No verdicts on players; every fact
proposed here has an exact trigger and evidence, and Lync takes no action beyond dropping malformed input.

**Labels.** **verified**: I ran it or read the source. **documented**: official docs. **reported**: third party.
**unverified**: my inference or not yet measured.

**Runs.** Luau source in `.data/projects/luau` (stated by the lead as 0.742; the tree carries no version string),
built with CMake as `luau` and `luau-compile`, run interpreted (`-O2`, and `-O1` where noted) because clients run no
native code; `--codegen` only for server-side figures. Intel Xeon 2.1 GHz, 4 cores, shared machine; best of 7
batches minus an empty loop. Roblox devices are slower by an unmeasured factor. Type checks used the luau skill
(luau-lsp 1.70.1, Roblox definitions). Probes and outputs: `.data/docs/probes/client-self-checks/`. Engine facts on
the client side: `research/security-tooling.md` §2.

**The milestone build** (`f1fbfd7`, in git history) is the reference for "what Lync does today":
`f1fbfd7:src/host/roblox.luau`, `src/transport/tag.luau`, `src/wire/halfsiphash.luau`.

## Checklist

- [x] U1: capture `FireServer` once and call the captured function
- [x] U2: per-build variation of the tag function beyond its two constants
- [x] U7: `debug.info` caller information folded into the tag
- [x] Implications

---

## U1. Capture `FireServer` once, call the captured function

**Today.** The milestone build calls the method by name on every send:
`(remotes.reliable :: RemoteEvent):FireServer(frame, instances)` (`f1fbfd7:src/host/roblox.luau` line 165, and
167 for the unreliable remote). That compiles to `NAMECALL … ['FireServer']` + `CALL`, which goes through the
remote's `__namecall` metamethod. So the docs' open question ("whether the runtime already does this",
`security-refusals.md` U1) has the answer **no** (verified, source).

**Mechanism.** When the client transport finds each remote, it reads the method once and keeps it:
`fireReliable = reliable.FireServer` and `fireUnreliable = unreliable.FireServer`. Every send then calls
`fireReliable(reliable, frame, instances)`. This compiles to one `GETTABLEKS … ['FireServer']` per remote at
capture and a plain `CALL` per send, with no `NAMECALL` (`probes/client-self-checks/capture.luau`,
`capture.out`). It type-checks clean under the new solver with Roblox definitions (verified, `capture.out`). The
capture happens when the remote is found, not when the shard loads, since the client waits for
`ReplicatedStorage.Lync` (v5.md §4.1). It is one implementation line in the transport, with no API, wire or
option change.

**What it prices.**
- *Hooking functions and metamethods*, in its `__namecall` form only. A spy that hooks the remote's
  `__namecall` and filters on `getnamecallmethod()` sees calls made with `:FireServer(...)`, and never sees a
  plain call of a captured function. This is SimpleSpy v3's default mode and one of Hydroxide's two hooks
  (verified by reading their sources, `client-security.md` §1.3). Such a spy then shows no Lync traffic, where
  today it shows opaque buffers.

**What it does not price.**
- *Hooking functions*, in place: `hookfunction(remote.FireServer, …)` "replaces func with hook globally", so the
  captured reference is the hooked function (`rawequal` stays true). SimpleSpy's optional mode and Hydroxide's
  second hook use this (documented and verified by reading, `client-security.md` §1.2–§1.3).
- *Hooking metamethods before Lync loads*: executors can run before game scripts (`client-security.md` §1.1). A
  hooked `__index` in place at capture time hands Lync whatever it returns.
- *Packet-level send and receive hooks* (Cobalt on executors with `raknet`) and *reading the client's own code*:
  untouched.
- API drivers and extractors: untouched; they go through Lync, not around it.

**An engine fact that bears on it (unverified on Roblox).** The Luau source has a direct userdata method path: at
load, every `NAMECALL` whose method name has an atom is rewritten to `NAMECALLUDATA` (`VM/src/lvmload.cpp` lines
684–702). When the host has registered a direct namecall handler for that userdata tag
(`lua_registeruserdatadirectaccess`, `VM/src/lapi.cpp` line 2093), the VM calls that C handler directly with a
copy of `__namecall` taken at registration, without calling the metatable's current `__namecall` closure
(`VM/src/lvmexecute.cpp`, `LOP_NAMECALLUDATA`, from line 3560); without a handler it falls back to `NAMECALL`.
Whether Roblox registers this for `Instance`, and what it does to `__namecall` spies, I could not establish. If it
does, U1's difference from today may shrink. Game code can't install a `__namecall` hook on an `Instance`, so this
can't be observed from a game script; it stays unverified.

**Cost** (verified, `cost.out`, CLI stand-in: a userdata whose `__namecall` is a C function).

| Form | `-O2` | `-O1` |
|---|---|---|
| `proxy:FireServer(frame)` (`NAMECALL`, today) | 45.1 ns | 43.0 ns |
| `proxy.FireServer(proxy, frame)` (index on every call) | 69.1 ns | 66.5 ns |
| `captured(proxy, frame)` (U1) | 44.0 ns | 34.6 ns |

The captured call costs the same or up to 8 ns less in the VM's dispatch. The engine's own work inside
`FireServer` is unmeasured (v5.md §10) and identical either way. Zero bytes, no options, no maintenance beyond the
line. Developer cost: none.

**Failure on an unmodified client.** U1 is not a check, so it produces no fact and no false fact. Its failure
modes are functional:
- capturing before the remote exists (the capture must follow the remote watch);
- a remote replaced after capture: whether the engine returns one function per class or per instance is
  unverified, so the transport captures again whenever it finds a new remote and passes that remote as `self`.

Neither changes any wire byte.

---

## U2. Per-build variation of the tag function beyond its two constants

**Today.** A nonzero build seed replaces the tag's two HalfSipHash initialisation constants (`0x6c796765`,
`0x74656462`) with two xorshift32 outputs (`v5-integrity.md` §2). The round counts are fixed at 1-3 and the six
rotation amounts at the reference `5, 16, 8, 7, 13, 16` (`f1fbfd7:src/wire/halfsiphash.luau`, `sipRound`). The
earlier research spoke of "four" rotated constants (`client-security-build.md` §2.3); the design rotates two.

**Mechanism.** The build seed, through the same xorshift32 stream, also draws:
- **the six rotation amounts**, as one entry of a fixed pool of rotation sets shipped in Lync's source, each
  vetted once by a diffusion test (below) and given golden vectors. Seed 0 keeps the reference set;
- **the finalization rounds** d from {3, 4};
- **the compression rounds** c from a range the developer sets (option below; default 1, so no change).

The generated client and server shards both emit the chosen variant as straight-line code. The runtime path stays
at seed 0. No wire change: both shards come from one build run, which `HELLO`'s seed already enforces
(`schemaMismatch`, `seedDiffers`).

**Rotation amounts are build-time immediates at zero run-time cost** (verified, `bytecode.out`). Each
`bit32.lrotate(v, n)` with a literal `n` compiles to `FASTCALL2K 35 R5 K10 L5 [5]`; the altered set gives
`[6]` in the same slot. The 1-3 reference variant and an altered one have identical opcode sequences, 435
instructions each, with 63 fast calls. Timed, they are indistinguishable (table below).

**PRF quality under altered rotations.** HalfSipHash's round function is Chaskey's permutation; its author
wrote that HalfSipHash "takes its core function from Chaskey and uses the same construction as SipHash, so it
should be secure", but "it hasn't received the same amount of attention as 64-bit SipHash did"
([J.-P. Aumasson, LKML, 2016-12-19](https://lkml.iu.edu/hypermail/linux/kernel/1612.2/01666.html), documented).
I found no analysis of HalfSipHash with other rotation amounts (searched the web for HalfSipHash rotation-constant
analysis; results cover SipHash-2-4 differentials, [eprint 2014/722](https://eprint.iacr.org/2014/722), and kernel
threads). So any altered set has **no published analysis**, and the measure trades the reference's analysed
constants for variation. What I measured (verified; a necessary condition, not a proof):
- **Whole-tag avalanche** (`avalanche.py`, `avalanche.out`: 16-byte messages, 300 samples, noise floor about
  0.115): the reference, an altered set and 30 random sets of amounts in 1–31 all sit at worst bias 0.087–0.130
  under 1-3 and 2-4. Degenerate sets show: all-zero rotations 0.500, all-16 rotations 0.327 under 1-3. The test
  separates only degenerate sets.
- **Round-level diffusion** (`diffusion.py`, `diffusion.out`: the bare permutation, 400 samples): the reference
  set makes every input bit reach every output bit after 3 rounds. Of 40 random sets, 24 do so after 3 rounds
  and 16 need 4; sets of multiples of 8 and all-16 need 4; all-1 does not reach full dependency within 4.

So rotation sets must come from a vetted pool, never straight from the seed: every pool entry must reach full
dependency in as few rounds as the reference, and pass the whole-tag test. A pool of 16–64 sets gives
4–6 bits of per-build variation in rotations.

Who the tag's PRF quality protects: a sender who does not hold the key. The only party that sees tags is the
client, which holds the key; a weakness matters only to a tool that observes frames and tags (a *packet-level
hook*) but does not read Lync's memory, and recovers the key from outputs. With the reference constants that
search is 2^64 per session; with a vetted altered set it is unanalysed.

**Cost** (verified, `tagvariants.out`; input = 11-byte prefix + 64 B or + 1024 B of frame; client interpreted
`-O2`, server `--codegen`; two interpreted runs give the ranges).

| Variant | client, 64 B | client, 1024 B | server native, 64 B | server native, 1024 B | bytecode, unrolled (`-g0`) |
|---|---|---|---|---|---|
| 1-3, reference rotations (today) | 2.33–2.37 µs | 27.1–27.8 µs | 0.29 µs | 3.64 µs | 2,234 B |
| 1-3, altered rotations | 2.33–2.36 µs | 26.3–28.0 µs | 0.28 µs | 3.73 µs | 2,234 B |
| 1-4 | 2.33–2.49 µs | 26.7–26.8 µs | 0.30 µs | 3.67 µs | 2,538 B |
| 2-3 | 3.62–4.21 µs | 45.3–47.7 µs | 0.52 µs | 6.25 µs | 2,842 B |
| 2-4 | 3.83–3.93 µs | 48.2–48.5 µs | 0.48 µs | 6.59 µs | 3,146 B |
| 2-4, altered rotations | 3.90–3.91 µs | 47.8–50.4 µs | 0.50 µs | 6.80 µs | 3,146 B |
| 3-4 | 5.03–5.24 µs | 66.5–67.6 µs | 0.70 µs | 9.64 µs | 3,754 B |
| 4-4 | 6.86–7.43 µs | 83.9–90.7 µs | 0.86 µs | 12.10 µs | 4,362 B |

- Rotation amounts and d cost nothing measurable in time (d = 4 adds about 304 B unrolled). Each extra compression round adds about 19 ns per covered byte
  interpreted (26 ns at c = 1, 45 at 2, 64 at 3, 82 at 4) and about 2.7 ns native.
- The busy model (70 upstream frames/s, v5.md §4.1) at about 64 B per frame: c = 2 costs a client 0.09–0.13 ms/s
  more than c = 1, interpreted, and the server 13–16 µs/s more per player, native. A tag failure costs
  up to 5 PRFs at the variant's price.
- Unrolled, each written-out SipRound adds about 304 B of bytecode: an extra compression round writes two (word
  loop and tail), an extra finalization round one. A loop with a literal bound keeps the size of 1-3; the
  milestone code used loops.
- Wire: zero bytes. Developer: none beyond the option; offline decoding already needs the seed.
- Verification: the generated 2-4 variant reproduces the published HalfSipHash-2-4 32-bit vector
  (`a9 35 9f 5b` for key `00…07` and the empty message, `tagvariants.out`); each pool entry needs its own golden
  vectors, and the build can run the emitted client and server tag functions on them before writing shards.

**What it prices.** Tag reimplementations that hard-code HalfSipHash's structure and rounds, built against one
release (an external tool, or a script carrying its own HalfSipHash): they must re-derive, per release, the
rotation amounts and round counts as well as the two constants.

**What it does not price.**
- *Reading the client's own code*: the amounts are K operands and the round counts are visible in the function's
  shape, all in the same function a rotation-aware tool already reads for the two constants each release. The
  read is the same read, in the same pass; it adds a one-time change to the tool, not recurring work.
- *Reading upvalues, stack and GC objects*: a tool that finds Lync's own tag closure and calls it with the key it
  read reimplements nothing, so variation costs it nothing.
- API drivers, hookers above the encoder, packet-level tools that let Lync compute the tag: untouched.
- Keyless guessing: the bound is set by the tag width (one acceptance per about 38 days at the full budget,
  v5.md §4.5), unchanged.

**Failure on an unmodified client.** None from the network. The causes are Lync's own:
- a variant emitted wrongly on one side gives `tagMismatch` on every frame, then `desync` and `REKEY`, all with
  the existing triggers (v5.md §7.3, "a Lync bug"); the build-time golden check above removes that cause before
  release;
- client and server shards from different runs are already `schemaMismatch` with `seedDiffers` 1.

**Options.** Rotation amounts and d ride on `build.seed` with no option, since they cost nothing; this keeps the
seed as the one switch (`v5-integrity.md` §2, `[review-redundancy-2 7]`). Compression rounds have a cost, so per
v5.md principle 2 an option sets their range:

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `build.tagRounds` | array of two integers `[min, max]` | compression rounds per 4-byte word | 1 ≤ min ≤ max ≤ 4 | `[1, 1]` | each round above 1: about 19 ns per covered byte on the client (interpreted), 2.7 ns native on the server, on every upstream frame and on each of up to 5 retries of a failing one; about 600 B of shard per round if unrolled |

With min < max each build draws c uniformly in the range, so the frame cost varies between builds within it. The
manifest records the drawn c, d and pool index beside the seed.

---

## U7. Caller information from `debug.info` folded into the tag

**Origin.** The attempt listed "`debug.info` caller attestation folded into the tag" and "closure hygiene" without
specifying either (`v5-attempt.md` lines 248–250).

**Today.** The caller probe's source check (`v5-integrity.md` §4) walks `debug.info` to the first frame outside
Lync and looks its source up in the build's list of client scripts that reference the definition. The result
travels as a count, `sourceUnlisted`, in `REPORT`, and the server reports `reportedSourceUnlisted` with evidence
`reported` and `probes`, both client-stated, and no definition.

### Three ways to fold it in

**(a) A caller-keyed tag, verified against a server-only list.** The client mixes a hash of each caller's source
into the tag; the server, holding the lists, checks it. The server doesn't know which listed script sent each
message, and a frame batches messages from many callers, so it must try every combination: the product of the
list sizes over the frame's messages (3 messages whose definitions list 4 scripts each: 64 PRFs per frame),
before decode, since the tag is checked first (v5.md §6.1). The cost is unbounded in the frame's contents. If the
lists ship to the client so that it can pick, it reduces to (b). Described for completeness; its cost has no
bound.

**(b) One bit per frame, `u`, in the tag input.** The client sets `u = 1` for a frame when any probed call whose
message is in that frame failed the source check. `u` is carried in the high bit of the lane byte that the tag
input already holds (v5.md §4.5: "lane u8 (0 reliable, 1 unreliable)"), so the hashed length doesn't change and
no byte is sent. The server verifies each count first with `u = 0`, then `u = 1`, then moves to the next count of
the lookahead. A match with `u = 1` delivers the frame as usual and records one fact for it.

**(c) (b), with the frame split.** As (b), but the client puts the messages of unlisted calls in a frame of their
own within the flush, so that the bit covers exactly those messages and the fact can name their definitions.

### What (b) and (c) change against `REPORT`

| | `REPORT` count (today) | (b) bit in the tag | (c) bit with split |
|---|---|---|---|
| Who states it | the client | the client | the client |
| Evidence | counts since the previous `REPORT` | per frame: `lane`, the frame's message count, its definition when the frame holds one | per frame, with the definitions of exactly the unlisted calls |
| Bytes | `REPORT` only when non-zero (one control chunk) | none | none, plus one extra reliable call per flush holding an unlisted call |
| Editable below the encoder | no while `REPORT` lies inside `tag.cover` (default 16,384, the whole frame); yes for the part of a frame past a smaller cover | no at any `tag.cover`, including 0 | as (b) |
| Removed by a patched Lync | yes, by zeroing the count | yes, by setting `u = 0` | as (b) |

So the bit adds per-frame evidence and a definition name, and holds at any cover. It adds no resistance to a
patched Lync: the bit and the count are both what Lync's code chooses to state.

**What it prices.** The same as the source check: API drivers that call Lync from a chunk whose source is not on
the definition's list, without renaming it (`v5-integrity.md` §4).

**What it does not price.**
- *Naming or hiding code and stack frames*: a chunk loaded under a listed script's name, or a frame hidden from
  the walk, reads as listed.
- *Reading and writing upvalues, stack and GC objects*, and *hooking*: Lync's probe result or the bit can be
  forced to 0 before the tag is computed.
- *Requiring client modules and calling Lync's own API* through a listed game function: the first frame outside
  Lync is that function's script, which is listed.
- Packet-level tools: they can't change the bit without the key, but they never set it either.

**"Closure hygiene"** (keeping the key and count out of reach of memory readers): no Luau storage is outside
*reading and writing upvalues, stack and GC objects* (`getgc`, `getupvalues`, `getstack`, `getreg`), so where Lync
keeps them changes which call finds them, not whether one does.

**Cost** (client interpreted, `cost.out`; server native, `tagvariants.out`).
- Client: the probe's walk and lookup, 189–196 ns per probed call through one Lync frame (566–589 ns for the walk
  alone through five), already paid by the source check at `callerProbe.oneIn` = 1; setting the bit is one
  assignment. The tag input keeps its length.
- Server: a frame with `u = 1` costs 2 PRFs instead of 1 (about 0.29 µs more native at 64 B, 3.6 µs at 1 KB). A
  failing frame costs up to 10 PRFs instead of 5 on the reliable lane and 6 instead of 3 on the unreliable.
- Keyless guessing: each candidate frame now matches under two `u` values, so at the full frame budgets
  (1320 candidates/s, v5.md §4.5) acceptance doubles, from one per about 38 days to one per about 19.
- (c) only: one extra `FireServer` per flush that holds an unlisted call (engine per-call cost unmeasured,
  v5.md §10); the frame header and toc again (a few bytes).
- Developer: none beyond the source check's clone mapping.

**Failure on an unmodified client (false facts).** Each yields a frame with `u = 1`, delivered as usual. From the
probes (`info.out`) and the docs:
- `fire` started with no frame of game code on its thread: passed straight to `coroutine.wrap` (verified: the
  walk runs off the stack), and by the same mechanism `task.spawn(view.fire, view, v)` or a signal connected
  directly to `view.fire` (unverified on Roblox).
- `fire` called through a C function (`pcall`, verified: `[C]` is the first frame). Lync can skip `[C]` frames
  and walk on, which removes this cause and also skips `newcclosure` frames.
- `fire` reached through a function value that a library calls, with no game frame between (a `fire` bound to
  its view and handed to a promise library): the first frame outside Lync is the library's module, which the scan
  didn't list because its text doesn't name the definition.
- A script outside the clone mapping (the existing cause, `v5-integrity.md` §10), and a character model that game
  code renamed, since the mapping of character scripts uses `Players.LocalPlayer.Name`
  (`security-tooling.md` §2).
- Whether a script renamed or moved after it loaded keeps its load-time source string: unverified.
- The Studio command bar (Studio only; its source string is unverified).

The first and third causes can be removed only by game code calling `fire` from its own function. An option that
leaves the no-outside-frame case unset would also leave the scheduler route unobserved; that choice belongs to the
option below.

**Options.** (b) replaces the `sourceUnlisted` field of `REPORT` rather than adding a second way to state the same
count (v5.md principle 4); `callerProbe.oneIn` and `callerProbe.maxPerSecond` keep governing which calls are
probed. It needs no new option. (c) and the no-outside-frame rule add:

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `callerProbe.splitFrames` | boolean | — | — | false | one extra reliable call per flush that holds a call with an unlisted source; a few bytes of header and toc; the fact then names exactly those definitions |
| `callerProbe.noOuterFrame` | enum | — | `"unlisted"`, `"ignored"` | `"unlisted"` | none; `"ignored"` removes the scheduler cause and leaves calls with no outside frame unobserved |

Both are client behaviour, so the server sends them in `WELCOME` (2 bits beside `callerProbe.oneIn`). The fact
keeps the code `reportedSourceUnlisted` with a new trigger: "a frame whose tag matches with `u = 1`"; action
none (the frame is delivered); evidence `lane`, `messages` (the frame's message count), and the definition when
the frame holds messages of one definition only; marked client-stated. The identity half of the probe could fold
in the same way, as a second bit, at the same server cost per set bit.

---

## Implications

1. **Adopt U1 as an implementation detail:** capture `FireServer` per remote found; zero bytes, no option, VM
   dispatch equal or up to 8 ns cheaper. It prices only `__namecall` spies, and the direct-namecall path in Luau
   may already change that (U1, "An engine fact").
2. **Do not count U1 as an integrity measure** in v5.md §6.2's table: it reports nothing and in-place hooks see
   through it (U1, "What it does not price").
3. **Draw the rotation amounts and d from the seed, through a vetted pool only,** never straight from the seed:
   zero run-time cost, but 16 of 40 random sets diffuse a round later than the reference (U2, diffusion).
4. **Ship the pool with golden vectors, and make the build check its emitted client and server tag functions on
   them** before writing shards (U2, "Failure").
5. **Offer `build.tagRounds` with default `[1, 1]`**: about 19 ns per covered byte per extra round on clients, and
   it prices only reimplementations that a rotation-aware tool already re-reads each release (U2, cost and
   "What it does not price").
6. **Record that altered rotations have no published analysis** next to the measure, since the trade is
   analysed constants for per-build variation (U2, PRF quality).
7. **If caller information goes into the tag, use (b), the per-frame bit in the lane byte, and remove
   `sourceUnlisted` from `REPORT`**: zero bytes, holds at any `tag.cover`, adds per-frame and per-definition
   evidence, and stays client-stated (U7, comparison table).
8. **Refuse (a), the caller-keyed tag:** its server cost grows with the product of list sizes per frame and
   has no bound (U7, (a)).
9. **State the doubled keyless acceptance** (one per about 19 days at full budgets) wherever (b) is adopted, beside
   the tag-width decision in v5.md §4.5 (U7, cost).
10. **Skip `[C]` frames in every source walk, and walk by source, never by level**: removes the `pcall` cause and
    keeps Studio (`-O1`) and live (`-O2`) results equal (U7, false facts; `security-tooling.md` §2).
11. **List the scheduler, library-callback and renamed-character causes** on the `reportedSourceUnlisted`
    registry page, with `callerProbe.noOuterFrame` as the developer's choice (U7, false facts and options).
12. **Never use `getfenv` to reach a caller's instance:** the 3.5–4× slowdown lands on the game's script, not on
    Lync (`security-tooling.md` §2, `deopt.out`).
