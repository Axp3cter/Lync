# Lync v5: failures and observability

A design for everything that goes wrong or needs watching: errors, warnings, printing, asserts,
protected calls, the debug library, logging, metrics. It starts from who needs the information, not
from v4. Status: proposal for review. Names are placeholders until the naming design.

Platform behaviour this design relies on was checked in Studio on 2026-10-02 (§9).

## 1. Who needs what

| Audience | When | Needs |
|---|---|---|
| The developer writing code | Studio, while building | Immediate feedback on misuse: what is wrong, the line in their code, how to fix it |
| The developer running a live game | Production | Low-noise, aggregated, structured reports that a client cannot flood |
| The program itself | Runtime | Machine-readable outcomes for expected failures, to branch on with exact types |
| Lync maintainers | Tests, bug reports | Invariant checks and internal detail, hidden from users |
| An exploiter | Any time | Nothing: they must not be able to cause floods, CPU spikes or leaks |

## 2. Principles

1. **Every situation has exactly one channel.** §3 lists every situation, the channel it uses, and the
   test that proves it. A situation without an entry is a design bug.
2. **Errors point at the user's line.** A thrown error's position is the frame in user code that
   caused it, found at raise time (§4.1), never computed by hand.
3. **Lync never runs user code on its own stack.**
   - Listeners, watchers, responders, completions and observers each run in their own thread. The
     engine reports their errors natively, with the user's own traceback and clickable lines, and
     `ScriptContext.Error` fires, so the user's error analytics see them.
   - A failing callback cannot corrupt Lync's state or stall it.
   - The only exceptions are validators and transforms, which must run inside decode (§4.3).
4. **Silent in normal operation.** Lync prints nothing while things work. Console output is reserved
   for what needs a developer's attention, and it is bounded per time window regardless of how many
   players there are.
5. **Expected failures are values.** Outcomes such as a timed-out request are typed results, never
   thrown and never printed.
6. **Structure for code, text for people.** Code reads typed fields. Message text follows one grammar
   (§5) and is never parsed.
7. **Only real boundaries are protected.** `pcall` exists only where a failure from outside Lync must
   be turned into a value (§4.4). Nothing is wrapped to silence or to re-log.

## 3. Situation catalogue

| # | Situation | Example | Channel |
|---|---|---|---|
| 1 | Mistake in one declaration | `int(5, 1)`, `:newest` on a packet field, a set key of the wrong kind | Throw at the declaration line. Checks run eagerly when the declaration is built, not deferred to a later start. |
| 2 | Mistake across declarations | Duplicate namespace, a name used twice | Throw at the line that registers the namespace |
| 3 | Caller mistake at a call | Wrong value (with its path), the other side's call, a call after close, a malformed recipient, a bad timeout | Throw at the caller's line (§4.1) |
| 4 | Fault in a user callback | A listener, set watcher, observer or request completion raises | Own thread; the engine reports it natively. Lync continues. |
| 5 | Fault in a responder | A query responder raises | Own thread, reported natively. Lync sees the thread die (status `dead` without a reply) and answers the asker `Unanswered`. |
| 6 | Fault in a validator or transform | `:validate` or `:as` raises during decode | Caught (§4.3). The value is dropped with reason `CheckRaised`, and the fault is reported once per definition per window, with the captured user traceback. |
| 7 | Untrusted input rejected | Malformed bytes, out-of-bounds value, validator returns a reason, rate limit exceeded | No per-event output. Counted in metrics; one typed event to observers (bounded); a bounded console summary per window (§6). |
| 8 | Expected outcome | A request times out, the other side leaves, shutdown, no responder | A typed result to the caller |
| 9 | Schema mismatch | Client and server were built from different schemas | Client: one error naming the definitions that differ. Server: one warning per distinct mismatch, not per client. This needs per-definition hashes in the handshake. |
| 10 | Engine or environment failure | Remotes missing, a player leaves mid-send, the engine drops an oversized unreliable call | Prevent by guards where possible; otherwise one warning in the recovery mold per condition per window |
| 11 | Resource condition | State backlog growing past the budget, request cap reached, queues long | Metrics and an observer event; one console warning per condition per window |
| 12 | Internal invariant broken | A Lync bug | Throw `[Lync] internal error: …` asking for a report. Cheap checks ship; expensive ones exist only in the test build. |

## 4. Mechanisms

### 4.1 Finding the user's line

**The problem** (checked in Studio). Luau inlines local functions within a module, so a helper's frame
can vanish. A hand-computed `error(message, 2)` from an inlined helper landed on `pcall`, which has no
line, and the message lost its position. The same call from a non-inlined table function pointed at
the caller correctly.

**The fix: one internal raise function** that walks `debug.info` from its own frame. The first frame
whose source is not Lync's is the user's frame. It raises with that level. Since Luau inlines only
within a module, Lync code is never inlined into user code, so this holds however much inlining
happens. Lync's source prefix is captured once at load, and in the single-file build every Lync frame
shares one source, which makes the comparison trivial. The walk costs nothing that matters, because it
runs only when raising.

**Positions captured for later.** A definition's declaration site, and the site where a callback was
registered, are captured with `debug.info` when the call happens. Later reports can name them, for
example "listener for `Chat` registered at `Combat:42`".

### 4.2 Threads

- Every user callback is resumed in its own pooled thread. An error kills only that thread. The engine
  prints it with the user's frames and fires `ScriptContext.Error`. Lync replaces dead threads in its
  pool.
- **Responders.** Lync records the reply when the responder returns. If the thread is `dead` without a
  reply, the asker receives `Unanswered`. No `pcall` is needed, and the user's error is reported where
  it happened.
- **Spawner context.** `task.spawn` starts a fresh stack (research §3.4), so a callback's traceback
  shows only the callback. That is the right frame for a fault in the callback. For faults that belong
  to the code that triggered work, the trigger site is captured at call time (§4.1).

### 4.3 Validators and transforms

These run synchronously inside decode, because their result decides whether a value is accepted.

- Each call is protected with `xpcall`, whose handler captures `debug.traceback` on the failing stack.
- On a raise, the value is dropped with reason `CheckRaised`, and decode continues with the rest of the
  frame. v4 lost the whole frame here.
- The fault is reported natively, by raising the message with its captured traceback in a fresh
  thread, once per definition per window. A broken validator that fails on every packet produces one
  report per window, not thousands.

### 4.4 Protected calls

| Where | Why |
|---|---|
| Around decoding one inbound frame | Untrusted bytes: any failure, including a Lync bug, becomes a counted drop for that frame instead of an unhandled error. One protected call per frame, never per field. |
| Around each validator and transform call | §4.3 |
| Around engine calls that can fail for outside reasons | Only where a guard cannot prevent the failure |

**Not protected:**
- listeners and responders (§4.2);
- writes of values the caller passed in, because a refusal is a caller mistake (§3 row 3).

How a write refusal reaches the caller is a measured choice: a writer that returns a failure, or one
protected call at the public boundary. Either way the error lands on the user's line with the value's
path.

### 4.5 Asserts

- `assert` states Lync's own invariants only, with literal messages (skill rule). Arguments from users
  are checked by guards that raise through §4.1, never by `assert`.
- **Build variants** (darklua `inject_global_value` plus `remove_unused_if_branch`):
  - cheap invariant checks ship in every build;
  - expensive consistency checks (whole-store audits, cross-structure invariants) exist only in the test
    build.

## 5. Message grammar

One grammar for every message Lync prints or throws: the skill's molds plus a source marker, a
deliberate deviation recorded in the goals.

| Kind | Mold | Example |
|---|---|---|
| Caller mistake | marker, subject, `must` requirement, `, got` value, optional `; ` fix | `[Lync] Chat:fire value.items[3].count must be a whole number from 0 to 99, got 120` |
| Declaration mistake | marker, subject, `must` requirement, `, got` value | `[Lync] int bounds must be in order, got 5 to 1` |
| Recovery | marker, `could not` action, `; ` what happens instead, `: ` cause | `[Lync] could not find remotes for "combat"; retrying for 10 seconds: ReplicatedStorage has no Lync folder` |
| Drop summary | marker, subject, counts, top reasons | `[Lync] Damage dropped 412 values from 3 players in the last 30 s: 400 out of bounds, 12 rate limited` |
| Internal error | marker, `internal error:`, invariant, report request | `[Lync] internal error: a slot was freed twice; please report this with the trace` |

**Rules:**
- **One line**, except the traceback attached to a fault.
- **The subject** is the user's own names: `Definition:method`, plus the path into the value.
- **Text from outside is quoted.** A value of the wrong type is reported by its type.
- **No codes or tags** other than the marker. Codes live in structured fields (§6).
- **Fix hints** appear only where the likely fix is known. For example: "`str` bounds are byte lengths;
  for a fixed set of strings use …".
- **One message table.** Every message is built from one table of templates, so tests can check
  wording and docs can list every message.

## 6. Observability

**One typed event stream** replaces v4's `kind, message, data` triple.

- Observers receive frozen events from a tagged union, for example:
  - `{ kind: "Dropped", definition, player, reason, path, count }`
  - `{ kind: "CheckRaised", definition, player, message }`
  - `{ kind: "Recovered", condition, detail }`
  - `{ kind: "Mismatch", definitions }`
  - `{ kind: "Pressure", condition, amount }`
- **Exact types.** `reason` and `condition` are singleton unions, so user code branches on them and the
  checker catches a missing case.
- **Bounded.** Events per definition per window are capped; the overflow becomes one summary event. A
  client cannot make observers work harder than the cap allows.
- **Isolated.** Observers run in their own threads (§4.2).

**The console** is one built-in observer, which the user can disconnect.
- It prints drop summaries at most once per definition per window, plus recoveries and pressure
  warnings, each through `LogService` structured logging.
- Templates carry the marker and placeholders. The context holds the definition, a player's name and
  UserId (never the Instance, which `LogService` fails to serialize), counts and reasons.
- In live games this groups Lync's reports by template in the creator analytics.
- Whether the console prints drop summaries in live servers by default, or only in Studio, is open
  (§10).

**Metrics**, always on and cheap:
- per-definition counters for messages and bytes in and out, drops by reason, rate-limit hits;
- per-namespace queue depth, budget use and backlog;
- readable through an API, so users can build their own panels.

**Profiling and memory.**
- `debug.profilebegin/profileend` labels around flush, encode and decode per namespace, so Lync's
  cost is visible in the MicroProfiler. Opt-in in release, always on in the test build.
- Lync's threads set `debug.setmemorycategory("Lync")` (checked: available), so Lync's memory shows
  under its own name in the Developer Console.

**Tracing**, opt-in at runtime: a definition can be traced to print each send and arrival, with the
decoded value, its byte size and the peer. This is the one place Lync uses `print`.

## 7. Results

- **Requests** resolve to a `Result`:
  `{ ok: true, value: Reply } | { ok: false, reason: "Timeout" | "Unanswered" | "Left" | "Shutdown" }`.
  This applies to both the yielding client form and the server form's completion.
- **Checking a value** against a codec without sending it returns the same `Result` shape, with the
  failing path and requirement. Users validate without `pcall`, and the reason text matches what a send
  would throw.

## 8. Changes from v4

| v4 | v5 |
|---|---|
| Errors raised at level 0, carrying no position | Raised at the user's frame, found by walking `debug.info` |
| Hand-computed levels (fragile under inlining) | None; the frame walk replaces them |
| Listener and responder faults caught with `xpcall` and re-printed through `warn` | Native engine errors in the callback's own thread |
| A throwing validator or transform killed the rest of the frame, logged as malformed input | Caught per call; only that value is dropped; one native report per definition per window |
| `onLog` listener errors uncaught on Lync's stack | Observers in their own threads |
| `kind, message, data` records with untyped `data` | A typed event union, frozen, bounded |
| Drop warnings capped per player (8 per code per 10 s), so many players still flood | One summary per definition per window, whatever the player count |
| Console prints every record through `warn` with `[lync] file:line` | Silent unless attention is needed; LogService templates with context |
| Request outcomes as `ok, reply, detail` | A typed `Result` |
| Schema mismatch reported as two hashes | The names of the definitions that differ |
| Many schema errors deferred to `start` | Raised at the declaration line, eagerly |
| No metrics, profiler labels or memory category | All three |

## 9. Platform checks behind this design

All run in Studio through the MCP on 2026-10-02 (Edit DataModel, Windows):

- **Native callback errors.** An error inside a `task.spawn` thread was printed by the engine with the
  user's frame (`Script 'AssistantCommand', Line 5 - function userListener`), and the thread's status
  became `dead`.
- **Inlining breaks levels.** `error(message, 2)` from an inlined local helper carried no position
  (level 2 landed on `pcall`). From a table function it carried the caller's line. `debug.info` showed
  the inlined helper's frame missing.
- **Memory category.** `debug.setmemorycategory` and `debug.resetmemorycategory` are available.
- **Structured logging.** `LogService:Warn(template, context)` prints the filled template.
  `LogService:GetLogger` is not yet available.

## 10. Open questions

1. Whether the console prints drop summaries in live servers by default, or only in Studio.
2. How a write refusal reaches the caller: a failure return, or one protected call at the boundary.
   This is decided by measuring the hot path.
3. The window length for summaries and per-definition event caps.
4. The exact form of the source marker.
5. Whether tracing is allowed in live games, or only in Studio.
