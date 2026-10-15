# Lync v5 spec: failures and observability

What Lync does when something goes wrong or needs watching: which channel each situation uses, how a
message is written, and what an observer sees. The wire refusals it reports are in [wire.md](wire.md), the
numbers in [limits.md](limits.md), and the surfaces it works through in [api.md](api.md). The id scheme and
the claim grammar are in [README.md](README.md).

Five terms. A **window** is the reporting window of a key (L-18). A **key** is a namespace together with a definition, and an event, drop
or report that has no definition is keyed by its namespace together with its reason or condition, or by its reason or
condition alone when it has no namespace. **Reportable** means every reason except
`Stale` and `CheckRaised`. A refusal of a HELLO is **final** for statuses 1, 2 and 4, for status 3 once the retry
deadline (L-24) has passed without an accept, and when the remotes are still missing after the 10 seconds of
L-20. To **discard** is to remove a block or message without a drop reason, and to **drop** is to count it under
a reason.

## 1. Behaviors that follow from the principles

| ID | Claim |
|---|---|
| F-1 | A send, an arrival, a request round trip and a collection write that all succeed on untraced definitions must produce no Output and must throw nothing. |
| F-2 | Console output about drops must not exceed one line per key per window, whatever the number of players that caused the drops. |
| F-3 | A request that ends as `Timeout`, `Unanswered`, `Left` or `Shutdown` must reach its caller as a `Result` value and must neither throw nor print. |
| F-4 | Lync must call `pcall` or `xpcall` only around the decoding of one inbound frame, around each validator and transform call, and around engine calls that a guard cannot protect. |

## 2. Declarations and callers

| ID | Claim |
|---|---|
| F-5 | A mistake in one declaration must throw when the declaration is built, not when its namespace is first used. |
| F-6 | Taking a view of a namespace whose name a different namespace table already holds in that instance must throw at the line that takes the view. |
| F-7 | A caller mistake must throw, the caller mistakes being a refused value, a member the side's view lacks, a call after `Lync.stop`, a malformed recipient and an invalid argument. |
| F-8 | A thrown declaration mistake or caller mistake must carry the position of the first frame whose source is not Lync's and that has line information, however many Lync functions, inlined or not, lie between that frame and the raise, so that a `pcall` frame is skipped. |
| F-9 | The message of a refused value must name the path into the value the user passed: the argument's name, which is `value` for `fire`, `invoke` and `Lync.check`, `record` for an insert or replace, `patch` for `update` and `reply` for a handler's return, then `.field` for a record field, `[n]` for a 1-based array position and `[key]` for a map entry, a string key in double quotes and a number key as `tostring` writes it. |
| F-10 | Indexing a member that the side's view lacks must throw a message that names the definition, the member and the side that offers it. |
| F-11 | After `Lync.stop`, a fire, an invoke, a collection write and a call that sets a handler, validator or limit on a view taken before the stop must throw. |
| F-12 | A call that is refused for any value in it must queue nothing for any recipient. |

## 3. Faults in user code

| ID | Claim |
|---|---|
| F-13 | A listener, collection signal watcher or observer that raises must be reported by the engine from its own thread with the user's own traceback, and `ScriptContext.Error` must fire. |
| F-14 | A fault in one callback must not stop Lync: the event's other listeners must still run and later events must still be delivered. |
| F-15 | Every listener, handler, signal watcher and observer must run in a thread other than the one that triggered it. |
| F-16 | A handler that raises, or whose thread ends without a reply, must make its asker's result `Unanswered` no later than the next frame of the clock after the thread ends, and the engine must report the handler's error once from the handler's own thread. |
| F-17 | A reply that fails the reply codec must make its asker's result `Unanswered` and must be reported natively from the handler's own thread. |
| F-18 | A validator or transform that raises must drop only the message that holds the value, with reason `CheckRaised`, and the later messages and blocks of the frame must still be delivered. |
| F-88 | The documentation must state that a validator or transform must not yield, and Lync must not check for a yield at run time. |
| F-19 | The report of a validator or transform fault must carry the traceback captured on the failing stack. |
| F-20 | A validator or transform fault must be reported natively, by raising its message with the captured traceback in a fresh thread, at most once per definition per window. |
| F-21 | Each `CheckRaised` drop must produce one `CheckRaised` event, subject to F-68. |
| F-22 | A validator that returns neither nil nor a string must be handled as a validator that raised. |
| F-23 | An error raised by an `encode` transform must propagate unchanged to the caller of the send. |
| F-24 | Lync must capture each definition's declaration site and each callback's registration site as `source:line` when the call is made, and the report of a validator or transform fault must name the site where that validator or transform was registered. |

## 4. Untrusted input

The reasons a message can be dropped are `Malformed`, `OutOfBounds`, `Rejected`, `RateLimited`,
`CheckRaised`, `NotAdmitted` and `Stale`.

| ID | Claim |
|---|---|
| F-25 | A dropped message must be counted in metrics under its reason and must print nothing at the moment it is dropped. |
| F-26 | Each drop whose reason is reportable must produce one `Dropped` event, subject to F-68. |
| F-27 | A decoder refusal of a frame's structure (W-94, W-95, W-97, W-106, W-107, W-21, W-125, W-131, W-136, W-137, W-152, W-156, W-73, W-194, W-197, W-203, L-26 and L-28) must drop the rest of the frame and count one drop with reason `Malformed`. |
| F-28 | A decoder refusal of a decoded value's domain (W-110, W-54, W-124, W-126, W-129 and W-157) must drop the rest of the frame and count one drop with reason `OutOfBounds`, except that a refusal under L-26 is counted as `Malformed` (F-27). |
| F-29 | A value for which a validator returns a string must be dropped with reason `Rejected`, and the string must be the `detail` of its event. |
| F-30 | A message that arrives when its player's bucket for the definition holds less than one token must be dropped with reason `RateLimited` before any validator runs. |
| F-31 | A block whose namespace slot is not admitted for its sender, a frame a client receives beyond its hold (L-12), and the unadmitted rest of a held frame at its deadline (W-204) must be dropped with reason `NotAdmitted`. |
| F-32 | A latest event block that W-147 does not accept, a LATEST block that W-165 does not accept, and a response with no pending id, must be dropped with reason `Stale`, counted in metrics only. |
| F-33 | A request that is dropped for any reason must get no response, so that its asker's result is `Timeout`. |

## 5. Schema mismatch

| ID | Claim |
|---|---|
| F-34 | A client whose HELLO ends in a final refusal must raise one error per namespace, from its own thread, that names the cause and, for a hash mismatch, the definitions that differ. |
| F-35 | A server must print at most one mismatch warning per distinct client hash per namespace, not one per client. |
| F-36 | A final refusal must produce one `Mismatch` event on the client, and a refusal with status 1, 2 or 4 must also produce one on the server. |
| F-37 | After a final refusal, the client must discard its sends on the refused namespace, count each as a `NotAdmitted` drop, and resolve each invoke on it as `Timeout` when its timeout elapses. |
| F-82 | The first status 3 a client receives for a namespace must produce one `Recovered` event with condition `NamespaceUnknown` and print one recovery warning that names the namespace and the retry deadline. |

## 6. Environment, resources and internal errors

| ID | Claim |
|---|---|
| F-38 | A client that cannot find its remotes must produce one `Recovered` event with condition `RemotesMissing`, print one recovery warning that names the namespace and the cause, retry for 10 seconds (L-20), and after those 10 seconds raise one error from its own thread and treat the namespace as finally refused with the cause `Unknown`. |
| F-39 | A block queued for a player who has left must be discarded at flush and counted in `discardedBlocks`, without throwing or printing. |
| F-40 | An engine send that raises must be caught, the frame counted in `lostFrames`, one `Recovered` event with condition `SendFailed` produced, and at most one recovery warning printed per window for that condition. |
| F-41 | A message demoted to the reliable lane (W-62) must produce one `Recovered` event with condition `Oversize`, increment its definition's `oversize` counter, print at most one recovery warning per window for that condition, and never throw while it fits L-8. |
| F-42 | A flush with a budget that leaves blocks queued must produce one `Pressure` event per namespace with condition `Backlog` and the number of queued blocks as `amount` (provisional M-9). |
| F-43 | An invoke that must wait because no request id is free, ids in the quarantine of W-79 included, must produce one `Pressure` event with condition `Requests` and the pending count as `amount`. |
| F-44 | A private function of Lync that finds its own invariant broken, as a test of that module can make it by calling it with a state its contract forbids, must throw a message of the internal-error mold (F-54). |
| F-45 | An unexpected error while decoding a frame, as a test of the decoder can cause with an internal codec node that raises outside any validator or transform call, must be counted as one `Malformed` drop and reported natively as an internal error at most once per namespace per window. |

## 7. Mechanisms

| ID | Claim |
|---|---|
| F-46 | A failure while decoding a frame, whether a refusal or an unexpected error, must end the decoding of that frame without raising an error to the engine. |
| F-47 | Lync must use `assert` only for its own invariants, with literal messages, and must check a user's arguments with guards that raise through F-8. |
| F-48 | Expensive consistency checks must exist only in the test build, and cheap invariant checks in every build. |

## 8. Message grammar

| ID | Claim |
|---|---|
| F-49 | Every message that Lync throws or prints must begin, after any position prefix, with the marker `[Lync] `. |
| F-50 | A caller-mistake message must be the marker, the subject, `must` and the requirement, `, got ` and the value, and optionally `; ` and a fix. |
| F-51 | A declaration-mistake message must be the marker, the subject, `must` and the requirement, and `, got ` and the value, the subject being the codec or function being declared when no definition exists yet. |
| F-52 | A recovery message must be the marker, `could not ` and the action, `; ` and what happens instead, and `: ` and the cause. |
| F-53 | A drop-summary message must be the marker, the definition (`frames` when the drops have none), `dropped N values from P players in the last W s: ` and the reasons with their counts in descending order of count, ties by reason name, each reason written as lowercase words, with `value` and `player` singular when their count is 1. |
| F-54 | An internal-error message must be the marker, `internal error: `, the broken invariant and a request to report it with the trace. |
| F-84 | A mismatch error must be the marker, `namespace `, the quoted namespace name, ` does not match the server: `, the cause as lowercase words and, for a hash mismatch, `; differing definitions: ` and their names separated by `, `. |
| F-85 | A pressure warning must be the marker, the quoted namespace name, ` is under pressure: `, the condition as lowercase words, `, ` and the amount. |
| F-86 | A fault report must be the marker, the definition, ` validator ` or ` transform `, `registered at `, the site, ` raised: ` and the message, followed by the traceback on the lines after it. |
| F-93 | A server mismatch warning must be the marker, `namespace `, the quoted namespace name, ` does not match a client: `, the cause as lowercase words and, for a hash mismatch, `; differing definitions: ` and their names separated by `, `. |
| F-87 | A trace line must be the marker, `trace `, the definition, ` sent ` or ` received `, the size, being the block's bits divided by 8 and rounded up, and ` B`, ` to ` or ` from `, the peer's name (`server` on a client), `: ` and the decoded value. |
| F-92 | A traced send to several recipients must print one line for each recipient. |
| F-55 | A message must be one line, except for a traceback attached to a fault report. |
| F-56 | A message's subject must be the user's own names, written `Definition:method` with the path into the value where one applies, or, for a mistake made before any definition exists, the name of the codec or function, such as `integer`. |
| F-57 | Text that comes from outside Lync's own wording, such as a name received from a peer, must be quoted with its control characters escaped, so that the message stays on one line, and a value of the wrong type must be reported by its type. |
| F-58 | A message must carry no code or tag other than the marker. |
| F-59 | Every message must be built from one table of templates. |

## 9. Observability

| ID | Claim |
|---|---|
| F-60 | An observer must receive each event as a frozen table whose `kind` is `Dropped`, `CheckRaised`, `Recovered`, `Mismatch`, `Pressure` or `Suppressed`. |
| F-61 | A `Dropped` event must have `namespace` and `definition` (each nil when the drop cannot be attributed), `player` (nil on a client), `reason` (`Malformed`, `OutOfBounds`, `Rejected`, `RateLimited` or `NotAdmitted`), `path` (nil when none), `detail` (nil unless the reason is `Rejected`) and `count`, the number of messages it stands for. |
| F-62 | A `CheckRaised` event must have `namespace`, `definition`, `player` and `message`. |
| F-63 | A `Recovered` event must have `condition` (`RemotesMissing`, `NamespaceUnknown`, `Oversize` or `SendFailed`), `namespace`, `definition` (nil when none) and `detail`. |
| F-64 | A `Mismatch` event must have `namespace`, `cause` (`Hash`, `Version`, `Unknown` or `Full`, for statuses 1 to 4 of W-180), `definitions` (the names of the receiver's own differing definitions, ascending) and `unmatched` (the number of the peer's definitions with no local match). |
| F-65 | A `Pressure` event must have `condition` (`Backlog` or `Requests`), `namespace`, `definition` (nil for `Backlog`) and `amount`. |
| F-66 | A `Suppressed` event must have `namespace` (nil when unknown), `key`, which is a definition name, a reason or a condition within that namespace, and `count`, the number of events withheld. |
| F-67 | The values of `reason`, `condition` and `cause` must be members of closed sets that the types express as singleton unions. |
| F-68 | Lync must deliver at most 16 events per key per window (L-19), withhold and count each excess event, and at the close of the window produce one `Suppressed` event carrying the count. |
| F-69 | Each observer must run each event in its own thread, so that an observer that raises or yields does not affect Lync or another observer. |
| F-70 | `Lync.observe(observer)` must return a Connection, and after its `disconnect` the observer must receive no event. |
| F-71 | The console must be built in and must read the uncapped counters rather than the capped events of F-68. |
| F-90 | `Lync.configure({ console = false })` must disable the console. |
| F-72 | The console must print through `LogService:Warn` with a template and a context, and the printed text must be the filled template. |
| F-73 | A console template must begin with the marker and hold placeholders, and its context must hold the definition, the counts and the reasons and, when a summary covers one player, that player's name and UserId, never a Player instance. |
| F-74 | The console must print one drop summary per key at the close of each window that held reportable drops. |
| F-83 | The counts of a drop summary, being the number of values, the number of players and the count of each reason, must cover every reportable drop of the window, including those whose events F-68 withheld. |
| F-75 | The console must print each recovery and pressure warning at its first occurrence per key per window, and count later occurrences in that window without printing. |
| F-76 | `Lync.metrics()` must return a frozen table with `namespaces`, a table keyed by namespace name whose entries have `queuedBlocks`, `queuedBits`, `flushedBits` and `definitions`, a table keyed by definition name whose entries have `messagesSent`, `messagesReceived`, `bitsSent`, `bitsReceived`, `oversize` and `drops`; with `unattributed`, whose `drops` counts the drops that have no definition; and with `discardedBlocks` and `lostFrames`; every `drops` table must map each of the seven reasons to its count. |
| F-89 | `Lync.metrics()` over several instances must sum each counter across them (A-16). |
| F-91 | `messagesSent` and `messagesReceived` must count single messages, a send to several recipients counting once for each recipient. |
| F-77 | With `profile` enabled, Lync must wrap the flush, encode and decode of each namespace in `debug.profilebegin` and `debug.profileend` under labels that begin with `Lync`, and the test build must enable it. |
| F-78 | Lync's threads must set the memory category `Lync` with `debug.setmemorycategory` and must reset it with `debug.resetmemorycategory` before they run user code. |
| F-79 | A traced definition must print, in any environment, one line of the mold of F-87 per send and per arrival, and tracing must be the only place Lync prints during normal operation. |

## 10. Results

| ID | Claim |
|---|---|
| F-80 | A request's result must be `{ ok = true, value = reply }` or `{ ok = false, reason = ... }` with `reason` one of `Timeout`, `Unanswered`, `Left` and `Shutdown`, and a failed result must carry no other field. |
| F-81 | The `reason` text of a failed `Lync.check` must equal the thrown message of a refused `fire` of the same value once its position prefix, its marker and its `Definition:method` subject are removed. |
