# Review: simplifications standing in for definitions

2026-10-15. Audits the v5 design (`v5.md` draft 3.3, `v5-collections.md`, `v5-integrity.md`, `v5-tooling.md`,
`v5-extensions.md`, `m1-plan.md`, `m2-plan.md`) against principle 5 ("every option has a name, type, unit, range,
default and cost; every fact has an exact trigger and its known honest causes") and the rule that Lync reports
facts and never judges. The built code was removed from the working tree. Its names and text are cited from git
commit `f1fbfd7` as `f1fbfd7:<path>:<line>`. Treat them as things the next build must not repeat.

The word the author found, "anomaly", is gone from the design. It survives only as history in `v5-changes.md:123`
and `:212`. The same kind of slip is still present in other places, listed below.

**Count:** 26 findings: 12 major, 10 minor, 4 taste. None blocks milestone 2. Six of them must be fixed before the
first release, because code names and evidence fields are never renamed once shipped (`v5.md:860`): #3, #6, #10,
#11, #17 and #18.

| Category | Findings |
|---|---|
| Judging words | 4 (#1, #2, #11, #25) |
| Collapsed scales | 1 (#9) |
| Incomplete options | 5 (#7, #8, #13, #15, #22) |
| Vague facts | 5 (#4, #5, #14, #17, #24) |
| Vague quantities | 2 (#19, #21) |
| Vague behaviour | 2 (#16, #26) |
| Grouped facts | 5 (#3, #6, #10, #18, #20) |
| Hidden judgement | 2 (#12, #23) |

Findings are ranked by how much of the product each one shapes.

---

## Major

### 1. "Honest" is an undefined label for players, clients and code
**Judging words. Major.**
- **Where:**
  - `v5.md:281-282`: "so a wrong direction or lane can't be produced by an honest client".
  - `v5.md:1009-1010`: "asserting that each fact fires on exactly its trigger and never for the honest client".
  - `v5-integrity.md:65`: "so it never reports an honest call"; `:66`: "what honest client code fires"; `:87`:
    "can't tell from an honest client".
  - `m2-plan.md:336`: "every honest scenario raises no fact, and every attack raises exactly its fact"; `:378`
    "(honest model)"; `:392` "Honest suites"; `:394` "Ten honest clients"; `:434`.
  - Registry "Fix" lines at `f1fbfd7:docs/codes/`:
    - `tagMismatch.md:31`: "An honest client never produces it; nothing needs doing for a client that is not
      honest."
    - `impossibleAck.md:30`, `repeatedHello.md:29`, `desync.md:31`, `slotConflict.md:32`, `malformed.md:31`.
    - `overBudget.md:35` and `overLimit.md:32`: "If honest players reach it, raise …".
  - Test names at `f1fbfd7`:
    - `test/transport/mutation.spec.luau:260` "honest frames decode with rule 0" and `:638` "mutated honest frames
      …";
    - `test/codec/mutation.spec.luau:407` "honest directions are never refused";
    - `test/support/net.luau:143-144` `Net.HONEST`, "The honest model's settings".
- **Why.** Principle 5 uses "honest" for causes, and that use is fine. Everywhere listed above it classifies a
  player or a client, which is a verdict.
  - `tagMismatch.md:31` goes further: it names a class of "client that is not honest" and tells the developer
    what to do about it (nothing).
  - "If honest players reach it" asks the developer to sort players into honest and not before acting.
  - The term is never defined, so claims like "never reports an honest call" can't be checked. #5 shows that one
    of them is false.
  - `Net.HONEST` is a network with 5% loss and 0.3 s stalls. That describes the network, not anyone's honesty.
- **Provenance.** `[client-security §1]` and its fact tables, which had "Verdict" and "Confidence" columns
  (`research/client-security.md:351`, `:597`).
- **Replacement.** Define one term once, in `v5.md` §1:
  > **Unmodified client:** a client running this build's Lync runtime and shard as published, whose game code
  > reaches Lync only through its API.

  Then:
  - "honest client" → "an unmodified client" (`v5.md:282`, `:1010`, `v5-integrity.md:66`, `:87`);
  - "never reports an honest call" → the exact claim, with its exceptions (#5);
  - "Known honest causes" → "Known causes on an unmodified client" (the `v5.md:910` column header and every
    registry page);
  - "If honest players reach it, raise …" → "If it occurs with a cause listed above, raise …";
  - `tagMismatch.md`'s Fix → "Nothing is required by Lync; the frame was dropped.";
  - "An honest client never produces it" → "An unmodified client produces it only through the causes above";
  - `Net.HONEST` → `Net.DEFAULT`, "the default network model";
  - test names: "honest frames" → "encoder output", for example "encoder-produced frames decode with rule 0";
  - `m2-plan.md` §6.2 and §6.3 → "Unmodified-client suites" and "Modified-client cases".

### 2. The rule against judging words is a six-word list, checked only in messages
**Judging words. Major.**
- **Where.**
  - `v5.md:869-870`: "No judgement words ("suspicious", "illegal", "invalid", "bad", "exploit", "flagged").";
  - `f1fbfd7:test/diag/registry.spec.luau:50`:
    `const JUDGEMENT_WORDS = { "suspicious", "illegal", "invalid", "bad", "exploit", "flagged" }`.
- **Why.** A list stands in for the rule, and the list is the only enforcement.
  - It misses "anomaly", the word that slipped through. It also misses "abuse", "attack", "cheat", "malicious",
    "hostile", "unexpected", "naive" and "honest" in the sense of #1.
  - The lint scans `example` blocks only. Code names, evidence names and page prose are unchecked, so
    `configInvalid` (#11) is in the design's own code list next to the sentence banning "invalid".
- **Replacement.**
  - **The rule** (`v5.md` §7.1): "Codes, evidence names, messages and registry pages state what was observed and
    the requirement it was checked against. They never characterise the sender's intent or the value's quality."
  - **The lint**, applied case-insensitively and by word boundary to every code name, evidence field name, page
    body and `example`:
    `anomal*`, `abuse`, `attack*`, `bad`, `cheat*`, `exploit*`, `flag*`, `hostile`, `illegal`, `invalid`,
    `malicious`, `naive`, `suspic*`, `unexpected`, `weird`, plus `honest` outside the phrase "known causes".

### 3. `overBudget` merges three budgets, and the evidence can't say which one refused
**Grouped facts. Major (evidence is permanent).**
- **Where.** `v5.md:912`: "a frame finds its lane's frame bucket < 1 or byte bucket < its charge, or its decode
  exhausts the element allowance (rule 10)", with evidence `lane`, `bytes`, `instances`, `elements` (0 unless
  rule 10). The page `f1fbfd7:docs/codes/overBudget.md:35` says: "raise the budget that refused it".
- **Why.** Three triggers with different knobs share one reason:
  - `inbound.<lane>.frames`;
  - `inbound.<lane>.bytes`;
  - `inbound.elements`.

  With `elements = 0` the developer can't tell a frame-bucket refusal from a byte-bucket refusal. A 200 B frame
  refused by either bucket gives identical evidence `{lane 0, bytes 200, instances 0, elements 0}`. So the
  documented fix can't be followed.
- **Replacement.** Add evidence `bucket`: 1 frames, 2 bytes, 3 elements. Also add `tokens`, the bucket's level
  when it refused, rounded down. Alternatively split the reason into `overFrameBudget`, `overByteBudget` and
  `overElementBudget`. The split is the author's choice; the evidence field is the smaller change.

### 4. "Known honest causes" say "none" or "unknown" where the design itself documents a cause
**Vague facts. Major.**
- **`tagMismatch`** (`v5.md:915`): "a Lync bug (then repeated `desync`)".
  - `frameGap` lists `FireServer` raising on the client as an honest cause (`v5.md:916`). The server looks
    ahead only 4 counts (`v5.md:531`).
  - So 5 or more consecutive raising `FireServer` calls from an unmodified client make every later reliable
    frame a `tagMismatch`, and the 8th a `desync`.
  - **Add the cause:** "`FireServer` raising 5 or more consecutive times on the client".
- **`desync`** (`v5.md:917`): "unknown engine reconnect behaviour". "Unknown" is not a cause, and the reconnect
  question is not in §10's pending list.
  - **Replace with:** "the `tagMismatch` causes, 8 in a row". Add "engine behaviour on reconnect (does a
    reconnected client keep its count?)" to `v5.md` §10.
- **`schemaMismatch`** (`v5.md:921`): "a stale or mixed build". The trigger includes "names no loaded namespace"
  after the 10 s hold (`v5.md:584`). Namespaces are numbered by first server-side use (`v5.md:558`).
  - So a server that first requires a schema lazily, for example at round start, refuses unmodified clients.
  - **Add the cause:** "the server's first use of the namespace more than 10 s after the client's `HELLO`".
- **`slotConflict`** (`v5.md:922`) and **`repeatedHello`** (`v5.md:920`): "none", with no argument. This is a
  suspicion, not a demonstrated case.
  - For `slotConflict` case 3, the asking side has to time out twice on one slot while the answering side still
    holds the first ask. That needs a reliable-lane stall longer than `timeout`.
  - **State the bound:** "none while reliable-lane stalls are shorter than the request's `timeout`".
  - **Rule for every "none":** give the one-line argument, or the condition under which it holds.
- **`impossibleAck`** (`v5.md:919`): "none". Keep it, with the argument: "an ack is sent only for a frame that
  arrived, and the server extends the 12-bit seq against its newest sent".

### 5. Milestone 5 facts have no honest causes, and one claims "never"
**Vague facts. Major.**
- **Where.** `v5.md:929` defers all six to `v5-integrity.md` and leaves Evidence and Honest-cause cells empty.
- **`unreachable`, inferred.** `v5-integrity.md:60-65` scans "client-reachable code (scripts that replicate, and
  `Packages/`)" and concludes "so it never reports an honest call".
  - A `LocalScript` inside a `Tool` stored in `ServerStorage` and cloned into a `Backpack` at run time is not in a
    replicating container at build time.
  - That is Roblox's standard tool pattern. Its `Net.x:fire()` is reported `unreachable` with `declared = 0`.
  - **Replace "never" with:** "Known causes on an unmodified client: client code that the build did not scan:
    scripts stored in `ServerStorage` or `ServerScriptService` and cloned to a client at run time".
  - Or include those containers in the scan. That is the author's choice: scanning them widens what counts as
    client code.
- **`unreachable`, declared.** No cause is listed. **Add:** "client code that fires a definition the server marked
  with `:trap()`, which is a mistake in the game's declaration".
- **`clockRate`.**
  - `v5-integrity.md:112-113` reports when the slope "exceeds 0.006, the documented bound between
    `GetServerTimeNow` and the local clock". The research says an unmodified client "drifts at most 0.6% while it
    corrects" (`research/client-security.md:469`), and its fit noise is 0.03–0.08% on cellular (`:479`).
  - So the threshold sits exactly at the unmodified maximum, and noise carries an unmodified client that is
    correcting at full slew past it.
  - **Add the cause:** "a client correcting its clock at the maximum slew rate for 3 fits, plus fit noise
    (0.03–0.08% at σ = 20–50 ms)". Also see #12.
- **`canaryEchoed`.** No cause is listed. **Add:**
  - "game code that sends a collection record's fields back to the server, including the canary";
  - "a player message that equals a live canary by chance: probability 62^−12 per value per canary".
- **`clientReport`.** Causes are given per field (`v5-integrity.md:89-90`, `:104-105`), but the fact is one reason
  (#6).

### 6. `clientReport` merges three client-stated counts with different causes
**Grouped facts. Major (code is permanent).**
- **Where.** `v5-integrity.md:81-84`: "The server reports one fact, `clientReport`, with the four counts as
  evidence".
- **Why.** These are separate observations:
  - `identitySucceeded` is a probe read that succeeded at identity 8 (cause: Studio command bar, plugins);
  - `sourceUnlisted` is a caller chunk not in the build's list (cause: scripts cloned outside starter
    containers);
  - `refusedFrames` is the client decoder refusing a server frame (cause: a Lync bug);
  - `probes` is not a fact at all. It is the denominator.

  The reason names the channel, not what was observed. A game that wants to act on `refusedFrames` has to unpack a
  composite, and §7.3's one row can't hold three honest-cause lists.
- **Replacement.** Three reasons, each with evidence `count` and `probes`, all marked "client-stated":
  - `reportedIdentity`;
  - `reportedSourceUnlisted`;
  - `reportedRefusedFrames` (evidence `count` only).

  Keeping one reason is the author's call. If kept, rename it to what it is, `clientStatedCounts`, and list the
  causes per field in §7.3.

### 7. Schema options have no cost column, open ranges, and a default that escapes its range
**Incomplete options. Major.**
- **Where.** The `v5.md:268-279` table has the columns "Type, unit, range" and "Default". It has no Cost column.
- **Cost missing for every option.** `lane`, `limit`, `timeout`, `maxRecords`, `priority`, `reliableRate`. For
  example:
  - `maxRecords`: ⌈log2 maxRecords⌉ bits per row, plus per-slot server memory;
  - `limit`: one bucket per player per definition on the server;
  - `reliableRate`: order is lost against events (`v5-collections.md:20`).
- **`priority`:** "weight > 0". There is no type, no upper bound and no unit.
  - **Replace with:** "number, 1/1 (multiplies age in state ticks), (0, 1e6], default 1".
  - Or integer 1–1000. That is the author's call.
- **`limit.perSecond`:** "number > 0 (messages/s)". There is no upper bound.
  - **Give one:** for example (0, 1000], matching `burst`'s 1–1000.
- **`burst` default escapes its range.**
  - "`burst` defaults to max(1, ⌈perSecond⌉)" with range 1–1000.
  - In the built planner (`f1fbfd7:src/plan/planner.luau:932-934`), `limit = { perSecond = 2000 }` yields
    burst 2000 with no check.
  - `limit = { perSecond = 2000, burst = 2000 }` is refused with `paramRange` ("be an integer from 1 to 1000",
    `:948`).
  - **Fix:** default `min(1000, max(1, ⌈perSecond⌉))`, or bound `perSecond` at 1000. Either way, state it.
- **`reliableRate`:** "Hz, 1–60". It doesn't say whether the value is an integer or real.
  - **Fix:** state it. A real is fine, since it multiplies a time and is floored.

### 8. `Lync.configure` options: blank costs, cost cells that hold meanings, types the wire contradicts
**Incomplete options. Major.**
- **Where:** `v5.md:971-986`.
- **`state.rate`:** "Hz | 10–60 | 20".
  - It travels as `stateRate u6` in `WELCOME` and `RATE` (`v5.md:571`, `:577`), so it must be an integer.
  - `rate = 12.5` can't be carried, and the table doesn't say whether it is refused or truncated.
  - **Fix:** "integer, Hz, 10–60".
- **`inbound.unreliable.frames` and `inbound.unreliable.bytes`:** the Cost cells are empty.
  - Unlike the reliable row, the unreliable bytes row has no lower bound on `burst`.
  - **Fill:** "a player can make the server tag-check and decode at most `perSecond` frames/s beyond `burst`".
    The bytes row needs its burst range.
- **`{ perSecond, burst }`:** doesn't say whether each is an integer. **State:** perSecond real, burst integer.
- **`state.budget`, `state.floor`, `observe.window`, `observe.perPlayerEvents`, `observe.serverEvents`:** the
  "Cost and meaning" cells give the meaning and no cost. **Give the cost per unit:**
  - `observe.window`: memory held per open key for the window's length;
  - `perPlayerEvents`: one key per fact, about N B per key, measured;
  - `state.budget`: bytes on the wire per player.
- **`tag.cover`:** "tag CPU per covered byte, both ends" has no number. The measured figure exists (3.2 µs per
  64 B interpreted, 0.48 µs native, `v5.md:539-540`).
  - **Give:** about 0.05 µs/B interpreted and 0.0075 µs/B native, marked as derived from the 64 B figure.
  - **Define 0:** "covers no frame bytes, only count, lane, length and instance count".

### 9. `build.seed = "release"` is a label standing in for a definition
**Collapsed scales. Major.**
- **Where.**
  - `v5-integrity.md:48`: "`build.seed`, integer 0–2^32 − 1 or `"release"` (a fresh seed per CI release)";
  - `v5-tooling.md:31`;
  - `v5-tooling.md:83`.
- **Why.** "A fresh seed per CI release" doesn't define:
  - the entropy source;
  - when the seed is drawn (per `lync build` call, per commit, per tag);
  - how a client shard and a server shard built in two jobs get the same seed. If they don't, every `HELLO` is
    `MISMATCH`.

  The research defined it: "`"release"` draws a fresh seed and records it in the manifest"
  (`research/client-security-build.md:595`). `reviews/v5-design-1-redundancy.md:566` flagged it as "a label
  standing in for a definition", and it is still undefined.
- **Replacement.** Pick one and state it:
  - (a) `"release"`: each `lync build` invocation draws 32 bits from the OS CSPRNG and uses them for every
    namespace and both sides of that invocation, then writes the seed to `manifest.json`. Client and server must
    come from one invocation.
  - (b) Delete the keyword. CI passes `seed = <integer>` from an environment variable, `LYNC_SEED`.

  (b) removes a label. (a) keeps the convenience.

### 10. Request outcomes `rejected` and `unanswered` each merge several causes
**Grouped facts. Major, author decision.**
- **Where.**
  - `v5.md:338-340` and `:752-754`;
  - `rejected`: over `limit`, `validate` returned `false`, `validate` threw, a trap, `unresolved`;
  - `unanswered`: the handler threw, returned nothing, or ran past `timeout`;
  - `v5.md:749-750`: "outcome 0 value, 1 `rejected`, 2 `unanswered` (3 is malformed)".
- **Why.**
  - The asker can't tell "retry later" (over `limit`) from "don't retry" (`validate` false). The wire already has
    a spare outcome code, 3.
  - Merging the trap with `validate` false is deliberate: a trap must look like an ordinary rejection to an API
    driver. The design never says so, so a later revision could split it and break the trap.
  - "Returned nothing" is a mistake in game code and has no channel of its own.
- **Options.**
  - (a) Keep both merged, and write the reason in §5.2: "`rejected` doesn't distinguish its causes, so a trap is
    indistinguishable from a `validate` refusal".
  - (b) Use outcome 3 for `overLimit`, which leaks nothing the client doesn't know, since it knows its own limit.
    Make "returned nothing" a native report on the answering side, `handlerReturnedNil`, as well as `unanswered`.

### 11. `configInvalid` uses a banned word, and merges distinct failures
**Judging words and grouped facts. Major (code is permanent).**
- **Where.**
  - `v5.md:866`: "`build` (`staleShard`, `rawRemote`, `solverOff`, `configInvalid`)";
  - `v5-tooling.md:69`: "2 usage or configuration (`configInvalid`)".
- **Why.**
  - "Invalid" is on the banned list two lines later (`v5.md:869`).
  - The code covers a missing file, a TOML syntax error, an unknown key, a wrong type, an out-of-range value, a
    missing `[[namespace]]`, and unknown `format` versions.
- **Replacement.** Follow the declaration codes' pattern:
  - `configSyntax` (TOML parse failure, with line and column);
  - `configUnknownKey`;
  - `configType`;
  - `configRange`;
  - `configMissing` (no `lync.toml` and no plugin `StringValue`).

  Or one code, `configRefused`, whose message names the key and the requirement. Splitting matches
  `unknownOption` / `paramRange`; the choice is the author's.

### 12. `clockRate` reports only above a fixed threshold the game can't change
**Hidden judgement. Major.**
- **Where.** `v5-integrity.md:110-115`:
  - "reports `clockRate` … when the slope exceeds 0.006 … in 3 consecutive fits; what threshold matters is the
    game's choice";
  - "The first 30 s after join are ignored".
- **Why.**
  - The sentence says the game chooses, but the game only ever sees slopes above 0.006 that hold for 3 fits after
    30 s. Lync has already decided which drifts count.
  - The threshold equals the unmodified maximum (#5), so the gate is both a verdict and noisy.
  - The research proposed a 3% threshold (`research/client-security.md:475`); the design's 0.006 has no stated
    derivation beyond the documented bound.
- **Options.**
  - (a) Report every fit's slope as a counter, `Lync.counters(player).clockSlope`, and the fact only as "the last
    fit's slope", so the game applies its own threshold.
  - (b) Make the gate an option, `clock.reportSlope`: number, fraction per second, range 0.006–1, default chosen
    from the Studio mobile measurement. `clock.reportFits`: integer 1–12, default 3.

  Either way, list 5 s, 12 windows, 30 s and 3 × beacon in the constants table (#13).

---

## Minor

### 13. Constants live outside the constants table, and some "why" cells don't derive the value
**Incomplete options. Minor.**
- **Where.** `v5.md:673` says §4.9 lists the protocol constants, "none is a knob".
- **Not in the table:**
  - the 1/60 s client flush interval (`v5.md:727`; `f1fbfd7:src/sched/scheduler.luau:30` `CLIENT_INTERVAL`);
  - `missedFlush`'s 2 steps (`v5.md:733`);
  - the 2 s slot reuse delay (`v5-collections.md:28`);
  - the 17-frame notify ring (`v5-collections.md:107`);
  - the 10 s minimum-ping window (`v5-integrity.md:126`);
  - the beacon's 5 s, 12 windows, 0.006, 3 fits, 30 s and 3 × beacon;
  - the encoders' 4-step iteration cap (`v5.md:189`, `:201`);
  - the 1e-9 step tolerance and the 1e-6 axis tolerance (`v5.md:142`, `:163`);
  - the clients' 2^22 allowance, which is in the table.
- **"Why" cells that don't produce the value:**
  - `v5.md:685`: "tag lookahead, desync count, rekey interval | 4 frames, 8 frames, 60 s | honest gaps are 1
    frame". A 1-frame gap justifies a lookahead of at least 1. It derives none of 4, 8 or 60.
  - `v5.md:691`: "`HELLO` wait, remotes wait | 10 s each | start order and slow joins". No measured start
    time is given.
- **Stale value:** `v5.md:461`: "`columnMinRows` … (draft value 4)" against 3 in §4.9 (`v5.md:679`).
- **Replacement.**
  - One table, split into "protocol" (versioned) and "server-local" constants. Each row gets value, unit and a
    derivation or "chosen, unmeasured".
  - For example: lookahead 4 = "`FireServer` raises in a row that are reported as `frameGap`, not `tagMismatch`;
    chosen, unmeasured".
  - Delete "(draft value 4)".

### 14. Build checks without exact triggers: `rawRemotes`, `solverOff`
**Vague facts. Minor.**
- **`rawRemotes`.** `v5-tooling.md:43`: `rawRemotes = "warn"  # "off" | "warn" | "error": client code touching
  RemoteEvents directly`.
  - "Touching" isn't a trigger. The research had one: "`:FireServer`, `:InvokeServer`, `:FireClient`,
    `:FireAllClients` in project scripts" (`research/client-security-build.md:474`).
  - The research's reason for the default `warn` was a judgement: "Raw remotes elsewhere are unbudgeted entry
    points outside `Suspicion`".
  - **Replacement:** trigger = "a method call `:FireServer(`, `:InvokeServer(`, `:FireClient(`,
    `:FireAllClients(` in a scanned client or server script, outside `Packages/`". Also define the code's
    evidence (file, line, method).
  - The default should rest on a stated effect: "Calls on Lync's own remotes are refused as `tagMismatch`".
    Otherwise default it to `"off"`.
  - The `off | warn | error` scale itself is defined by effect (`v5-tooling.md:66`) and is fine.
- **`solverOff`.** `v5.md:96`: "reports `solverOff` on every runtime-path use". "Use" is undefined.
  - **Replacement:** "each call site of `Lync.server(` or `Lync.client(` in scanned scripts".

### 15. Integrity option tables: a type the wire contradicts, and missing Cost columns
**Incomplete options. Minor.**
- **`clock.beacon`.** `v5-integrity.md:121`: "number, s | 0 (off) or 0.5–1.5". It travels as "u4 tenths".
  - 0.55 can't be carried.
  - **Replace with:** "integer, tenths of a second, 0 (off) or 5–15, default 0".
- **`earlyAnswer.factor` and `maxPerViewer`.** The tables at `v5-integrity.md:132-134` and `:160-162` have no
  Cost column.
  - **Add:**
    - `earlyAnswer.factor`: "one clock read and one `GetNetworkPing` per server ask; no bytes";
    - `maxPerViewer`: "per viewer with decoys: one chunk re-encode per changed partition per flush (236 ns
      native), and the pool takes `maxPerViewer` slots out of `maxRecords`".

### 16. "At most once per window" for native reports names no window and no key
**Vague behaviour. Minor.**
- **Where.**
  - `v5.md:822-823`: "reported natively as `validatorError`, at most once per definition per window";
  - `v5.md:888`: "at most 1 per definition per window";
  - `v5.md:894`: "(≤ 1 per window)".
- **What the code did.** `f1fbfd7:src/session/inbound.luau:561-572` limited `decoderRaised` to one report per
  `observe.window` seconds per runtime, measured from the previous report. It was not per definition, and not
  aligned to the fact windows.
- **Replacement.** "at most one native report per (code, definition) per `observe.window` seconds, timed from
  that key's previous report". For `decoderRaised` and `internal` the definition is nil.

### 17. `missedFlush`: "reported once", and evidence `frames` that counts steps
**Vague facts. Minor (evidence is permanent).**
- **Where.**
  - `v5.md:733-734`: "Data pending for more than 2 `PostSimulation` steps is reported once";
  - `v5.md:926`: evidence `frames`;
  - `f1fbfd7:docs/codes/missedFlush.md`: "`frames` | the steps the data had waited".
- **Why.** "Once" is undefined: once per runtime, or once per wait? The code reset it at each flush
  (`f1fbfd7:src/sched/scheduler.luau:108`, `:120`). The evidence name says frames while it counts steps.
- **Replacement.**
  - "reported once per wait: when the 3rd consecutive step ends with data pending and no `Lync.flush()`; the
    next report needs a flush first";
  - rename the evidence to `steps`.

### 18. `sendDropped` evidence `queue` = 1 for a send that never entered a queue
**Grouped facts. Minor (evidence is permanent).**
- **Where.** `v5.md:925`: four triggers. The evidence is `queue` (1 hold, 2 limit) plus `lane`.
- **Why.** An unreliable send before `WELCOME` is never held (`v5.md:770`), yet it would be reported as `queue =
  1`, "the join hold". The four causes are recoverable only by combining `queue` with `lane`.
- **Replacement.** Evidence `cause`:
  - 1: reliable, the hold is full;
  - 2: unreliable, before `WELCOME`;
  - 3: reliable, the `limit` FIFO is full;
  - 4: unreliable, over `limit`.

  Keep `lane` and `bytes`.

### 19. Honest causes stated as vague quantities
**Vague quantities. Minor.**
- **`overBudget`** (`v5.md:912`): "a stall longer than the burst". This compares a time to a token count.
  - **Replace with:** "a reliable-lane stall of s seconds after which the client's queued frames exceed `burst` +
    `perSecond` × s (frames or bytes)".
- **`overLimit`** (`v5.md:923`): "stalls longer than the slack".
  - **Replace with:** "a stall during which the client queued more than `burst` + 2 s × `perSecond` messages of
    the definition".
- **`replayed`** (`v5.md:918`): "deep reordering".
  - **Replace with:** "reordering that delivers an unreliable frame 64 or more sequence numbers behind the newest
    received".
- **`sendDropped`** (`v5.md:925`): "heavy sends during a join".
  - **Replace with:** "more than 32,768 B of reliable sends to one namespace before its `WELCOME`".

### 20. Families claim to fix the channel, but two codes have two channels
**Grouped facts. Minor.**
- **Where.**
  - `v5.md:863-866`: "Families fix the channel … `fault` (`validatorError`, `validatorYielded`,
    `schemaMismatch` on the client)";
  - `v5.md:894`: `decoderRaised` is a native report "plus the fact";
  - `m2-plan.md:478`: "`decoderRaised` and `schemaMismatch` are family `fact`";
  - `f1fbfd7:src/diag/codes.luau:9-10`.
- **Why.** The family label stands in for the channel. For these two codes it no longer determines it, and the
  design and the plan now disagree.
- **Replacement.** In `v5.md` §7.1: "a family fixes the primary channel; `decoderRaised` (always) and
  `schemaMismatch` (on the client) are also reported natively". Move `schemaMismatch` out of the `fault` list.

### 21. Vague quantities where a number exists or should
**Vague quantities. Minor.**

| Where | Text | Replacement |
|---|---|---|
| `v5.md:25-26` | "about 4x slower `[probes T P1]`" | the measured range and the operation, from the probe |
| `v5.md:447` | "buffers of roughly 100 B and up (undocumented threshold and level)" | "threshold unmeasured; the design assumes compression from 100 B (`[compression §1]`), pending §10" |
| `v5.md:453` | "so the unknown engine level barely matters" | the measured spread across the levels modelled in `[compression §2.1]` |
| `v5.md:424-425` | "for a busy player" | the traffic model's name and its rates |
| `v5.md:688` | "each frame still acked about 8 times" | "each state frame is covered by 8 acks at one ack per 2 frames (16-bit window ÷ 2)" |
| `v5.md:872-873` | "the walk costs about 100 ns per frame" | the measured figure and its source |
| `v5.md:948-949` | "a snapshot is O(definitions) and is meant for polling at 1 Hz" | the snapshot's measured µs and bytes per definition; drop "meant for" |
| `v5-integrity.md:117`, `:121` | "About 4 B per beacon" | the exact bits: type u3, count EG0, u16, plus the segment's toc share |
| `v5-integrity.md:67` | "The build scans text." | the scan's cost per MB of client source, measured in milestone 5 |
| `v5.md:1019-1020` | "a public comparison … which v5 has to win" | the metrics (bytes/s, CPU µs per message) and the benchmark's name and version |
| `v5-extensions.md:10` | "Cells cost about 0.01 ms per pass" | keep with its citation, or give the measured range |

### 22. Extensions are named by their parts, with options that have no values
**Incomplete options. Minor.**
- **Where.** `v5-extensions.md:7-30`:
  - "cells and hysteresis", "look-ahead reveal", "`:maxHz(hz)` rounded to a divisor of `state.rate`" (`interest`);
  - "capped at a declared number of copies", "a jitter buffer of a declared depth" (`inputs`);
  - "a byte cap" (`strings`);
  - "delay max(2/rate, 0.1 s) + 2 × jitter" with jitter's estimator undefined (`interpolation`);
  - "lag-compensated hit verification" (`rewind`);
  - "schema-marked gameplay feature streams" (`telemetry`).
- **Why.** The file defers these by rule (`:4-5`). But the text reads as specification, and two items lean
  towards verdicts:
  - "hit verification" implies the library decides whether a hit is valid;
  - `checks`' "failure policy" is a consequence. That one is acceptable, because the developer declares it.
- **Replacement.**
  - Mark each unvalued option "unspecified until milestone 7".
  - Reword `rewind` to what it returns: "returns the rewound state at the client's perceived tick; the game
    decides the hit".
  - Name jitter's estimator, for example "mean absolute deviation of arrival intervals over N ticks".

---

## Taste (capped at five)

### 23. Every fact prints at Warning severity
**Hidden judgement. Taste, author decision.**
- **Where.** `v5.md:951-958`: facts go to `LogService:Warn` or `warn`.
- **Why.** That puts `frameGap`, whose cause is a raising `FireServer`, at the same Warning severity in the Error
  Report as `malformed`. The severity is the library's choice, not the developer's.
- **Options:**
  - keep it, and say so: "every fact is a warning line; severity carries no meaning";
  - or print through `print`, so the Error Report doesn't rank them.

### 24. Evidence fields that are constants
**Vague facts. Taste.**
- **Where.**
  - `desync`'s `failures` is always 8 (`f1fbfd7:docs/codes/desync.md`: "the consecutive tag failures, 8");
  - `remotesMissing`'s `seconds` is always 10.
- **Why.** A constant field carries no fact.
- **Replacement.**
  - `failures` → `sinceRekey`, the seconds since the last `REKEY` to this player, or nil;
  - drop `seconds`, or make it the time since first use when the remotes finally appear.

### 25. Threat-model vocabulary that judges
**Judging words. Taste.**
- **Where:**
  - `v5-integrity.md:85`: "**Prices** naive API drivers";
  - `v5-integrity.md:152`: "a cheat must reproduce";
  - `f1fbfd7:test/transport/mutation.spec.luau:6`: "Hostile frames";
  - `f1fbfd7:test/host/world.spec.luau:195`: `local attacker`.
- **Why.** The route names in `v5-integrity.md:16-25` (raw sender, replayer, extractor, API driver) describe
  actions, which is fine. "Naive", "cheat" and "hostile" describe intent or quality.
- **Replacement:**
  - "API drivers running at identity 8 under an unlisted chunk name";
  - "a raw-state reader must reproduce";
  - "Frames breaking each rule";
  - `local modified`.

### 26. Behaviour words that hide the behaviour
**Vague behaviour. Taste.**

| Where | Text | Replacement |
|---|---|---|
| `v5.md:637` | "an unexpected raise refuses the frame" | "any raise inside the frame's `pcall`" |
| `v5.md:668` | "a faulty server's frame" | "a downstream frame whose counts total more than 2^22 elements" |
| `v5.md:616` | "one bad chunk can't desynchronise the tail" | "one chunk breaking a rule" |
| `v5.md:756` | "asyncs are checked by thread status" | "handlers that yielded are checked by `coroutine.status` once per flush" |
| `v5.md:996-997` | "A seam with nothing registered compiles out" | the measured cost of an unregistered seam (one nil test per call?) |

---

## Shared root causes (fix once)

| Root cause | Findings | One fix |
|---|---|---|
| **A. "Honest" used as a verdict on players.** Inherited from `[client-security §1]`'s Verdict and Confidence columns. | #1, #5 ("never"), #25, the `m2-plan.md` §6 headings, the test names | Define "unmodified client" in §1; rename the column to "Known causes on an unmodified client"; rewrite the registry's Fix lines. |
| **B. A word list in place of the rule.** | #2, #11, #25 | The rule in §7.1, plus a lint over code names, evidence names and pages. |
| **C. Facts named by their action or channel ("dropped", "rejected", "report", "invalid") rather than their trigger.** | #3, #6, #10, #11, #18, #20 | One reason, or one evidence value, per trigger whose knob or cause differs. Check every table row with "can the developer choose the fix from the evidence alone?" |
| **D. Option tables without a Cost column, with unit written where type is meant.** | #7, #8, #13, #15 | One column set for every options table: Name, Type, Unit, Range, Default, Cost (a number or "unmeasured"), Wire encoding. |
| **E. Labels kept from research briefs without their definitions.** | #9 (`"release"`), #12 (beacon gate), #14 (`rawRemotes`) | When a brief's term enters the design, copy its definition with it, or write a new one. |
| **F. Honest causes written from memory, not derived from each trigger's failure modes.** | #4, #5, #19 | For each fact, list every documented failure mode that reaches its trigger: lookahead overflow, the 10 s `HELLO` hold, clones from non-replicated containers, maximum clock slew. `m2-plan.md` §6.2 should then run each listed cause; it now runs 5 of the 17. |

---

## Refused and excluded lists: reasons that are vague

Most refusals in `v5-changes.md` now rest on a stated mechanism or a measured cost. The draft-2 table rewrote
earlier reasons such as "marginal" (`:104`) and "plausible frame rate" (`:119`) into stated reasons. The
following still rest on a vague or missing reason:

1. **Reasons claimed but missing.** `v5-changes.md:302-305`: "Event `newest`; `timestamped`; … compiler plugins
   and `rans`; … the unreliable-event deadline; `:initial()`; an audience-by-field shortcut. Reasons are in the
   draft-1-to-2 tables above."
   - The tables give no reason for `rans`, the unreliable-event deadline or `:initial()`.
   - The roblox-ts transformer and compiler plugins appear only under M12 (`:36`), whose reason is the review's
     title, "Over-engineering". That is not a cost.
2. **Watermarks.** `v5-changes.md:115`: "Low-order watermarks in quantized values | Weak; visible jitter | still
   refused | Visible jitter for the honest player, and rounding removes it."
   - "Visible jitter" has no magnitude, though it is one code step of the field's declared `step`.
   - "Weak" is the earlier reason and isn't restated.
3. **Studio line.** `v5-changes.md:214`: "Rejected: a Studio line on every runtime-path start … and train people
   to ignore Lync's output."
   - A behavioural prediction, unmeasured. The first half ("Lync can't tell which solver is on, so it would print
     … new solver included") is a sufficient stated reason. Keep that half and drop the prediction.
4. **Holding later messages.** `v5-changes.md:215`: "Rejected: holding every later message behind a held one,
   which would stall all of a client's traffic for up to a second."
   - The stall is 1/`perSecond` per held message, so it is 10 s at `perSecond = 0.1`. "Up to a second" is wrong
     in general.
   - **Replace with:** "for up to `burst`/`perSecond` seconds".
5. **SARIF.** `v5-tooling.md:65`: "SARIF waits until a user asks." The exclusion rests on demand, not cost.
   - Either state the cost (one more renderer to maintain and golden-test) or keep it as a demand rule, labelled
     as one.
6. **Lute.** `v5-tooling.md:75-76`: "Lute 1.0 is not ready `[client-security-build §1.2]`." "Not ready" names no
   criterion.
   - **Give the missing capability:** for example, no `require` by path, or no stable file API, as the brief
     records it.

Nothing in the client-side table (`v5-changes.md:87-119`) rests on "too expensive" without a figure. Each
refusal there gives bytes, CPU, a platform rule or a mechanism.

---

## What is good

- **Exact facts.** The milestone 2 fact table (`v5.md:910-928`) already gives an exact trigger, an action and
  numbers-only evidence for every reason. Only the honest-cause column needs work (#4, #19).
- **Constants, not knobs.** `v5.md` §4.9 turned transport tuning into constants with a "why" column. Extend it
  (#13) rather than replace it.
- **No verbosity levels.** There are none, and `console` is a single switch. Build severity is defined by effect
  ("`error` writes no outputs"), not by rank.
- **Coalescing hides nothing.** `suppressed` is exempt from the caps and carries per-reason counts.
- **Integrity measures report and never punish.** The deletion of quiet mitigation (`v5-changes.md:116`) holds
  throughout `v5-integrity.md`.
- **Precise code text.** The built code's comments and messages, read at `f1fbfd7`, are precise. The judging and
  vague words are almost all in test names, registry Fix lines and two code names. Every `[Lync]` message in the
  registry states a requirement and a value.
