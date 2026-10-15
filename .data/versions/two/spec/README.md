# Lync v5 spec

The normative statement of Lync v5, as numbered claims that tests cite. The design documents that gave the
reasons (v5-api, v5-failures, v5-wire, v5-testing and v5-goals) are not part of the repository, so every claim
stands alone, and the names of those documents below only say what a decision or a conflict was about.

| File | Prefix | Area |
|---|---|---|
| [api.md](api.md) | A | the public surface: views, seams, codecs, events, requests, collections, control, types |
| [wire.md](wire.md) | W | the wire format: framing, codes, codecs, columns, events, collections, requests, handshake |
| [failures.md](failures.md) | F | failure channels, message grammar, observers, console, metrics |
| [limits.md](limits.md) | L | every number and bound |
| [harness.md](harness.md) | H | the test harness: property engine, assertions, simulated engine, reporting, statistics |

## Ids

- A claim id is `<prefix>-<n>` with `n` a positive integer. An id is never reused or renumbered, a claim is
  changed in place, a new claim takes the next free number, and a claim that is dropped stays as a row
  starting `Withdrawn.`.
- The order of rows follows the topic, not the number: a sentence split from an original claim takes a new id
  and sits beside its parent.
- A claim written with "must" states a requirement. A claim in the present tense that defines an encoding or a
  term binds as strongly.
- `M-n` names a Studio measurement (register below).

## Claim grammar

This is what the `claims` command reads, so tests and spec agree on what an id is.

- Claim files are every `*.md` in this folder except `README.md`.
- A claim is one line, `| <id> | <statement> |`, whose first cell matches `[AWFLH]-[1-9][0-9]*` exactly. The
  statement is one sentence on one line, and a pipe inside it is written `\|`. A table starts with the header
  `| ID | Claim |`.
- A provisional claim ends its statement with `(provisional M-n)` or `(provisional M-n, M-m)`, then a period.
- A waived claim ends its statement with `(waived: <reason>).`, the reason being the text that `judge` prints for it; only a claim that the Waived row below lists carries the marker, and it carries no provisional marker.
- A withdrawn claim has a statement that starts `Withdrawn.`. It is not counted, and citing it is an error.
- An id or an `M-n` inside a statement must resolve to a claim or a register row. Prose and headings are not
  read.

## How tests cite claims

A declaration cites its claims as its first argument, and an empty list throws (H-24):

```luau
-- Sketch; the module and its functions are illustrative.
suite:prove({ "W-23", "W-111" }, "writes 300 of 0 to 400 in 9 bits", function(check: Check): ()
	check:equals(Bits.length(Integer.write(300, 0, 400)), 9)
end)
```

`claims` runs without Studio: an unknown tag is an error and an uncited claim is `Untested`. `judge` marks a
claim `Proved` when a cited test passed in a full run, and a skipped test counts for nothing (H-23).

A claim is proved in one of seven ways, and a claim is proved the way its wording asks for.

| Kind | Proof | Suits |
|---|---|---|
| Tested | a passing test cites it, on a `World`, or in `test/live` for the claims about real remotes and the real engine: W-1, W-2, W-88, W-89, A-5, A-148, A-151, F-13, F-38, F-40, F-72; the adapter claims A-201 to A-207 are proved by suites that call `adapt(Lync)` on the test variant's entry | the default |
| Scripted | a `.test.luau` suite run by `lute test`, outside Studio, that drives the tooling itself: the `claims` command, `judge`, the coverage gate and the exit codes | H-14, H-15, H-23, H-29, H-30 |
| Typed | a Luau file in `test/types/` whose marked lines carry `-- proves A-n; the checker must report an error on the next line`; the checker must report an error on every marked line and no finding of any kind, lint warnings included, on any other | claims that say "must be a type error": A-49, A-56, A-68, A-69, A-97, A-128 to A-134, A-153 |
| Inferred | a Luau file in `test/types/` whose marked lines carry `-- infers A-n; the checker must report no finding on the next line`, the next line binding the value to a variable annotated with the type the claim names, so that a wrong inferred type is an error; the checker must report no finding on a marked line and none on any other, lint warnings included | positive typing claims: A-58, A-127, A-135, A-155 to A-158, F-67 |
| Declared | a `.ts` file in `test/types/ts/`, compiled with `tsc --noEmit` against `index.d.ts`, whose marked lines carry `// proves A-n; tsc must report an error on the next line` or `// proves A-n; tsc must report no error on the next line`; the diagnostics must match the notes exactly | the roblox-ts claims: A-139 and the seven claims that replace A-165, A-194 to A-200 |
| Reviewed | agent review of the code or the build | claims about code structure, and about the documentation: F-4, F-47, F-48, F-59, F-77, F-78, F-88 |
| Waived | a recorded reason that every report shows, written as the `(waived: <reason>).` marker that ends the claim's statement | a claim that cannot be proved yet; the ids listed here are the waived claims, and none is listed now |

## Provisional claims

A provisional claim holds its value until its measurement settles it. When one does, the value is edited, the
marker removed and the id kept; if the outcome changes what the claim means, the id is withdrawn and a new one
added. Before the first release the protocol version stays 1 while these settle, and after it any change to a W
claim bumps the version.

| M | Settles | Rule | Claims |
|---|---|---|---|
| M-1 | dense layout against aligned layouts, on real zstd | an aligned layout becomes version 2 if it beats dense by 8% after column modes on two workloads | W-91 |
| M-2 | remote names, nesting under a ModuleScript, instance arguments, a trailing nil instance argument and the unreliable cap, each measured in both directions with the unreliable drop warning | the largest passing sizes fix the 985 and the 6 per instance, the 64 and the name length, and if the directions differ L-7 splits in two; if the engine cannot fire 64 instance arguments, L-4 reopens | W-1, W-2, W-88, W-125, W-127, L-7 |
| M-3 | bit writer and mechanism return | picks an implementation, and a mechanism that costs over 5% of decode time for under 3% of bytes is switched off in the encoder, the column search by `columns = false` (W-55, A-117, A-190) | none |
| M-4 | reliable call cap, and the memory growth of decoding | the cap is the largest frame that decodes in 2 ms on the interpreter, and L-26 is the largest growth measured with margin | L-6, L-26 |
| M-5 | sequence width, settle delay | keep 8 bits while the worst reorder distance is under 64; settle is the smallest delay that always converges | L-15, L-17, A-108 |
| M-6 | baseline deltas for latest fields | specified as version 2 if the net saving is 20% or more of the position stream | W-173 |
| M-7 | stamp width | keep 16 bits if the maximum clock skew is under 10 s, else 24 bits (version 2) | L-16, W-145 |
| M-8 | entropy coder return | adopt per field kind only if it saves 15% of that kind's bytes at 2 microseconds or less per symbol, and then add a claim | none |
| M-9 | whether automatic flushing needs a byte budget, and what a flush `budget` should mean | send a 20000-record catch-up to 100 clients and record calls per second per client against the engine's call queueing and `Stats.DataSendKbps`; adopt a default budget if calls queue or frames drop | L-22, A-122, F-42 |

M-1 to M-8 come from the wire design's measurement plan; M-9 is defined by this spec.

## Decisions applied

| Decision | Claims |
|---|---|
| `Lync.enum` carries sorted item values | A-36, W-36, W-122, W-123 |
| Collection ids below 2^51, 64 non-partition fields, 16 namespaces per connection, 64 instances per call | L-1 to L-5, W-157, W-100, W-84 |
| Partition fields take exact types only | A-47 |
| `angle`, `direction` and `rotation` are exact unless given a step | A-28, W-115, W-117, W-32, W-120 |
| An oversize unreliable message demotes to reliable, is counted as `Oversize`, never thrown | W-62, W-149 to W-151, F-41 |
| Collection writes coalesce only while consecutive | W-98, W-167 to W-172, A-109 |
| An optional flush interval, defaulting to every frame | A-117 to A-119 |
| Remotes are parented under each copy's own module instance (provisional until M-2) | W-1, W-88 |
| A rate limit is a token bucket per player per definition, with a rate in tokens per second and a burst capacity that defaults to the rate; a fixed window would allow twice the rate across a boundary; the limit runs before `validate` | A-66, A-67, A-140, A-141, F-30 |
| A HELLO for a namespace the server has not registered gets status 3, and the client retries with backoff (0.5 s doubling to 4 s, no jitter) until a 30 s deadline, then reports a final refusal through the failure model: an error, a `Mismatch` event with cause `Unknown`, and the held sends discarded; the first status 3 also gives a `Recovered` event | W-191, W-192, L-23, L-24, F-34, F-36, F-37, F-82 |
| A namespace is keyed by its defining module, with no explicit-name form of `Lync.namespace`, so that the server and the client match without a string; a harness sample schema that needs a namespace lives in its own module | A-2 |
| Module-level functions act on all instances | A-16 |
| `update` of an absent id throws | A-86 |
| The drop reasons, the event kinds and fields (a drop with no definition is keyed by its reason), and bit-based metrics | F-25 to F-33, F-60 to F-67, F-76 |
| The console prints in every environment, with a 30 s window, 16 events per key and a 10 s remote retry | F-72, F-74, F-38, L-18 to L-20 |
| A flush `budget` is provisional on M-9 | A-122, F-42, L-22 |
| Hashes are specified by what changes them, not by byte layout, so golden hash values are recorded by tests | W-184 to W-186 |
| `Lync.stop` ends every existing instance, a view taken afterwards starts a fresh instance, and the harness stops between tests | A-123, A-151, A-152, F-11 |
| A collection write copies the record, reads return frozen snapshots, and "equal by value" means equal encodings, quantized values compared by index | A-84, A-100, A-102 to A-104 |
| Harness claims have a home, [harness.md](harness.md), with the prefix `H` | H-1 to H-32 |
| Two proof kinds beyond the test plan's Typed: Inferred for positive typing claims and Declared for the roblox-ts declaration claims | table above |
| `array` and `map` refuse optional elements, and `map` refuses quantized keys, at definition time | A-38, A-39 |
| The floor of 4 for `b` in W-30 stays, because the correctness of the error bound outweighs the bytes saved for rarely used coarse steps | W-30, W-116, W-119 |
| The numbers 2048 for the quarantine of timed-out request ids, L-25 to L-29 (L-26 provisional on M-4), and the tolerances of W-201 and A-28 | W-79, L-25 to L-29, W-201, A-28 |
| The reliable lane stalls at the first unadmitted block: the blocks before it are delivered, that frame from the block's bit offset and every frame behind it are held, and the lane resumes at the accept, which keeps lane order and delivers nothing twice; an unreliable frame naming an unadmitted slot is dropped at once; at its deadline a held frame is decoded in order, its admitted blocks delivered, and the rest dropped as one `NotAdmitted` drop, because blocks have no length prefix | W-188, W-204, W-205, W-206, L-12, L-30, F-31 |
| `test/types/ts/` is the home of the Declared proofs, and the test plan's layout lists it | table above |
| The harness claims H-16 to H-32 stand, pending the reviewer's confirming pass | H-16 to H-32 |
| W-119 states the analytic worst case of `281 / (2^b - 1)` degrees for `rotation`, which a hill-climb approached to within 8% at `b` of 4, 5, 8 and 12 and never passed; W-116 for `direction` holds | W-116, W-119 |
| `Lync.enum` values come from a Roblox API dump pinned separately from the luau-lsp types, because those list enum items without values; generation fails for an Enum missing from the dump | A-34 to A-36, A-166 |
| A zero-bit element count is at most 128, decoding is capped at 1024 bytes per frame byte plus 16384 and absolutely at 64 MiB (provisional on M-4), a breach is refused as `Malformed`, and W-202 is withdrawn in favour of L-26 | L-25, L-26, W-203, F-27, F-28 |
| The simulated unreliable drop uses L-7's formula, not 1000 raw bytes | H-26 |
| Signals in a seam have Roblox's shape, `:Connect(handler)` and `:Once(handler)` returning a connection with `:Disconnect()`, so that the engine's own signals can be passed as they are; every function in a seam is called with a dot; roster signals are `added` and `removing` | A-11 to A-13, A-191 to A-193, H-48 |
| The simulated `frame` signal fires every 1/60 s of simulated time, after the timers due at the same instant | H-115, H-116 |
| Under a fate the reliable lane delivers each frame once, at its fate's earliest delay (0 for an empty fate), held behind earlier frames on the connection; a delay of 0 delivers at the next `advance` and never inside `send` | H-7, H-17, H-117, H-118 |
| `harness/Signal.luau` has claims for `Connect`, `Once`, `fire` order, `Disconnect` during a firing and `connectedCount` | H-105 to H-114 |
| The roblox-ts mistakes are seven Declared claims, one each, and the npm entry's adapter has seven Tested claims for its runtime behaviour; A-165 is withdrawn | A-165, A-194 to A-207 |
| Report lines go to Output only after the POST to the local receiver has failed, which supersedes the test plan's "always" | H-70, H-128 |
| A run is `Incomplete` while any claim is `Skipped` or when none is `Proved`; a skipped test may carry its reason; a report holds one outcome per test id and DataModel; only the Tested and Scripted kinds get the five judged states, and the other kinds are reported by their own rule | H-23, H-30, H-37, H-124 to H-127, H-129 to H-131 |
| The distribution protocol bounds each count by 4 standard deviations, the tape records bounded draws reduced to their range, and `integer` shrinks to `t` for spans under 2^32 | H-16, H-72, H-103, section 6 of harness.md |
| Validators and transforms must not yield; this is documented and not detected at run time, because a coroutine per message costs too much on the hot path | F-88 |
| Timed-out request ids are quarantined, a wait for a free id raises `Pressure`, and a request whose id is already pending is dropped | W-79, W-207, L-11, F-43 |
| A repeated HELLO is idempotent, one with a different hash gets status 1, and HELLO byte 0 and VERDICT bytes 0 to 2 are stable across versions | W-193, W-208, W-198 |
| The encoder's column search has a switch, `columns = false`, which makes it emit PACKED | A-117, A-190, W-55 |

## Review choices

Where the gate review offered alternatives, the choice that keeps the claim testable was taken.

| Finding | Choice | Claims |
|---|---|---|
| no reachable trigger without a test-only hook | a trigger was named: a test of the private module or of the decoder calls it with a state its contract forbids | F-44, F-45 |
| "unspecified", "may" and a process rule | restated as what a receiver must accept, where an event travels, or what the version is; the bump rule moved to the provisional section above | W-59, W-175, W-159, W-86 |
| a claim that could not fail a test | withdrawn, with a claim to be added if M-8 adopts an entropy coder; and one that duplicated A-70 | W-174, L-21 |
| "dropped silently" and "ignored" against counted drops | a held request that expires is discarded without a reason; a late response is dropped as `Stale` | A-76, A-81 |
| the side test | the server when `RunService:IsServer()` is true, the client otherwise | A-148 |
| claims with several statements | split, one statement and one proof kind each | A-7, A-11, A-15, A-27, A-56, A-97, A-100, A-123, A-127 |

## Contradictions resolved

Decided by the decisions above and the design documents' Decisions table.

| # | Conflict | Resolution | Claims |
|---|---|---|---|
| 1 | wire W-1 (a Folder under ReplicatedStorage, fixed names), D-3 (three remotes per place) and §13 item 10 (one copy per place) against the module-instance decision | remotes are children of the copy's own module instance; two copies cannot collide | W-1, W-88 |
| 2 | failures §3 row 10 (the engine drops an oversize unreliable call; guard or warn) against wire D-7 and W-62 (demote) | demote, count, never throw; one recovery warning per window | W-62, W-149 to W-151, F-41 |
| 3 | wire W-7 (one call per recipient per lane) against W-9, W-10, W-11 (calls are cut) | W-7 holds except where a cut is required | W-7 |
| 4 | wire W-8 and W-71 (sections open only as the frame's last block, yet the same for every viewer) against per-recipient queues | the bits of a transition are identical; whether writes merge is decided per recipient queue | W-98, W-71 |
| 5 | wire §13 item 9 (an interval, only if M-2 shows overhead) against api §7 (only `flush = "Manual"`) | both exist, unconditionally; default 0 is every Heartbeat | A-117 to A-119 |
| 6 | api §3.1 (enum names resolve lazily) against wire W-36 (never the live item list) | the item list and count come from the generated table | A-36, W-122 |
| 7 | api §5 (a request waits for its handler up to the timeout) against failures §3 row 8 (no responder is an outcome) | it waits, then the asker sees `Timeout`; `Unanswered` is for a failed handler | A-76, A-78 |
| 8 | failures §2, §3 and §7 (request completions) against api §5 (one yielding `invoke` on both sides) | no completion form exists | F-13 |
| 9 | failures §4.4 (any decode failure, a Lync bug included, is a counted drop) against §3 row 12 (an internal error throws) | counted drop plus one native internal-error report per namespace per window | F-45 |
| 10 | api §3.1 (`Lync.instance` lists every creatable class) against its own `Lync.instance.Player` | every class of the pinned API types | A-34 |
| 11 | wire W-55 (the encoder emits the fewest bits) against D-11 (an encoder may always choose plain) | fewest bits by default, and a decoder accepts PACKED | W-55, W-140 |
| 12 | wire W-11 and M-2 (64 instances, provisional) against the decision | firm; M-2 reopens it only if the engine cannot fire 64 | L-4 |
| 13 | api §3.3 (no restriction) and wire §13 item 3 ("should be refused unless exact") against the decision | must be exact: five codecs | A-47 |
| 14 | failures §3 row 3 ("a call after close") against api §7 (no close call) | `Lync.stop` is the close | F-11 |
| 15 | failures §7 (checking a value returns a `Result`) against api §7 (no such member) | `Lync.check` | A-125 |
| 16 | testing §7 and §13 (clock, transport, roster as parameters) against api §7 (none) | an optional seams record | A-10 to A-16 |
| 17 | failures §3 and §5 name `int` and `:newest` | v5 names are used throughout | none |
| 18 | wire W-86 (any change bumps the version) against claims still provisional | the bump applies after the first release | W-86 |
| 19 | goals, failure model (listener tracebacks captured by `xpcall` at the thread's entry) against failures §4.2 (no `pcall`, the engine reports natively) | failures §4.2 holds | F-4, F-13 |
| 20 | failures §10 questions 1, 3, 4, 5 are open | console prints in every environment (F-72, F-74), window 30 s and 16 events (L-18, L-19), marker `[Lync] ` (F-49), tracing in any environment (F-79); question 2 is internal, and only its observable result is claimed (F-8, F-12) | as listed |
| 21 | api §4 and §5 (`limit(perSecond)`, a cap per second) against the token-bucket decision | `limit(rate, burst?)` | A-66 |
| 22 | conflicts between claims found by the gate review: W-151 against L-9, F-1 against F-79, F-35 against F-75, A-112 and A-113 against A-94, W-116 against W-30 for small `b` | each claim was scoped so that both hold, and `b` now starts at 4 | W-151, F-1, F-75, A-112, A-113, W-30 |
| 23 | wire W-36 (item values in the generated table) against the pinned luau-lsp types, which list enum items without values | values come from a separately pinned API dump | A-36, A-166 |
| 24 | the earlier W-188 (hold a frame whole, then decode it again) against lane order: a later admitted frame overtook a held one and a partly delivered frame redelivered blocks | a lane stall at the first unadmitted block | W-188, W-205 |

## Choices still to confirm or overrule

The design documents are silent where these claims choose.

| Claims | Choice |
|---|---|
| A-6, F-6 | a repeated take returns one view; a duplicate namespace name is detected per instance, so no module-level registry enforces one namespace per module |
| A-8, A-9, A-82, A-159, L-27 | sends toward a peer that is not admitted wait, within 1024 blocks, and are discarded if the peer leaves or an invoke's timeout elapses |
| A-10 to A-15, A-143 to A-147 | the shapes of the three seams, with `clock.frame` as the flush tick and a `cancel` for timers |
| A-22 to A-27, A-39 to A-42, A-154, A-164 | accepted argument forms, map key codecs, at least one `oneOf` key, flag, variant and definition, `kind` reserved in a variant |
| A-55, A-63 to A-65, F-22, F-88 | held-back latest values, silent discard without a listener, `validate` and `limit` replace, a validator returns nil or a string, a yielding validator counts as raising |
| A-67, A-141 | a bucket starts full, and its capacity is never below one token |
| A-85, A-87 to A-94, A-105, A-106 | removing an absent id is a no-op, audiences follow live groups, `show` and `hide` fire no signal |
| A-111, A-114, A-115 | recipients resolve at the call, once per player, and a group takes its roster from `seams` |
| A-117, A-126 | settings `console` and `profile`, `trace(false)` |
| A-160 to A-163, W-193, W-195, W-196, W-198 | what a connection is, releasing a leaver's state, an idempotent HELLO, how a latest write travels, and the stable first bytes of HELLO and VERDICT |
| F-38, F-40, F-43, F-83 to F-87, F-89 | the missing-remotes outcome after 10 seconds, `SendFailed`, the `Requests` condition, console counts, the four new molds, and summed metrics |
| F-76 | the names `unattributed`, `discardedBlocks`, `lostFrames`, `queuedBits` and `flushedBits` |
| W-104, W-124, W-129, W-130, W-168 to W-172, L-5, L-8, L-9 | earlier messages survive a refusal, an engine without an enum item, union and element rules, merge results, and what a single message is |
| W-192, L-23, L-24 | the backoff numbers and the 30 s deadline, which the decision left to the spec |
| W-204, L-30 | the 30 seconds a held frame waits, which the decision left to the spec |
| A-117, A-190 | the name `columns` for the encoder switch |
| L-25, L-26 | the values 128 elements and 64 MiB, which the decision left to the spec |
| A-36, A-166 | the pin of the API dump is a file of its own beside `definitions/Roblox.pin.json`, which does not exist yet |
| F-87, F-92, F-93 | the trace size as the block's bits divided by 8 rounded up, one trace line per recipient, and the wording of the server mismatch warning |
| W-205 to W-208 | the lane resume rule, unreliable drops, the pending-id drop and the repeated HELLO with a new hash |
| H-33 to H-55 | the harness claims added by the confirming review, pending its confirming pass |
| H-59 to H-70 | the Output-line format: the prefix with an 8-digit run id, standard base64 pieces of 3900 characters, a line limit of 4000 characters, and a CRC-32 on every line |
| H-71 to H-104 | the generator claims, written from `harness/Generators.luau` and checked by running it; the shrink bounds of 10000 and 1000 calls are measured with margin |
