# Refusals re-judged, part 1: R10, R11, R31, R33, R34

Researcher findings, 2026-10-15. **Decision it feeds:** whether each of five refused items (numbers from
`research/security-refusals.md` §2) stays refused, or enters the v5 design and in what form. The author's
direction: earlier refusals leaned on run-time limits and costs that were not worked through, and assumed that work
had to happen at run time or identically for every player. Generation (`research/generation-methods.md` §0, Summary)
is now available. Each item gives the earlier reason and its assumption, what it would protect (capability classes
of `client-security.md` §1.2, as grouped in `generation-methods.md`: **code**, **mem**, **api**, **hook**,
**signal**, **packet**, **identity**, **naming**, **clock**, **state**, **share**), a form in Lync's terms, its
measured cost, its facts, and a one-line outcome. Lync reports facts and drops only malformed input.

**Labels.** **verified**: I ran it or read the source. **documented**: official docs or the design say so.
**reported**: a third party says so. **unverified**: inference, or nothing found.

**Tools.** Luau 0.742 built from `.data/projects/luau` (Release, scratch build): `luau -O2` stands for clients
(interpreted), `luau -O2 --codegen` for servers (native; a Roblox server runs native code only for scripts marked
native, so interpreted figures also bound an unmarked server). Intel Xeon 2.1 GHz, 4 cores, shared machine; CLI
timings show scale only, devices are slower by an unmeasured factor. The milestone build's decoder (`f1fbfd7:src`)
is extracted to scratch by `run.sh` and never copied into the repo. API facts from the luau skill's dump 0.741.19.

**Probes** (`.data/docs/probes/refusals-rejudged/`, all by `sh run.sh BUILD_DIR WORK_DIR`, 3 runs per mode):
- `r10_base.luau`, `r10_names.sh` → `r10_names.out`: which renames change shipped bytecode, at `-g0`, `-g1`, `-g2`;
- `r31_decode.luau` → `r31_decode.out`: the milestone decoder's CPU and heap per element for the worst shapes the
  planner accepts, and for a dense record;
- `r33_intern.luau` → `r33_intern.out`: heap per intern entry; a reference against a literal at decode;
- `r34_seal.luau` → `r34_seal.out`: a HalfSipHash-2-4/64 counter-mode keystream, checked against the reference port
  in `probes/security-costs/hsip.luau`.

## Checklist

- [x] R10. darklua renaming as polymorphism
- [x] R11. Manifest self-attestation of client scripts
- [x] R31. A per-frame decode budget proportional to frame bytes
- [x] R33. Upstream (client-to-server) string interning
- [x] R34. Commit–reveal or cryptographic state sharing as a general feature
- [x] Implications

---

## R10. darklua renaming as polymorphism

**Earlier reason** (CSB §1.5, CSB:800, CH:110): "Not seedable; local names are not shipped" (decompile returns
`UNNAMED_<addr>`); "It changes nothing in shipped bytecode, so it prices nothing." Assumed: the only renaming
available is darklua's, and only local names are at stake.

**What is shipped** (verified, `r10_names.out`; compiler source `Compiler/include/Luau/Compiler.h:36-39`: "1 - line
info & function names only; sufficient for backtraces", "2 - full debug info with local & upvalue names").
- Renaming every local and parameter (darklua `rename_variables` at its default `include_functions = false`) leaves
  the bytecode byte-identical at `-g0` and `-g1` (653 B and 653 B at `-g1`); it differs only at `-g2`.
- Renaming `local function` names (`include_functions = true`) changes the bytecode at `-g1` (653 B → 645 B): the
  function's debug name is a string in the bytecode, and `debug.info(f, "n")` returns it (`encodeHit` → `h`).
  `function Codec.hit` ships the name `hit`; `local packShot = function` ships no name at `-g1` (`debug.info` "n"
  returns the empty value).
- Table keys (`Codec.hit`, a view's definition names) are constants at every level; no darklua rule renames them,
  and game code indexes them by name.
- Roblox ships function names: `debug.info` option "n" is "The name of the function; may be `nil` for anonymous
  functions and C functions without an assigned debug name" (documented, creator-docs
  `reference/engine/libraries/debug.yaml`, read 2026-10-15). With CS §2.1's `UNNAMED_<addr>` locals (reported) this
  matches debug level 1 *(inferred from the two)*.

So the earlier statement "changes nothing in shipped bytecode" is false for function names and true for locals.
"Not seedable" no longer matters: Lync's generator writes the final shard, so it can name each generated function
from M1's private `rotationSeed`, or leave it anonymous, with no darklua pass (CSB §1.5 verdict: "Lync needs no
darklua").

**What per-build function names would protect.** Only searches that locate Lync's functions by name: `filtergc(
"function", {Name = …})` and `debug.info(f, "n")` over `getgc` (class **mem**), and a decompiler's readability
(class **code**). It would not protect against any other route to the same function, and each of those is stable
across builds at the same work:
- **api**: `require` the client shard and index the view by definition name; the names are fixed by game code
  (`Net.chat:fire`), so no build can vary them.
- **mem**: `filtergc` by `Keys` of the view table (the same definition names), by `Constants` (codec bounds such as
  `1000` in `t.int(0, 1000)` are schema values, equal in every build), or by the shard's source from
  `debug.info(f, "s")` (the shard's instance path, which game code `require`s, so fixed per game).
- **code**: the shard's bytecode is read whole; names change labels, not structure.
- Lync's runtime package (not generated) has the same function names in every game using one Lync version; a
  generated shard cannot rename functions it does not emit.

**Cost.** Run time: zero (verified: at `-g1` the 75 instructions are identical once closure-name annotations are
removed; only the name strings differ). Bytecode:
the names' bytes (−8 B for two names in the sample). Developer: stack traces and `debug.info` "n" in error
reports show generated names; the dev-only debug map (CSB §5.6) would need a name column to map them back.

**Facts.** None: renaming produces no server-observable behaviour.

**Unverified.** Whether sUNC `getfunctionhash` (CS §1.2) covers the debug name; if it does, per-build names would
make hash-keyed searches per-build work for generated functions whose code is otherwise unchanged across builds. M1
field rotation already changes the code of every record codec with two or more fields.

**Outcome: kept refused.** Reason (not cost): every route a name search serves has an equally stable route through
names game code fixes (view keys, the shard's path, `require`), so per-build names leave a tool's per-build work
unchanged; generation removes the "not seedable" reason but not this one.

## R11. Manifest self-attestation of client scripts

**Earlier reason** (CSB §4.3, CSB:796-797, CH:111): `Source` is readable only with capability `PluginOrOpenCloud`
(verified), and "a client's self-report is attacker-controlled". Assumed: the attestation has to run on the client,
at run time.

**Run-time attestation, re-checked with generation.**
- What an unmodified client can read about its own code: `debug.info(f, "slna")` only. `Source` needs
  `PluginOrOpenCloud`; `Script:GetHash` is `LocalUserSecurity` (verified, dump 0.741.19); no engine API hashes a
  running script (`security-tooling.md` §1).
- What a content attestation would separate: a client running edited game scripts from one running the published
  ones. The capabilities in CS §1.2 run added code beside unmodified game scripts (`require`, `loadstring` chunks
  under any name, `hookfunction` "in place"); none of them needs to change a game script's bytecode. So a modified
  client's game scripts hash as the published ones do, and an attestation of them reports the same value for
  modified and unmodified clients.
- What a generated challenge would add: the server sends a per-session nonce, the shard answers with a function of
  the nonce and per-build constants. The answering function and its constants sit in the client's memory beside the
  tag key, so the answer proves what a valid tag already proves (the frame came from code holding this session's
  values: the shard, or an extractor, `v5-integrity.md` §1). It prices raw senders and static forgers, which the
  tag prices. Per player, M13's `tagVariant` already names the variant a frame came from.
- Script liveness (each listed client script registers when it starts) is expressible in game code with one
  ordinary client-sent definition, and its known causes on an unmodified client (`Disabled` scripts, `StarterGui`
  scripts before spawn, `Tool` scripts before equip) depend on game state the build cannot see.

**The form that works: attest the published place version, from CI.** A server runs one place version until it is
shut down or restarted (documented, `projects/update-games.md`, via `build-checks.md` §4.2), and its clients get
their scripts from it by replication *(inferred, as there)*. So the client scripts an unmodified client runs are
the published version's, and those can be read on the developer's side.
- **Build.** `lync build` already writes per-shard digests (SHA-256 over LF-normalised bytes after line 1,
  `build-checks.md` §3.2). It also records the digest of each woven built copy (`codecs-in-scripts.md`) and, as an
  inventory, of every other script in the reachability scan set (`v5-integrity.md` §3), which it reads anyway.
- **Check.** `lync check --published <universe>/<place>[/<version>]`, run after Place Publishing, creates one Luau
  Execution task on the versioned endpoint (`…/places/{p}/versions/{v}/luau-execution-session-tasks`, documented,
  `security-tooling.md` §4). The task walks the same scan set, hashes each script's `Source` with
  `EncodingService:ComputeStringHash(source, Enum.HashAlgorithm.Sha256)` (security None, thread-safe, verified
  dump), and returns `{path, digest}` as JSON (≤ 4 MB of return values, documented). The CLI compares with the
  manifest.
- **Unverified, decisive:** whether a Luau Execution task's thread holds `PluginOrOpenCloud`, and so can read
  `Source`. The docs say only that the task "may access and update the data model of the place, including invoking
  any module scripts" (documented, creator-docs `cloud/reference/features/luau-execution`, read 2026-10-15). If it
  cannot, the task `require`s each client shard and returns its identity constants (build id, seed-0 schema hash,
  generator version): that still finds a published pair from another run, not a hand edit.
- **Not used:** the Instance API reads script `Source` but needs "a collaborative session enabled" and does not say
  which version it reads (documented, `cloud/guides/instance.md`, read 2026-10-15), so it does not attest the
  published version.
- **Stays fixed:** wire, golden frames, schema hash, types, `HELLO`. Nothing runs on clients or game servers.
- **Studio-only projects:** not available. No plugin publish hook exists (CSB §1.4); the plugin's drift codes
  (`editedShard`, `unpairedShard`) cover the open place only.

**Facts** (build codes from `lync check --published`, in `report.json` and the text report; none at run time):

| Code | Exact trigger | Evidence | Known causes with no tampering |
|---|---|---|---|
| `publishedShardDiffers` | a client shard part in the published version whose digest differs from the manifest's | `path`, `part`, `expectedBuild`, `foundBuild` (the body's build id) | a Studio publish after the plugin regenerated shards (another build id); a hand edit published from Studio; the manifest of another CI run passed to the check |
| `publishedShardMissing` | a shard part the manifest lists, absent at its path in the published version | `path`, `part` | a Studio publish from a place copy without it; a shard moved after the build |
| `publishedWovenDiffers` | a woven built copy whose digest differs from the manifest's | `path` | a Studio publish, which carries the developer's unwoven source (built copies exist only in the CI artefact) |
| `publishedScriptChanged` | a scanned client script Lync did not write whose digest differs from the build-time inventory, or that is new or absent | `path`, `change` (1 changed, 2 added, 3 removed) | any edit published after the CI build; this is the developer's own code |

`lync check` exits non-zero on the first three, which are mismatches between artefacts of one build (the argument
of `build-checks.md` §3.5 for fixed codes); `publishedScriptChanged` is listed and never changes the exit status.

**What it protects, and what not.** It detects published client code that differs from the reviewed build: a
collaborator's Studio publish over a CI release, a shard pair from another run, an edited shard. Classes: none of
the modified-client classes; a modified client is untouched by it. It does not attest what any client runs beyond
the unmodified-client case.

**Cost.** Run time and wire: zero. CI: one Luau Execution task per check (5 task creations per minute per API key
owner, ≤ 5 min per task, documented) and one SHA-256 per scanned script (0.9–1.4 GB/s in Lune's `serde.hash`,
`build-checks.md` §3.5; `EncodingService` speed unmeasured). Developer: an API key with scope
`universe.place.luau-execution-session:write`. Options: none (a CLI flag).

**Outcome: adopt narrowed.** Attest the published place version from CI as above. Run-time self-attestation stays
refused; reason (not cost): no unmodified-client API reads its own code, and anything the shard can compute about
itself a modified client computes by running the same shard, which proves only what the tag already proves.

## R31. A per-frame decode budget proportional to frame bytes

**Earlier reason** (`m1-code.md` B1 proposed "k × the frame's bytes"; CH:400; `v5.md` §4.8 option (b)): "Honest
constant columns reach about 21,845 elements per byte, so a byte ratio either admits the attack or refuses honest
data." The design chose static rules (`zeroWidthElement`; W ≤ 65,536, `elementsTooMany`) and a per-player server
bucket `inbound.elements` (20,000/s, burst 65,536), charged before allocation (rule 10, `overElementBudget`). Assumed:
the ratio is judged on honest frames only; the attacker's control of frame bytes is not argued.

**What it would protect.** Server decode CPU and heap against amplification: few bytes promising many elements
(review-m1 p2: 3 B into 4.2 million tables before the static rules). Any sender that can call `FireServer` with a
crafted buffer (route A0; no capability class beyond running code on the client). It protects nothing on clients.

**Measured: what the current rules admit** (verified, `r31_decode.out`, the milestone decoder `f1fbfd7:src`, 3 runs
each; "elements" as `v5.md` §4.8 counts them; bytes include the run header's count):

| Shape (worst cases the planner accepts, plus one dense record) | B | elements | elements/B | ns per element, interpreted | native | heap per element |
|---|---|---|---|---|---|---|
| `t.array(t.bool(), 65535)`, all false | 3.1 | 65,536 | 20,972 | 64.9–71.7 | 21.6–27.2 | 16 B |
| `t.array({ a = t.bool() }, 65535)`, all false | 3.1 | 65,536 | 20,972 | 178.3–212.2 | 125.7–132.3 | 112 B |
| a run of 65,535 `{ a = t.bool() }` messages, all false | 4.9 | 65,535 | 13,443 | 161.6–184.5 | 97.2–111.7 | 96 B |
| a run of 65,535 `t.bool()` messages, all false | 4.9 | 65,535 | 13,443 | 60.4–72.1 | 23.7–24.7 | 0 B |
| `t.array(t.array(t.bool(), 255), 255)`, all false | 3.1 | 65,281 | 20,890 | 65.9–77.3 | 28.4–30.4 | 32 B |
| a run of 64 six-field records, random values | 397.6 | 64 | 0.161 | 1,238–1,681 | 538–687 | 352 B |

Derived at the defaults (`v5.md` §7.5), per player:
- **Element-driven** (a table per element, the costliest attack row): 20,000 elements/s × 161.6–212.2 ns = 3.2–4.2 ms/s
  interpreted, 1.9–2.7 ms/s native; one frame spending the 65,536 burst: 10.6–13.9 ms interpreted, 6.4–8.7 ms native,
  7.3 MB of transient heap.
- **Byte-driven** (dense records, 6.21 B per message, 199–271 ns/B interpreted, 87–111 ns/B native): the two lanes'
  `bytes.perSecond` total 65,536 B/s, so 13.1–17.7 ms/s interpreted, 5.7–7.3 ms/s native, at 10,550 messages/s,
  inside the element bucket.
- So after the static rules, amplification gives a sender less decode CPU per second than ordinary dense messages
  within its byte budget: the byte buckets, not `inbound.elements`, bound decode CPU at the defaults. At 100 players
  sending at full budget, that is 1.3–1.8 s of interpreted decode per second of server time (0.57–0.73 s native).
  `v5.md` §7.5 marks the element default as unmeasured; these are the first figures for it.
- Element counts do not track CPU: 21.6–1,681 ns per element across the rows above.

**The ratio, re-judged.** A per-frame allowance of k × frame bytes adds a bound only where it is lower than the
bucket's. Frame bytes are the sender's choice up to its byte budget: it can fill any frame with canonical messages of
any client-sent definition that has a non-constant field (messages over `limit` are dropped after decode, §6.1 step
5, so filler costs the sender only bytes). At 65,536 B/s, k × 65,536 is below 20,000 elements/s only for k < 0.305
elements/B, which refuses every constant column above (13,443–20,972 elements/B) while admitting the dense record
(0.161). For k ≥ 0.305 the bucket binds first and the ratio never refuses anything the bucket admits.

**With generation.** The build knows each upstream definition's W and `limit`, so a per-definition cap on messages
per frame is computable: an unmodified client puts at most `burst` + `perSecond` × (time since its last flush)
messages of one definition into a frame (`v5.md` §5.4). The time since the last flush has no upper bound (a long
game frame, a manual `Lync.flush()` schedule), so a refusal at any fixed cap has a cause on an unmodified client: it
would not be `malformed`, and Lync drops only malformed input. Generation does not change who chooses the bytes.

**Facts.** No new code. `overElementBudget` already carries `bytes`, `allowance` and `elements` (`v5.md` §7.3), so
the ratio of a refused frame is in its evidence.

**Outcome: kept refused.** Reason (not cost): the sender chooses frame bytes within its byte budget, so any ratio
either refuses honest constant columns or is dominated by `inbound.elements`; the byte buckets already bound decode
CPU above what amplification reaches at the defaults (measured above).

## R33. Upstream (client-to-server) string interning

**Earlier reasons** (`v5-design-1.md` M5; `v5-design-1-redundancy.md` #4; CH:29, CH:61; `v5-extensions.md`
`strings`): "a per-player memory sink": 4096 entries capped by count, not bytes, so about 800 KB per player for
`t.string(200)` and 1.6 GB for 100 players at `t.string(4096)` (derived); "up to ≈92 MB" (`wire_overhead.out`);
per-connection tables break shared encoding and `FireAllClients`. Assumed: the table's contents are chosen by the
client and capped by count only; the shared-encoding argument is about downstream.

**Re-checked.**
- **Shared encoding does not apply upstream.** Upstream chunks are never shared (`v5.md` §4.1: "upstream, chunks
  are packed with no alignment, since nothing upstream is shared"; `generation-methods.md` §0.2). That reason holds
  only for downstream, where the `strings` extension already uses per-audience tables.
- **Memory per entry** (verified, `r33_intern.out`): an id → string array entry costs the string's length plus
  55–56 B when the table owns the string (68, 75, 119, 255 B for 12, 20, 64, 200-byte strings), and 16–32 B when
  the string is alive elsewhere (Luau interns string contents, so the entry is a slot). The earlier figures omitted
  the per-entry overhead: 4096 × `t.string(200)` is 1.04 MB per player, not 800 KB.
- **Decode** of one 20-byte value: a literal (`buffer.readstring`) 57–86 ns interpreted, 46.8–49.8 ns native; a
  reference (`list[id]`) 17.3–26.5 ns interpreted, 6.6–7.5 ns native.
- **What it protects.** Nothing: interning is a compression feature. The concern is the opposite, a sender (route
  A0, any client) pinning server memory. Generation does not bear on it (per-session data).

**Form A, adopted: upstream references into the tables the server already sent.** In the `strings` extension
(milestone 7), for a string field declared internable:
- **Wire (upstream only).** The value is `ref:u1`, then `0`: the literal as today (length, bytes in the tail); `1`:
  `table:EG0 id:EG0`. `table` numbers the per-audience tables in the order the server first sent each to this
  player; `id` is the entry's index in it. Both forms decode, so the choice is the client encoder's, as column mode
  is (`v5.md` §4.3); the reference encoder sends a reference whenever it holds the value. A 20-byte value in
  `t.string(32)` goes from 166 bits (u(6) + 20 B) to at most 27 bits with one table and ids below 4096; a value
  sent as a literal pays 1 bit more.
- **Server.** It holds the tables already, as their sender. Per (player, table) it keeps one count: the entries of
  that table it has sent to the player. A table is kept while any connected player has received it, so a reference
  always resolves; its bytes are bounded by the extension's byte cap (unspecified until milestone 7).
- **Client.** A reverse map from string to (table, id) for the tables it holds: 16–32 B per entry (measured slot
  cost above).
- **Server memory a client can pin:** none. The tables' contents are the server's own strings.
- **Interaction with other measures.** A `:canary()` field is never internable (declaration error `canaryInterned`);
  canary matching runs on the resolved value, at today's cost per value. Reachability, traps, `limit` and the
  element bucket are unchanged (a reference is one value, as a literal is).
- **Stays fixed.** Seed-0 golden frames and the schema hash of every schema without an internable field; generated
  types (the field is still a `string`).
- **Not covered:** an eviction policy. The extension's tables are append-only (`compression.md` §5); a policy that
  evicts would need a rule for a reference to an evicted entry.

**Facts.** One existing rule, with a narrower trigger:

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `malformed`, rule 2 | an upstream reference whose `table` is not below the number of tables sent to this player, or whose `id` is not below the entries of that table sent to this player | frame dropped | `lane`, `rule` | none: the server counts an entry when it sends it, before the client can receive and reference it |

**Form B, not adopted in this unit: a client-originated table.** The client interns its own strings on second sight
and the server mirrors them per player. With a byte cap C on the content (the client learns C in `WELCOME`; an
intern past C is `malformed` rule 2, with no cause on an unmodified client), server memory per player is at most
C + 56 B × entries ≤ 57 × C (derived from the measured overhead, one-byte strings): 233 KB per player at C = 4096,
23 MB for 100 players. Its cost is bounded, so the security reason no longer holds; but no upstream traffic model in
the docs measures repeated client-originated strings (`compression.md` §5 models downstream only), so no default for
C can be derived. Reopen with such a model.

**Option table.** None for form A (an encoder choice; the field marker belongs to the extension).

**Outcome: adopt narrowed** (form A in the `strings` extension). The refusal's reasons do not hold upstream: shared
encoding is a downstream property, and form A pins no client-chosen memory; form B waits on an upstream model, not
on a security reason.

## R34. Commit–reveal or cryptographic state sharing as a general feature

**Earlier reason** (AC §7 table, AC:732-733; the design never mentions it): "the server is trusted, so withholding is
enough. Keep provably-fair RNG and pre-send/reveal as recipes." Assumed: withholding costs nothing, so the only
reason to send early is fairness proofs. AC itself lists the use that assumption misses: "pre-send then reveal key:
ship encrypted bulk data early, reveal a small key at the moment it becomes visible, for zero-latency reveal of
large hidden data".

The item holds three mechanisms with different adversaries; each is judged on its own.

**(a) Pre-send, reveal later (sealed delivery).**
- **What it protects.** A value the server sends before the game makes it visible (next round's layout, a drop
  table, a timed puzzle's answer). Before reveal its plaintext is not on the client at all: only ciphertext under a
  64-bit key the client does not hold. Classes priced: **state**, **mem**, **packet** and **share** readers, before
  reveal, at 2^63 expected key trials per seal; HalfSipHash with c ≥ 2, d ≥ 4 "is expected to provide the maximum PRF
  security … for any function with the same key and output size" (documented, github.com/veorq/SipHash README, read
  2026-10-15). Unlike every measure in `v5.md` §6.2, its secret is not on the client before reveal, so full
  memory access does not reach it. Not protected: anything after reveal (every client gets the plaintext at reveal, a modified one no
  sooner); the ciphertext's length (unless `hideLength`); the time and count of seals; whatever the server's own
  behaviour discloses. What defeats it is on the server side only: game code revealing early or sending the value
  elsewhere.
- **Against withholding.** Withholding delivers N bytes at reveal time, N / R after it, where R is the engine's
  downstream rate for that player (unmeasured, `v5.md` §10). Sealing delivers a reveal of about 9 B and then decrypts N bytes
  at 210–231 ns/B interpreted (CLI). It shortens the reveal whenever R is below 4.3–4.8 MB/s divided by the device
  factor (both unmeasured on Roblox).
- **Form.** A definition option `sealed` on server-sent reliable events (the server's `fire` returns a `Seal` with
  `reveal()` and `discard()`; the client's `connect` handler runs at reveal with the decoded value, so client types
  are unchanged).
  - **Wire.** Each message of a sealed definition starts `kind:u2`: `0` seal: `seal:EG0 bytes:EG0`, ciphertext in
    the tail; `1` reveal: `seal:EG0` then the key as two u32; `2` discard: `seal:EG0`. The plaintext is the
    codec's single-row encoding written as its own `bits align tail`, zero-padded to a multiple of 8 B (or to the
    codec's worst case with `hideLength`), then XORed with the keystream: block j = HalfSipHash-2-4/64 under the
    seal key over (seal u32le, j u32le).
  - **Keys.** Seal key i = HalfSipHash-2-4/64 under a 64-bit server secret S, over (definition id, i). S is drawn
    at server start from a `Random.new()` instance used for nothing else and is never sent, so a revealed key
    discloses one PRF output, not the generator's state (Roblox does not document `Random` as cryptographic:
    unverified).
  - **Encode once.** One key per seal, not per viewer: the sealed chunk and its reveal are identical for every
    recipient, so they are shared chunks and stay eligible for `FireAllClients` (`v5.md` §4.2). Per-player values
    are separate fires, as today.
  - **Recipients.** `reveal()` and `discard()` go to the players the seal was sent to who are still connected. A
    recipient already holding `outstanding` unrevealed seals of the definition is skipped and the server reports the
    local fact `sendDropped` with a new `cause` 5.
  - **Client decode.** At a reveal the client decrypts and decodes the value under `v5.md` §4.8; a violation refuses
    the frame holding the reveal, counted in `refusedFrames` and sent in `REPORT` as today. A seal past
    `outstanding`, or a reveal or discard naming no held seal, is rule 2 or 7 on the client, also counted.
  - **Declarations.** `sealedPlacement` for `sealed` on a client-sent event, a request, a collection or the
    unreliable lane; `messageTooLarge` applies to the padded worst case plus the seal header.
  - **Stays fixed.** Seed-0 golden frames, and the schema hash of every schema without `sealed`: the option is
    serialized only when present, under serialization version 2 for that schema (`v5.md` §4.7 writes version 1).
    No generation is involved: the key is per seal, at run time.
- **Facts on the server.** Nothing sealed flows upstream, so none beyond `sendDropped` cause 5:

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `sendDropped`, `cause` 5 | local: a sealed send to a recipient already holding `sealed.outstanding` unrevealed seals of that definition | the send to that recipient is dropped | `cause`, `bytes` | game code sealing faster than it reveals or discards |

- **Cost** (verified, `r34_seal.out`, 3 runs per mode, 1, 16 and 64 KB): 210.2–230.9 ns/B interpreted, 22.3–27.9
  ns/B native, the same for sealing and opening (an involution, checked). A 16 KB seal: 3.4–3.8 ms on the client at
  reveal; 0.37–0.46 ms on the server once per seal, whatever the recipient count. Per seal, one key block: 1.7–1.9 µs
  interpreted, 0.18–0.22 µs native (8 B at the rates above). Wire: up to 7 B of padding per seal (or worst − actual
  with `hideLength`), 2 + EG0 + EG0 bits of header; a reveal is about 9 B; a discard 2 bits plus an EG0. Client
  memory: `outstanding` × padded worst case per sealed definition. Server: one recipient list per outstanding seal.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `sealed.outstanding` | integer | unrevealed seals per player per definition | 1–256 | 1 (chosen: one pending reveal, such as the next round) | client memory: `outstanding` × padded worst case; server: one recipient list per seal |
| `sealed.hideLength` | boolean | — | — | false (chosen) | true: every seal padded to the codec's worst-case size, worst − actual bytes more per seal |

**(b) Commit–reveal for provably fair outcomes** (gacha, shuffles: the server sends H(seed) before the player
acts and the seed after). The adversary is the server, not a client: it prices no capability class. It needs no
Lync wire or codec support: two ordinary server-sent definitions and `EncodingService:ComputeStringHash(…,
Enum.HashAlgorithm.Sha256)`, which client and server both call (security None, verified dump). It stays a recipe.

**(c) Cryptographic state sharing between peers** (OpenConflict). Roblox clients hold no state another peer must
be denied: the server holds all state and chooses what each viewer receives (the `interest` extension). It stays
refused, for that reason.

**Outcome: adopt narrowed.** Sealed delivery (a) as a milestone-7 extension in the form above; (b) stays a recipe
because it guards against the server and needs nothing from Lync; (c) stays refused because no peer state exists.
The earlier reason fails for (a): withholding costs the transfer time at reveal, which sealing removes.

---

## Implications

1. Keep R10 refused, with its reason restated: function names are shipped at debug level 1, but view keys, the
   shard's path and `require` give every tool a stable route, so per-build names price nothing (R10).
2. Correct CH:110's "changes nothing in shipped bytecode": true for locals, false for function names (R10,
   `r10_names.out`).
3. Keep generated function names readable for developers; don't add per-build or anonymous naming (R10).
4. Add `lync check --published` with `publishedShardDiffers`, `publishedShardMissing`, `publishedWovenDiffers` and
   the inventory code `publishedScriptChanged` (R11).
5. Before specifying it, check in one Luau Execution task whether the task can read `Source`; if not, ship the
   identity-constant fallback only and say it misses hand edits (R11).
6. Record manifest digests for woven built copies and an inventory of scanned client scripts, both written by the
   existing scan (R11).
7. Keep run-time self-attestation refused: anything the shard computes about itself proves what the tag proves (R11).
8. Keep R31 refused with the padding argument: the sender chooses frame bytes, so any ratio either refuses honest
   constant columns or never binds before `inbound.elements` (R31).
9. Put R31's measured figures beside `inbound.elements` in `v5.md` §7.5: 161.6–212.2 ns per element interpreted,
   97.2–132.3 native, worst case, and 3.2–4.2 ms/s per player interpreted at the default (R31, `r31_decode.out`).
10. Tell the lead that at the defaults the byte budgets, not the element bucket, bound decode CPU: 13.1–17.7 ms/s
    per player interpreted, 1.3–1.8 s/s at 100 players; those defaults are marked chosen and need a measured basis
    (R31).
11. Withdraw R33's refusal reasons for upstream: shared encoding is downstream-only, and 1.04 MB per player (not
    800 KB) was the uncapped design (R33, `r33_intern.out`).
12. Add form A to the `strings` extension: upstream `ref:u1`, then `table:EG0 id:EG0` into tables already sent,
    one count per (player, table), rule 2 past it, `canaryInterned` (R33).
13. Leave form B (a client-originated table) unspecified until an upstream string model exists; its memory is
    bounded at ≤ 57 × C per player (R33).
14. Add sealed delivery as a milestone-7 extension with `sealed.outstanding` (1) and `sealed.hideLength` (false),
    one key per seal from a server-held secret, encode-once kept (R34, `r34_seal.out`).
15. Measure the engine's downstream rate per player before choosing between sealing and withholding for any
    game feature; sealing wins below 4.3–4.8 MB/s on the CLI (R34).
16. Keep provably-fair commit–reveal as a documented recipe over two definitions and `EncodingService` SHA-256,
    and keep peer state sharing refused (R34).
