# Security measures refused, kept out, deferred or never decided, with generation in view

Scout brief, 2026-10-15. Inventory only: no verdicts. For each item: where it was decided and re-judged, what it
prices, every recorded reason, every cost or limit it cites (marked **measured**, **derived** with inputs, or
**asserted**), tags for what the reason assumes, one line on how generation could bear on it, and facts a
re-judgment would need that the docs don't verify.

**Generation** = the generated path: the build (CLI or Studio plugin) emits per-side shards, with a build seed
(default `"release"`, one per build run) that already rotates record field order and the tag's two HalfSipHash
constants at zero run-time cost (`design/v5-integrity.md:33-63`; measured: same opcode sequences,
`research/client-security-build.md:320-345`, `probes/client-security-build/run.out`).

**Claim marks** follow the docs: **verified** (run or read in source), **documented** (official docs), **reported**
(third party), **unverified**. Cost provenance: **measured** (a probe or the milestone build `f1fbfd7`, data in
`probes/`), **derived** (arithmetic from stated inputs), **asserted** (no measurement or derivation given).

**Tags** (what the recorded reason assumes): `runtime-cost`, `runtime-path`, `shared-artefact`, `library-package`,
`script-rewrite`, `protection`, `platform`, `author-decision`. `none recorded` where the docs give no reason.

**Reading.** Read in full: every Markdown file under `.data/docs/` (`design/*`, `research/*`, `reviews/*`,
`agents.md`), every README and RESULTS file under `probes/` (`build/README.md`, `diagnostics/README.md`,
`compression/studio/README.md`, `typing-and-codegen/RESULTS.md`), and the cost probe outputs and scripts cited
below. Probe source files not cited here were not read.

Abbreviations: CS = `research/client-security.md`, AC = `research/anticheat-design.md`, CSB =
`research/client-security-build.md`, CH = `design/v5-changes.md`, INT = `design/v5-integrity.md`.

---

## 1. Cost figures that recur, and where they disagree

| Figure | Source | Provenance | Inconsistency with other measured figures |
|---|---|---|---|
| HalfSipHash per frame, native: 0.48 µs/64 B, 5.5 µs/1024 B | `probes/review-redundancy/halfsiphash_cost.out` (draft-1 probe, cover 1024) | measured | The milestone build measured 0.26–0.42 µs/64 B and 3.1–3.7 µs/1024 B native, 1.8–3.5 and 22–24 µs interpreted (`v5.md:609-611`, `probes/build/results/579015b.json`, `c91960e.json`). The draft-2 downstream-tag refusal (CH:102) uses the older, higher figures. |
| Tag cost per covered byte | CS:291-296 estimate 13–23 ns/B; review-redundancy 35 ns/B interpreted (`v5-design-1-redundancy.md:530-538`); `simplifications.md:229-231` 50 ns/B interpreted, 7.5 ns/B native (derived from the 64 B per-frame figure, so per-call overhead is included); build 22 ns/B interpreted, 3.5 ns/B native (`v5.md:610`, derived from the 1024 B figure) | estimate / measured / derived / derived from measured | Four figures in the docs, spanning about 2x; the design uses the build's 1024 B derivation (CH:510). Any "CPU per byte at the tag's rate" (masking, CH:556) inherits whichever is meant. |
| "Runtime field shuffling: 2–3x slower per record write" | CSB:335-345, `probes/client-security-build/rotation/compare.py`, `runtime.luau`, `run.out` (writeHit 41–72 ns generated vs 113–142 ns "runtime tables", interpreted only, one 3-field record, 3 runs per variant on a shared machine) | measured | The "runtime" variant is a loop over a table of per-field closures, i.e. a table-driven writer, not "straight-line code plus a shuffle". It measures the generated-vs-table-driven gap that `typing-and-codegen/RESULTS.md` P1 puts at 3.2–4.6x interpreted, 4.2x native. CSB:368-372 says the runtime path "already iterates a field list, so a permuted list costs it nothing extra". No native figure for writeHit. |
| "Codecs scattered: 5.0x bytecode" | CSB:400, `probes/client-security-build/placement/size.out` (50 call sites each inlining one 3-field, 15-byte encoder: 22,927 B against 4,587 B at `-g0`) | measured | Ratio of one synthetic case; absolute growth 18.3 KB for 50 sites. Scales with call-site count and encoder size; no other configuration measured. Whether script bytecode download is compressed by the engine: unverified in the docs. |
| Failing `pcall` (caller probe) 2.2–3.3 µs | CS:210-213, `probes/review-redundancy-2/inbound_hotpath.out` (failPcall 2.5 µs interpreted, 2.2 native) | measured (CLI) | Roblox device cost unverified (INT:110). |
| Masking: +62 %, +191 %, +272 % after zstd | CS:447-452, `probes/client-security/zmask.out` | measured, Python zstd level 3 on synthetic byte-aligned draft-wire frames | v5's bit section is stated not to compress further (`v5.md:499-503`, `[compression §2.4]`), so masking the bit section costs about 0 B (CH:556 says so); the +62–272 % applies to masking the byte tail. Engine codec, level and threshold unmeasured (`v5.md:1253`). The id-permutation column of the same probe shows +35–41 % on chat-like 256–1024 B frames, against CS:449's "0–3 % on input-like frames". |
| Permutation build | `inbound_hotpath.out` permBuild: 18.3 µs interpreted, 4.3 µs native per 200 ids | measured | — |
| Per-session id shuffle memory "about 20,000 slots" | CS:389, CH:104, CH:557 | derived: 200 definitions × 100 players | bytes per slot not given. |

---

## 2. Refused or kept out

### R1. Downstream tags and a client-side replay window
- **Decided:** CS:312-314 (refuse), CS:740 (§8 #15); CH:102 (draft 2, still refused); CH:555 (3.5, still refused).
- **Prices:** an injector of inbound frames, who fires Lync's client listener with fake frames (`getconnections`,
  `firesignal`; CS:90, INT:25). The view protected is the injecting client's own.
- **Reasons:** "the only consumer of that verdict is client code the attacker controls" (CS:313); "a PRF per
  recipient per frame (0.48–5.5 µs native each), which at 100 players × 60 Hz is up to about 3% of a core, and the
  end of `FireAllClients`" (CH:102); 3.5: "Cost is not the reason: no third party can write a client's downstream
  (the engine's transport carries it), so they protect only a modified client's view from itself; the refused-frame
  report covers non-canonical injection" (CH:555).
- **Costs cited:** PRF 0.48–5.5 µs — measured (draft-1 probe). "About 3% of a core" — derived: 100 × 60 × 5.5 µs =
  33 ms/s. With the build's 3.1–3.7 µs/1024 B it is ≤ 2.2 %; at 64 B frames ≤ 0.25 %; the busy model has 80
  downstream frames/s, not 60 (`v5.md:457-459`). End of `FireAllClients` — derived (per-recipient key); engine
  per-call cost unmeasured (`v5.md:1258`).
- **Tags:** `protection` (current); `runtime-cost` (draft 2, withdrawn in 3.5).
- **Generation:** the current reason (who holds the verifier) is independent of generation.
- **Needs:** whether any route other than the client's own process can write its downstream (documented engine
  transport only, CH:555).

### R2. Masking or whitening frames
- **Decided:** CS:445-452 (refuse), CS:741-742; CH:103 (draft 2, re-judged with generation); CH:556 (3.5).
- **Prices:** passive readers of frame bytes (spies, packet-level hooks, CS:94, CS:99-114) and any byte-level forge.
- **Reasons:** "forfeits engine buffer compression … and stops nothing above the wire"; "the mask lives in the
  same client" (CS:452). Draft 2: per-session key would make passive reading per-session work, "but everything it
  hides is readable through the typed API, whose names game code fixes, so no generation can make that counter
  specific; every forge it blocks the tag blocks; … per-connection keys end `FireAllClients`" (CH:103). 3.5: "a
  reader gets [it] with less work by requiring the client shard and connecting to its signals, so it prices no
  reader" (CH:556).
- **Costs cited:** +62–272 % — measured (synthetic, Python zstd, §1); about 0 B for the bit section — derived from
  `v5.md:499-503`; CPU per byte at the tag's rate — asserted (no masking probe); end of `FireAllClients` — derived.
- **Tags:** `protection`, `runtime-cost`.
- **Generation:** per-build mask constants are as cheap as rotated tag constants; the reason (API route dominates)
  is independent of generation.
- **Needs:** engine compression level and threshold (`v5.md:1253`); whether reading through signals costs a reader
  less than reading bytes (asserted, CH:556).

### R3. Per-session upstream id shuffle
- **Decided:** CS:387-389, CS:733-734 (opt-in recommendation); CH:104 (draft 2, still out); CH:557 (3.5, still out).
- **Prices:** byte tools and frame captures reused across sessions on one server.
- **Reasons:** "Marginal over the tag and server shuffle" (earlier); "the read it forces is the same memory read
  the per-session tag key forces, in the same pass, so it adds no recurring work" (CH:104, CH:557).
- **Costs cited:** a decode table per player, about 20,000 slots — derived (200 × 100); build per player — measured
  4.3 µs native per 200 ids (§1).
- **Tags:** `protection`, `runtime-cost`.
- **Generation:** reason independent of generation (it is about the extractor's single memory pass). Fact: the
  per-server permutation seed and the tag key both reach the client in clear in `WELCOME` (`v5.md:654-655`), so a
  packet-level receive hook (CS:94, documented) reads both without a memory read *(inferred from the two
  citations)*.
- **Needs:** memory per slot; whether CSB's per-player-variant refusal still holds without this shuffle (see R7).

### R4. Runtime (per-session) field shuffling
- **Decided:** CS:376, CS:683 (`shuffleFields`, opt-in); CSB:373-375 (ignored when generated code is present);
  CH:105 (draft 2, still out); CH:558 (3.5, still out).
- **Prices:** forgers and decoders that hold a build's field order across sessions.
- **Reasons:** "Generated straight-line codecs cannot follow a per-session field order without becoming the slow
  path" (CSB:373-374); "2–3x slower per record write …; rotation gives per-build variation at zero cost" (CH:105);
  3.5: "Re-judged on protection: a forger who reads the per-session key reads a per-session order in the same pass,
  and rotation already varies order per build. Cost stated: 2–3x per record write" (CH:558).
- **Costs cited:** 2–3x — measured, but see §1: it compares straight-line code with a table-driven writer; on the
  runtime path the shuffle itself costs "nothing extra" (CSB:370-372). Up to 7 padding bits per string field —
  derived for the draft wire (CS:379-380); v5's tail makes string bytes position-independent *(inferred from
  `v5.md:486-489`)*.
- **Tags:** `protection` (current), `runtime-cost`, `runtime-path` (the "becomes the slow path" premise assumes one
  writer per record).
- **Generation:** a build could emit several field-order variants per record and pick one per session by index
  (one table lookup per message) instead of a table-driven writer; not considered in the docs.
- **Needs:** cost of variant selection per message; shard size per variant; whether a rotation-aware tool already
  reads order per session at no extra work (asserted, CH:558).

### R5. A nonzero seed on the runtime path
- **Decided:** `v5.md:125-127`, INT:42-43 ("The runtime path always runs at seed 0"); CSB:368-372 (the runtime
  path *can* take a seed, used only in tests).
- **Prices:** static tools against runtime-path (no-build) games, which get no rotation at all.
- **Reasons:** none recorded beyond tests and the identity golden set.
- **Costs cited:** CSB:370-372: a permuted field list "costs it nothing extra" — asserted (no probe).
- **Tags:** `none recorded`.
- **Generation:** n/a by definition; the seed could reach clients in `WELCOME` like the permutation seed (no doc
  says so).
- **Needs:** whether the planner's seed seam is safe in production; `HELLO` seed semantics for a server-chosen seed.

### R6. Codecs (and checks) spread into the game's own scripts — recorded neutrally; the author considers it viable
- **Variants the docs describe:**
  - (a) inline each definition's encoder into every game script that fires it, so no codec module exists
    (CSB:394-407); the earlier draft's "scatter and dissolve" (CSB:406-407);
  - (b) the same with per-build shapes, so the central queue needs per-build discovery and removing the shard
    module makes the `require(Net)` route per-build work (CH:106);
  - (c) "scattering checks into game scripts" as a build-time transformation, owned by the build researcher
    (CS:13-14), not developed further in CSB;
  - (d) per-player: the docs describe per-player shard *variants* (R7) but not per-player scattering.
- **Decided:** CSB:394-407 (refuse), CSB:790-791; CH:106 (draft 2, "still refused, reason changed"); CH:559 (3.5,
  "still refused").
- **Prices:** API drivers that `require` the shard (CS:124, the most common route, CS:130-134), and tools that find
  the codec module or queue by `getgc`/`filtergc`.
- **Reasons, each with what it assumes:**
  - "5.0x bytecode … Every client downloads it" (CSB:400) — measured on one case (§1). Assumes per-call-site copies
    of full encoders. 3.5 says cost is not the reason (CH:559).
  - "A schema change rewrites game scripts … noisy diffs, merge conflicts, and `UpdateSourceAsync` races with
    scripts a developer has open" (CSB:401; CH:106; CH:559 "rewriting the developer's scripts each build") —
    assumes the transform edits the developer's **source** (Rojo files or Studio scripts), not the **built place**.
    Docs facts bearing on that: Rojo runs no transforms (CSB:139-141, verified); Lune and the rbx-dom crates read
    and write `.rbxl` (CSB:104, documented/changelog); the CI path is `lync build` → `rojo build` → Open Cloud POST
    (CSB:237-238, documented); Studio-only users have no publish or save hook (CSB:160, verified), so a
    built-place transform is unavailable there.
  - "Codec errors would point into `Weapon:142`" (CSB:402) — asserted; assumes no position mapping.
  - "the central function remains, and an executor finds it with `getgc`/`filtergc` by its constants" (CSB:403) —
    `protection`; CH:106 re-judged it: with per-build shapes that discovery becomes per-build work, "a real
    recurring cost".
  - "removes the typed shard API, which the author made the primary source of types" (CH:106, CH:559) — assumes
    game code stops requiring a shard; a variant that keeps the shard for types and moves only encoders is not
    discussed.
  - "Speed: none" (CSB:404) — asserted.
- **Tags:** `script-rewrite`, `author-decision`, `runtime-cost` (withdrawn in 3.5), `protection` (CSB only; CH:106
  reversed it).
- **Generation:** the measure is itself a generation product; whether it rewrites sources or the built place is
  the open choice the reasons depend on.
- **Needs:** the engine's handling of script bytecode size on download; whether a place-file transform survives
  Team Create and Studio publishing; how typed shards and scattered encoders would coexist.

### R7. Per-player shard variants from a build-time pool
- **Decided:** CSB:409-427 (refuse), CSB:792-793; CH:107 (draft 2, reason changed); CH:560 (3.5).
- **Prices:** byte-level scripts shared between players inside one build; per-player static tooling.
- **Reasons:** "a join-time dependency and per-player instances for a gain the runtime shuffle mostly provides"
  (CSB:426-427); "A pool adds per-player field order only, which matters solely to an attacker who shares
  byte-level scripts between players inside one build" (CSB:423-424); draft 2: "the counter a variant needs (read
  this variant's constants from the loaded shard) is exactly what a rotation-aware tool already does"; "`PlayerGui`
  arrives after spawn, a `ResetOnSpawn = false` container, client start waiting on the clone, one replicated
  instance per player" (CH:107); 3.5: "no work is added" (CH:560).
- **Costs cited:** PlayerGui timing — documented (CSB:416-420); replication "about equal" — asserted; one script
  instance per player — derived.
- **Inconsistency:** CSB's gain argument rests on the per-session id shuffle (CSB:421-423), which the design keeps
  out (R3).
- **Tags:** `protection`, `platform`, `runtime-cost`.
- **Generation:** emitting N variants is build-time work; the reason is that a tool reading constants per load
  already handles variants.
- **Needs:** whether a tool written against "the loaded shard" costs more per variant; other per-player
  replication routes than PlayerGui (none listed).

### R8. Per-client or per-server generated code
- **Decided:** CS:152-154; CSB:429-436, CSB:794-795; CH:108.
- **Prices:** every static tool, per client.
- **Reasons:** "Clients have no compiler, and server `loadstring` can't reach clients as code";
  "`LoadStringEnabled` is server-only and `NotScriptable`" (verified, API dump 0.741).
- **Tags:** `platform`.
- **Generation:** only pre-built code can vary (R7 is the build-time form).
- **Needs:** none beyond the API dump.

### R9. Obfuscation, VMs, `getfenv`/`setfenv`, `loadstring` in runtime, shards or plugin
- **Decided:** CSB:717-735, CSB:798-799; CS:194-200, CS:569-571; CH:109; CH:562 (3.5: "The Creator Store rule, a
  platform constraint, not the deoptimisation").
- **Prices:** readers of shipped Lync and shard bytecode (decompile, `getconstants`, CS:92).
- **Reasons:** Creator Store restricts "Obscuring engine features … LuaVMs, `getfenv()`, `setfenv()`", "Requiring
  remote assets … `loadstring()`", "Including obfuscated code" (documented, CSB:719-724); `getfenv` clears the
  safe-env flag and turns off fast calls (verified in source, CS:194-200).
- **Costs cited:** deoptimisation — mechanism verified, magnitude not measured (an AWP detector "used this slowdown"
  is reported, CS:199); 3.5 drops it as the reason.
- **Tags:** `library-package` (the design calls it a platform constraint).
- **Generation:** generated shards are per game and "never published as a package" (CSB:747-749); whether the Store
  rule reaches a game's own generated scripts is not argued.
- **Needs:** whether Roblox rules restrict obfuscated code in a game's own scripts (docs cite only the Store page);
  cost of a VM or obfuscator on fast calls.

### R10. darklua renaming as polymorphism
- **Decided:** CSB:171-187, CSB:800; CH:110.
- **Reasons:** "Not seedable; local names are not shipped" (decompile returns `UNNAMED_<addr>`, documented); "It
  changes nothing in shipped bytecode, so it prices nothing".
- **Tags:** `protection`.
- **Generation:** independent for locals; shipped identifiers are table keys and constants, which renaming locals
  doesn't touch *(inferred)*.

### R11. Manifest self-attestation of client scripts
- **Decided:** CSB:505-512, CSB:796-797; CH:111.
- **Reasons:** `Source` read capability is `PluginOrOpenCloud` (verified); "a client's self-report is
  attacker-controlled".
- **Tags:** `platform`, `protection`.
- **Generation:** independent.

### R12. Build-time definition-id rotation
- **Decided:** CSB:316-318, CSB:801; CH:112.
- **Prices:** byte tools built against one build's ids.
- **Reasons:** "Subsumed by the per-server shuffle"; "The per-server permutation varies ids per server, more often
  than per build".
- **Fact bearing on it:** the permutation is derived from the server seed, the schema hash and the space number
  only (`v5.md:629-635`), not the build seed, and the server seed reaches the client in `WELCOME`. review-2 m5
  restated its cost as "per session: read the seed or table" (CH:220, `v5-design-2.md:386-390`).
- **Tags:** `protection`.
- **Generation:** mixing the build seed into the permutation derivation would be zero-cost generation work; not
  discussed.

### R13. Generated hidden trap ids (`traps = N`)
- **Decided:** AC:676-678 (`trapDefinitions`, default 2); `v5-design-1-redundancy.md:390-402` (#14); CH:71 (R14
  accepted); CH:113 (still out).
- **Prices:** blind wire-level senders; API drivers that browse what the client holds.
- **Reasons:** "two ways to declare traps"; "They arrive as unknown ids, already `malformed` with an exact trigger;
  reachability is the automatic trap that reaches API drivers"; a runtime count can't shape an already-built shard
  (redundancy #14).
- **Tags:** `protection`, `author-decision` (one way per thing).
- **Generation:** redundancy #14 offered "make them a build option in `lync.toml`" with names defined; not taken up.
- **Needs:** whether shard-visible decoy names would draw API drivers beyond what reachability catches.

### R14. Rotating union variant order (and list-enum order)
- **Decided:** `v5-design-2.md:365-370` (m1); CH:216 ("Only record fields rotate; variant order doesn't"); INT:42
  ("Union variant order and ids don't rotate"); `v5.md:90-92` (lists keep list order).
- **Prices:** static decoders and forgers keyed to variant indices.
- **Reasons:** design: none beyond resolving the review's contradiction. Research: "Enum and `oneOf` indices: zero
  bits, but a permutation can turn DELTA and RUNS columns … into PACKED for values that move in natural order
  (bounded … ≤ 2 bits per column worse than PACKED); do not permute them" (CS:380-382).
- **Costs cited:** ≤ 2 bits per column — derived for the draft wire's column modes; not re-derived for v5's
  residual coder (`v5.md:536-559`).
- **Tags:** `runtime-cost` (research); `none recorded` (design).
- **Generation:** same zero-run-time-cost mechanism as field rotation.
- **Needs:** bit cost of permuted variant and enum indices under v5's column coder.

### R15. Per-viewer slot permutation (decoy companion, watermark)
- **Decided:** AC:287-292, AC:596-600, AC:719-722 ("required for decoys"); CH:114 (refused); CH:566 (3.5,
  unchanged).
- **Prices:** two colluding accounts comparing records to find decoys; attribution of leaked dumps.
- **Reasons:** "Keys travel in adds, so comparing key sets finds what slot permutation hides; it costs per-viewer
  slot encoding."
- **Costs cited:** per-viewer slot encoding — asserted.
- **Tags:** `protection`, `runtime-cost`.
- **Generation:** independent (per-viewer, run time).

### R16. Per-viewer decoy slots outside the shared range; decoys only in `:newest()` rows
- **Decided:** `v5-design-2.md:191-213` (M4, both proposed); CH:207 (not adopted); CH:277.
- **Prices:** a patched client separating decoys by slot range or by placement.
- **Reasons:** "a separate range would itself mark decoys" (CH:207). The `:newest()`-only option has no recorded
  reason; the design chose per-viewer chunk copies (INT:167-169).
- **Tags:** `protection`.
- **Generation:** independent.

### R17. Low-order watermarks in quantized values
- **Decided:** AC:601-605 ("weak; recipe only"); CH:115; `simplifications.md:550-553` (vague reason); CH:535, CH:561
  (3.5).
- **Prices:** attribution of careless leaks (AC:610-611).
- **Reasons:** "Visible jitter for the honest player, and rounding removes it" (CH:115); 3.5: "One rounding to twice
  the step strips the mark with no per-build work, so it prices nothing; and it moves values past the declared
  step/2 error, breaking §3.3's precision. Cost: per-viewer encoding" (CH:561).
- **Costs cited:** per-viewer encoding — asserted; jitter magnitude never stated (simplifications noted one step).
- **Tags:** `protection`, `author-decision` (precision principle), `runtime-cost`.
- **Generation:** independent.

### R18. Hook and environment checks on the client
- **Decided:** CS:543-571 (all refused), CS:738-739; CH:101 (draft 2, still refused); CH:563 (3.5). Identity and
  source probes, refused at CS:563-566, were later adopted (CH:93-94, INT:88-118).
- **Prices:** hookers and spies (CS:118-128 A5, §1.3).
- **Reasons:** "the standard tools already pass them without extra work (spies wrap hooks in `newcclosure` by
  default and hook in place), so they price nothing, and no generation changes the engine functions they inspect.
  Adonis ships its equivalent off for false positives; `getfenv` forms deoptimise every script and are barred from
  the Creator Store" (CH:101); "they price nothing, at any cost" (CH:563). Adonis defaults verified by reading
  (CS:550-554); executor APIs documented (CS:75-97).
- **Tags:** `protection`, `platform`, `library-package` (getfenv), `runtime-cost` (deoptimisation, unmeasured).
- **Generation:** reason states generation cannot change the inspected engine functions.

### R19. Client-side decoy filtering
- **Decided:** AC:46, AC:268-269, AC:730; CH:117.
- **Reasons:** "Any flag in memory is a filter for the cheat."
- **Tags:** `protection`. **Generation:** independent.

### R20. Client-chosen rewind timestamps; client-stated time
- **Decided:** AC:414-419, AC:728; CH:118; state-sync §6.4 (`research/state-sync.md:744-746`); `timestamped`
  dropped (CH:302-305, R15 at CH:72).
- **Prices:** "backtrack" claims inside the rewind window.
- **Reasons:** "Letting the client name the rewind time, even clamped, hands the attacker a free choice of any past
  position" (AC:415-416); `rewind` uses the perceived tick from the newest ack.
- **Tags:** `protection`. **Generation:** independent.

### R21. Counting `limit` by client send time
- **Decided:** `v5-design-1.md:328-347` (M11 proposed it); CH:35 (rejected); `v5.md:919-921`.
- **Prices:** honest bunching after a stall (false `overLimit`), not an attacker.
- **Reasons:** "upstream frames carry no time and a client-stated time could not be trusted"; slack of 2 s ×
  `perSecond` instead.
- **Costs cited:** slack from p99 stall 850 ms under 5 % bursty loss — simulated (`v5.md:798`).
- **Tags:** `protection`. **Generation:** independent.

### R22. Quiet mitigation hooks (`rejectClaims`, `noLookAhead`, `inboundDelay`) and visible slow-downs
- **Decided:** AC:619-620, AC:723-725 (explicit API, never automatic); CH:116 (deleted); CH:304; `simplifications.md:583-584`.
- **Reasons:** "Author decision: no automatic or library-applied consequence; the game builds it on the observer."
  Research: Quicksand retired as "very visually jarring" (AC:620, documented).
- **Tags:** `author-decision`. **Generation:** independent.

### R23. Suspicion weights, scores, decay and `Lync.suspicion` (and the attempt's `Lync.escalate`)
- **Decided:** CS:3 (superseded banner), CS:575-649; `v5-attempt.md:244-246`; CH:123-128, CH:303.
- **Reasons:** author decision: "Lync reports facts only" (CS:3).
- **Tags:** `author-decision`. **Generation:** independent.

### R24. Any automatic kick, ban, throttle or client-visible rejection
- **Decided:** CS:651-662, CS:743-744; AC:731; `v5.md:24-25`, `v5.md:979-981`.
- **Reasons:** "contradicts Roblox's guidance and turns library bugs into player harm" (CS:743-744; guidance
  documented, CS:165-171).
- **Tags:** `author-decision`, `protection`. **Generation:** independent.

### R25. Library-applied drops for inferred-unreachable, early answers, decoy references, echoed canaries
- **Decided:** CSB:498-501 (`reachability = "enforce"` drops); CH:131-132 (decision 3: delivered and reported);
  INT:73-83, INT:217-224.
- **Reasons:** "dropping them would be a judgement" (CH:132). Declared traps are still dropped (INT:69-72).
- **Tags:** `author-decision`. **Generation:** independent (the build already supplies the reachability lists).

### R26. `REPORT` forcing a frame
- **Decided:** `v5-design-2-redundancy.md:286-300` (#8); CH:238; CH:564 (3.5, kept).
- **Reasons:** "Forcing adds no protection: a patched Lync suppresses `REPORT` either way."
- **Costs cited:** "about 5 B plus a call when forced" — asserted (engine bytes per call unmeasured, `v5.md:1258`).
- **Tags:** `protection`. **Generation:** independent.

### R27. `REKEY` more often than once per 60 s
- **Decided:** CS:263-267; `v5.md:796`; CH:565 (3.5, kept).
- **Reasons:** "more frequent rekeys add no protection, since the key is already per session."
- **Costs cited:** traffic bound — "chosen, unmeasured" (`v5.md:796`).
- **Tags:** `protection`. **Generation:** independent.

### R28. A 64-bit tag (and the superseded 16-bit default)
- **Decided:** CS:278-280 (16 bits); `v5.md:612-624` (decision: 32); CH:548.
- **Prices:** keyless guessing senders.
- **Reasons:** 64-bit: listed option "8 B and a longer finalization per frame"; 32 bits bounds acceptance to one
  per about 38 days at the default budgets (derived: 1320 candidates/s × 2^−32, `v5.md:613-619`).
- **Costs cited:** 8 B — derived; longer finalization — asserted.
- **Tags:** `protection`, `runtime-cost`. **Generation:** independent.

### R29. Integrity policy in `lync.toml` or shared modules
- **Decided:** CSB:546-552, CSB:803-804; `v5.md:1139` ("never in shared code or `lync.toml`").
- **Reasons:** "the runtime-only path needs them without a build, they are server policy that must never ship in
  shared code, and the client learns what it needs at the handshake" (CSB:548-549).
- **Tags:** `runtime-path`, `shared-artefact` (assumes one config read by both sides).
- **Generation:** the server shard is never replicated (CSB:269-271, documented), so build-time policy could be
  compiled into it alone; not discussed.

### R30. Integrity tuning as options (tag width 0/16/32, rounds, lookahead, `desyncAfter`, `rekeyInterval`, replay window, clock fit)
- **Decided:** CS:672-699 (knobs); `v5-design-2-redundancy.md:248-284` (#7); CH:240 (S7, adopted as constants);
  `v5.md:766-803`.
- **Reasons:** "no game has a reason to set them; each is a property of the transport or of Lync's own
  implementation"; several values "chosen, unmeasured" (`v5.md:781-783`).
- **Tags:** `author-decision`. **Generation:** constants could be per-build values like the tag constants; not
  discussed.

### R31. A per-frame decode budget proportional to frame bytes
- **Decided:** `v5-attempt.md:240`; `m1-code.md:24-57` (B1, proposed "k × the frame's bytes"); CH:400; `v5.md:743-746`.
- **Prices:** decode amplification (3 B into 4.2 million tables, measured `probes/review-m1/p2`).
- **Reasons:** "Honest constant columns reach about 21,845 elements per byte, so a byte ratio either admits the
  attack or refuses honest data" — derived.
- **Tags:** `protection`. **Generation:** independent.

### R32. Clients enforcing the element bucket
- **Decided:** CH:400; `v5.md:758-762`.
- **Reasons:** "the server is trusted and its compression must not be refused"; clients keep a fixed 2^22 allowance.
- **Tags:** `protection`. **Generation:** independent.

### R33. Upstream (client-to-server) interning
- **Decided:** `v5-design-1.md:209-228` (M5); `v5-design-1-redundancy.md:128-155` (#4); CH:29, CH:61;
  `v5-extensions.md:28-30`.
- **Prices:** server memory pinned by a client.
- **Reasons:** "a per-player memory sink" — 800 KB per player for `t.string(200)`, 1.6 GB for 100 players at
  `t.string(4096)` (derived, M5); up to 92 MB (derived, `wire_overhead.out`); per-connection tables break shared
  encoding.
- **Tags:** `runtime-cost`. **Generation:** independent (per-session data).

### R34. Commit–reveal or cryptographic state sharing as a general feature
- **Decided:** AC:621, AC:732-733 (refuse; keep provably-fair RNG and pre-send/reveal as recipes). The design never
  mentions it.
- **Reasons:** "the server is trusted, so withholding is enough."
- **Tags:** `protection`. **Generation:** independent.

### R35. Constraint modifiers dropped from `checks`: `maxRate`, `planar`, `exempt`, `cooldown`
- **Decided:** AC:471-481 (seven modifiers); `maxRate` removed by the lead before review-1 (`v5-design-1.md:6`, no
  reason recorded); `cooldown` folded into `limit` (CH:65, R8); `checks` keeps `within`, `monotonic`, `maxTotal`
  (`v5-extensions.md:24-27`). `planar` and `exempt` are never mentioned in the design.
- **Prices:** speed and teleport claims; rate-of-change claims.
- **Reasons:** `cooldown`: one rate limiter (principle 4). Others: none recorded.
- **Tags:** `author-decision`, `none recorded`. **Generation:** independent.

### R36. A built-in hit verifier (`Lync.hitscan`)
- **Decided:** AC:449-457, AC:702-706; CH:524 (#22: "`rewind` returns state and the game decides the hit");
  `v5-extensions.md:21-23`.
- **Reasons:** facts, not verdicts (implied by #22).
- **Tags:** `author-decision`. **Generation:** independent.

### R37. A per-fit clock-rate counter
- **Decided:** `simplifications.md:294-315` (#12 option a); CH:514.
- **Reasons:** "the option at 0.001 already gives the game nearly every fit, and two ways to read slopes would break
  principle 4."
- **Tags:** `author-decision`. **Generation:** independent.

### R38. A signal for calls per second above any plausible frame rate
- **Decided:** CS:514-515 (weight 0); CH:119 (covered).
- **Reasons:** "The inbound frame budget reports the same fact … with an exact trigger."
- **Tags:** `protection` (dominated). **Generation:** independent.

### R39. A per-frame transform hook ("compression or encryption experiments")
- **Decided:** `research/landscape.md:489-494` (implication 14: per-field codecs, per-message middleware and
  per-frame transforms, "compile it out" when unused); per-message middleware deleted with every hook but `validate`
  (CH:65, R8; `v5-design-1-redundancy.md:256-279`); `v5.md:1177-1178` ("There is no middleware … transformation game
  code"). The per-frame transform is never named in the design.
- **Prices:** whatever a game-supplied frame transform would add (the landscape brief names encryption experiments;
  compare R2).
- **Reasons:** for middleware, "four ways" to reject a message with undefined order, and a drop with no `rejected`
  answer (redundancy #8); one function hook (principle 4). No reason recorded for the per-frame transform itself.
- **Costs cited:** none; landscape asks that an unused hook cost nothing on the hot path (asserted).
- **Tags:** `author-decision`; `none recorded` for the per-frame part.
- **Generation:** a build could compile a declared transform into the shards, so an absent one costs nothing; not
  discussed.

### R40. A Studio line naming a fired trap
- **Decided:** CS:416 ("In Studio Lync reports it and prints one loud line naming the trap");
  `v5-design-2-redundancy.md:200-205` (#5 lists "a Studio print" among what `:trap()` adds);
  `research/diagnostics.md:795` (cut as "the Studio-only `trap` print"); traps report through the `unreachable`
  fact (INT:67-72).
- **Prices:** developer mistakes (own test code or the command bar firing a trap), not an attacker.
- **Reasons:** "an ad hoc Studio-only print", a second channel for one fact (`research/diagnostics.md:329`, `:688`).
- **Tags:** `author-decision`. **Generation:** independent.

---

## 3. Deferred to milestone 7 extensions (scope decided, specification deferred)

| # | Item | Where | What it prices | Generation bearing | Unverified facts it needs |
|---|---|---|---|---|---|
| D1 | `interest`: per-viewer relevancy, cells, hysteresis, look-ahead, owner-only fields | AC:130-212; `v5-extensions.md:8-13`; `v5-collections.md:74` | raw-state readers of Lync state (AC:200-202) | AC:142-143 assigns a build-time PVS bake to "the other researcher"; CSB never covers it | `Workspace:Raycast` cost; PVS size per map (AC:736-740) |
| D2 | `rewind` rings at the perceived tick | AC:385-462; `v5-extensions.md:21-23` | backtrack and origin claims | independent | engine interpolation delay (AC:429-430, unverified) |
| D3 | `checks`: `within`, `monotonic`, `maxTotal`, `:claim()` | AC:464-491; `v5-extensions.md:24-27` | out-of-bound claims | independent | — |
| D4 | `telemetry`: feature streams, `:aim()`, atoms | AC:535-575; `v5-extensions.md:34-37` | behavioural detection, offline | independent | Roblox terms on off-platform telemetry (AC:567-568, unverified) |

---

## 4. Described in the research, never decided (neither adopted nor refused)

| # | Measure | Where described | What it would price | Generation bearing | Unverified facts it needs |
|---|---|---|---|---|---|
| U1 | Capture `FireServer` once and call it as a plain function, hiding Lync traffic from `__namecall` spies | CS:112-114 (verified by reading SimpleSpy and Hydroxide) | casual remote spies only (not `hookfunction` or `raknet`) | independent | whether the runtime already does this |
| U2 | `tagRounds` 2-4 option; per-build variation of the tag function beyond its constants (rounds, rotation amounts) | CS:258-259, CS:674; CSB:316-318 speaks of "four" constants, the design rotates two (`v5.md:597`, INT:39-40) | tag reimplementations across builds | rotation amounts are immediates like the rotated constants *(inferred from `rotation/remarks.out`)* | PRF quality under altered rotation amounts; 2-4 cost (CS: about twice per byte, estimate) |
| U3 | Clock beacon false-positive rules: discard a window when most players shift together (server hitch); report slow clocks at weight 0 | CS:488-494 | false `clockRate` | independent | fit noise and slew on devices (`v5.md:1265`) |
| U4 | `roundTrip` and `ping` on server request results as an instrument for human-gated prompts | CS:536-539 | bots answering in one frame | independent | — |
| U5 | `foreignRemotes` build check (every remote not owned by Lync listed as attack surface); `dynamicAccess` warning | CSB:477-483 | unbudgeted entry points outside Lync | a build product | — |
| U6 | Core hash in `HELLO` as build identity; manifest drift check of hand-edited shards | CSB:465-468, CSB:509 | stale or foreign clients; accidental edits | a build product | — |
| U7 | `debug.info` caller attestation folded into the tag; "closure hygiene" | `v5-attempt.md:248-250` | API drivers; memory readers | the source list is a build product (INT:95-99) | never specified in the attempt |
| U8 | Field-level visibility classes beyond owner-only (team, below a threshold, after first sight); scoped events `:about(ref)` and its lint | AC:157-171, AC:697-699 | raw-state readers; event leaks outside relevancy | a lint is a build product | — |
| U9 | Re-derivation verifier `Lync.derive(fn, tolerance)` | AC:371-379, AC:622 | outcome claims that are functions of inputs | independent | float determinism across devices (`v5-attempt.md:212-226`) |
| U10 | Response-before-stimulus and reaction-time floor on `:reactsTo` definitions | AC:493-507 | clients acting on data Lync never sent them | independent | game-specific floors |
| U11 | Decoy-adjacent detections: a rewound hit on a decoy hitbox; `Lync.reportInteraction`; a lint for client `ref` fields into decoy collections | AC:281-285, AC:300 | aimbots and auto-interact tools that target decoys | the lint is a build product | — |
| U12 | A warning on unannotated free-form client fields (`:input()` or `:claim()` required) | AC:355-360 | outcome claims hidden as inputs | a build or planner lint | — |
| U13 | Relevancy telemetry (relevant-pair time per collection) | AC:206-207, AC:624 | relevancy bugs that leak | independent | — |
| U14 | Server-issued gameplay challenges | AC:623 | AFK bots | independent | accessibility false positives |
| U15 | Docs guidance: `StreamingTargetRadius`; staged release of unreleased content | AC:119-120, AC:608 | leaks through engine streaming and replicated content | independent | — |

---

## 5. Items whose recorded reasons carry only `runtime-cost`, `runtime-path`, `shared-artefact` or `library-package`

| Item | Tags | Note |
|---|---|---|
| R9 obfuscation, VMs, `getfenv`, `loadstring` | `library-package` | 3.5 names the Creator Store rule as the reason; generated shards are not Store packages (CSB:747-749) |
| R14 union variant and enum order rotation | `runtime-cost` (research); design records none | the bit cost was derived for the draft wire, not v5's coder |
| R29 integrity policy in `lync.toml` | `runtime-path`, `shared-artefact` | the server shard is never replicated |
| R33 upstream interning | `runtime-cost` | per-session data; generation doesn't bear on it |

Items with no recorded reason: R5 (runtime path fixed at seed 0), R14 on the design side, R35 (`maxRate`,
`planar`, `exempt`). R4 carried only `runtime-cost`/`runtime-path` until 3.5 re-judged it on protection.

---

## Open questions

- Does the Creator Store rule (R9) or any Roblox rule reach a game's own generated scripts? The docs cite only the
  Store page.
- Was the 2–3x "runtime field shuffling" figure (R4) meant as shuffle cost or as table-driven cost? The probe
  measures the second.
- Can a place-file transform (R6) run for Studio-only users, given no publish hook? CSB:160 says no hook exists;
  nothing else is proposed.
- Does the permutation (R12) stay independent of the build seed by intent? No doc says.
- Do the plain-text key and permutation seed in `WELCOME` (`v5.md:655`) change the stated tamper cost "read the key
  every session" (INT:29-31) for packet-level tools?
- Engine facts left open by the design and needed by several items: compression level and threshold, bytes per
  call, `FireAllClients` against per-player call cost, script bytecode download size (`v5.md:1252-1265`).
