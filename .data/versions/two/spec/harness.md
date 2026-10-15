# Lync v5 spec: test harness

The machinery that tests and benchmarks run on: the property engine, the assertions, the simulated engine, the
reporting and the statistics. Its claims are proved by self-tests of the harness before any module of Lync uses
it. The id scheme and the claim grammar are in [README.md](README.md).

Four terms. A **tape** is the list of words that replay the draws of a `RandomSource`: a word drawn as
such is recorded as it is, and a bounded draw, such as an integer or a boolean, records the value reduced to its
range, not the raw word. A **fate** is the list of delays, in
seconds from the send, at which copies of a frame are delivered. A **World** is the in-process engine of
[api.md](api.md) §2, built from a transport, a clock and a roster. A **profile** is `quick`, `standard` or
`deep`.

## 1. Random source and properties

| ID | Claim |
|---|---|
| H-1 | `RandomSource` must be xoshiro128** seeded through SplitMix32 on `bit32` alone, so that one seed gives one draw sequence on every host. |
| H-16 | A `RandomSource` must record each draw on its tape, a word as it is and a bounded draw as the value reduced to its range, and one built from a tape must replay those words and then give zeros. |
| H-56 | A replaying `RandomSource` must give at most 4096 zeros past the end of its tape and must refuse the 4097th, to stop a runaway read. |
| H-2 | The shrinker must return a failing tape no longer than its input and not later than it in shortlex order, using at most 1000 property calls, or 10000 at the `deep` profile. |
| H-57 | On the decoupled probe properties, which test each word on its own, the shrinker must reach the shortlex minimum within the call bound of H-2. |
| H-58 | On the coupled probe property, two integers from 0 to 100 that fail when their sum is 100 or more, the shrinker's redistribution pass, which moves weight between pairs of words, must reach the tape `{100}`, which replays as the values 100 and 0 because a read past the tape's end gives zero, within 100 property calls. |
| H-3 | A property failure must report the seed, the case number, the shrunk tape as a Luau literal, a replay line `filter=<id> tape={...}`, and the message and traceback of the shrunk case. |
| H-18 | A property must run 300 cases at the `standard` profile, a tenth of that at `quick` and 20 times that at `deep`, each seeded from the run seed, the test id and the case number so that one case replays alone. |
| H-19 | The run order must be shuffled with the run seed. |
| H-36 | The default run seed must be `0x4C796E63`. |

## 2. Assertions, verdicts and taps

| ID | Claim |
|---|---|
| H-4 | `equals` must compare structurally, with NaN equal to NaN, `-0` different from `0`, buffers byte by byte and datatypes by component. |
| H-5 | An assertion failure and any other error must be different verdicts, `Failed` and `Crashed`. |
| H-21 | A test's verdict must be `Passed`, `Failed`, `Crashed`, `TimedOut` or `Skipped`. |
| H-37 | A pair test whose clients do not arrive within 30 seconds must be `Skipped`, carrying the reason, never `Passed`. |
| H-126 | A skipped test may carry the reason it was skipped, and a reason that it carries must appear in its outcome in the report. |
| H-127 | A report must hold at most one outcome for each pair of a test id and a DataModel. |
| H-20 | A test body that runs longer than 5 seconds, or 30 seconds in a live test, must be marked `TimedOut`. |
| H-6 | An uncaught error that a test did not claim must fail the test. |
| H-22 | Lync output that a test did not declare with `check:expectOutput` must fail the test. |
| H-24 | A suite declaration with an empty claim list must throw. |
| H-25 | A test title must be unique within its suite. |
| H-38 | The harness must call `Lync.stop()` after each test, so that no instance outlives its test. |
| H-39 | `throws(action, expectation)` must fail unless the action throws. |
| H-40 | `throws` must fail unless the position of the thrown error names the test's own file. |
| H-41 | `throws` must compare the subject and path the user wrote with the thrown text, not the wording of the message. |
| H-42 | `includesEvent(recorder, expected)` must pass only when the recorder holds an observer event whose `kind` and every given field equal those of `expected`, and must never compare message text. |
| H-43 | `excludesEvent(recorder, expected)` must pass only when the recorder holds no such event. |
| H-44 | `matchesGolden(name, value)` must fail unless `value` equals the golden stored under `name`. |
| H-45 | A `matchesGolden` mismatch on a string or buffer golden must print the first differing index with a hex window. |
| H-132 | A `matchesGolden` mismatch on any other golden must report the path to the first difference, as in `golden "tbl"[3] must equal 3, got 4`. |
| H-46 | A `matchesGolden` mismatch must record an update candidate. |
| H-47 | `world:expectFault(pattern)` must let a test claim an uncaught error whose message matches `pattern`, so that H-6 does not fail it. |

## 3. Simulated engine

| ID | Claim |
|---|---|
| H-7 | On the unreliable lane a fate must decide delivery: `{}` loses the frame, `{0}` delivers it once, `{0, 0.05}` delivers it twice and `{0.2}` delays it, and a later frame given a smaller delay must overtake an earlier one. |
| H-118 | A delay of 0 must deliver at the next `advance` and never inside `send`, on every lane. |
| H-17 | Under any fate the reliable and handshake lanes must deliver each frame exactly once, at the earliest delay of its fate, or at the next `advance` for an empty fate, and not before every earlier frame on the same connection has been delivered. |
| H-8 | One seed and one plan must give one delivery trace. |
| H-26 | The simulated transport must drop, and count, an unreliable frame longer than `985 - 6 * I` bytes, `I` being its instance arguments (L-7). |
| H-9 | `Timeline` must fire due callbacks in (time, insertion) order and skip none. |
| H-50 | `Timeline.advance(duration)` must fire what falls due within `duration` and then leave `now()` `duration` later. |
| H-51 | `Timeline.delay(seconds, callback, ...)` must schedule the callback `seconds` after `now()`. |
| H-117 | A timer of 0 seconds must run in the next `advance` and never inside `delay`. |
| H-115 | The `frame` signal of a simulated clock must fire every 1/60 second of simulated time with that duration as its argument, after every timer that is due at the same instant. |
| H-116 | `Timeline.new(frameDuration)` must throw unless `frameDuration` is a finite number above 0. |
| H-31 | A `World` must run its server view and its client views in one DataModel. |
| H-33 | `world:advance(duration)` must move virtual time and deliver what falls due. |
| H-34 | `world:server()` and `world:client(player)` must return the seams record (A-10) of one endpoint. |
| H-35 | A repeated `world:server()`, and a repeated `world:client(player)` for one player, must return the same record. |
| H-119 | `World.new` given `fates` and no `plan` must draw each frame's fate with `fates`, in the order the frames are sent, from a `RandomSource` seeded with the world's `seed`. |
| H-120 | Two worlds given the same `seed` and the same `fates` must give the same fate to each frame of the same sequence of sends. |
| H-121 | `World.new` must throw when it is given both a `plan` and `fates`. |
| H-122 | `World.new` given neither a `plan` nor `fates` must give every frame the perfect fate `{0}`. |
| H-123 | `World.new` must throw unless `seed` is a whole number from 0 to 4294967295. |
| H-48 | `Roster` must fire its `added` signal when a stand-in player joins and its `removing` signal when one leaves. |
| H-49 | A stand-in player must have a `Name` and a `UserId`. |

## 4. Reporting, claims and coverage

| ID | Claim |
|---|---|
| H-13 | A reader must reassemble a report from its Output lines whatever their order and however often a line is repeated. |
| H-59 | A report line must be `[LyncReport:<run>] <i>/<n> <crc> <piece>`, where `<run>` is the run id, `<i>` the chunk index, `<n>` the chunk count, `<crc>` the checksum and `<piece>` a piece of the payload, each separated as shown by one space. |
| H-60 | The run id must be 8 lowercase hexadecimal digits and must be the same on every line of one report. |
| H-61 | The chunk index `<i>` must run from 1 to `<n>`, the number of lines of the report, both written in decimal without leading zeros. |
| H-62 | The payload must be the standard base64 (RFC 4648 section 4, with `=` padding) of the UTF-8 bytes of the report's JSON, whose schema is that of `scripts/project/Reports.luau`. |
| H-63 | The base64 text must be cut into pieces of 3900 characters, the last one shorter, and line `<i>` must carry the `<i>`-th piece. |
| H-64 | A report line must be at most 4000 characters long, its prefix included. |
| H-65 | The checksum must be the CRC-32 of the UTF-8 bytes of the report's JSON, with the reflected polynomial `0xEDB88320` (`0x04C11DB7` unreflected), the initial value `0xFFFFFFFF` and a final exclusive-or with `0xFFFFFFFF`, written as 8 lowercase hexadecimal digits, and it must be the same on every line. |
| H-66 | A reader must accept a report as complete only when it holds every line from 1 to `<n>` of one run id and the CRC-32 of the reassembled JSON equals the checksum on those lines. |
| H-67 | A reader must report a report that lacks a line as truncated, naming the missing lines, and one that holds every line but fails its checksum as corrupt. |
| H-68 | A reader must ignore a line that does not match the line form and must keep the lines of different run ids apart. |
| H-69 | A reader must report a report as corrupt when its lines disagree on `<n>` or on the checksum, or when two lines repeat an index with different pieces. |
| H-70 | When the POST of a report to the local receiver fails, the harness must print the report to Output in this format. |
| H-128 | The harness must not print the report lines to Output when the POST of the report has succeeded. |
| H-14 | `claims` must find an uncited claim, an unknown tag and an unmarked type error. |
| H-23 | `judge` must give each claim of the kinds Tested and Scripted one of the states `Proved`, `Failing`, `Untested`, `Skipped` and `Waived`, and a skipped test must prove nothing. |
| H-129 | A claim of the kind Typed, Inferred or Declared must be reported `Proved` when the diagnostics of its type run match its notes, `Failing` when they do not, and `Untested` when no file marks it. |
| H-130 | A claim of the kind Reviewed must be reported as `Reviewed`, needing no citing test, and a claim of the kind Waived as `Waived` with its recorded reason. |
| H-15 | The coverage gate must refuse a module whose line count differs from its file's, and an exclusion whose text no longer matches exactly one line of its file. |
| H-29 | The coverage gate must fail a module while any executable line of it is uncovered and not excluded. |
| H-30 | `judge` must exit 0 for a `Pass` ruling, 1 for `Fail` and 2 for `Incomplete`. |
| H-124 | The ruling on a report must be `Fail` when a test failed, crashed or timed out or a problem was found, and otherwise `Incomplete` while any claim is `Skipped` or when no claim is `Proved`, and otherwise `Pass`. |
| H-125 | A report that lacks a claim which a file under `test/` cites must not be ruled `Pass`, because another build made it. |
| H-131 | A report of a run with a filter, or of a run in which a planned work item did not report, must give no claim a state. |
| H-52 | `buildId` must be a hash of the sorted test ids and `VERSION`. |
| H-53 | A client whose `buildId` differs from the server's must stop the run and name the stale side. |

## 5. Measuring

| ID | Claim |
|---|---|
| H-10 | `Statistics` must return the known values on fixed inputs for the median, the MAD, a 95% bootstrap interval of the median from 2000 resamples seeded from `RandomSource`, and Tukey outliers at 1.5 and 3 times the IQR, flagged and kept. |
| H-11 | On a virtual clock, `Sampler` must size each batch to last at least the larger of 10 ms and 1000 times the smallest nonzero clock step measured over 10000 calls. |
| H-32 | `Sampler` must end warm-up after at least 3 batches once two consecutive batch medians agree within 5%, and after at most 30 batches. |
| H-12 | `Comparisons` must say `same` for equal samples and `slower` for a clear shift, and must never gate on noise. |
| H-27 | `Comparisons` must call a row `slower` or `faster` only when the Mann-Whitney p-value is below 0.05 and the change exceeds the larger of 3% and twice the half-width of the baseline's interval, and `same` otherwise. |
| H-28 | `Comparisons` must refuse a comparison across baseline keys and must give the reason. |
| H-54 | A bench row's payload and estimated bytes must be compared with the baseline exactly, and any increase must fail unless the baseline is updated on purpose. |
| H-55 | A bench row tagged `gate` must fail when it is `slower`. |

## 6. Generators

A **generator** is a function from a `RandomSource` to a value, as `Generators` builds them. A claim that
values are "each as likely as another", or in proportion to a weight, is tested by counting a seeded run of at
least 40000 draws and requiring each count to lie within 4 standard deviations of its expected count `n * p`,
a standard deviation being `sqrt(n * p * (1 - p))` for `n` draws and a probability `p`.

| ID | Claim |
|---|---|
| H-71 | A value that a generator gives must be rebuilt by replaying the tape that its source recorded: a source made from `source:tape()` must make the same generator give a structurally equal value. |
| H-72 | A value argument of a combinator that is out of range, or a list argument that is empty, must throw where the generator is built, not where it first draws. |
| H-73 | `array` must throw when built unless `minLength` and `maxLength` are whole numbers in order and `minLength` is 0 or more. |
| H-74 | `choice`, `oneOf` and `frequency` must throw when built with no values, generators or entries. |
| H-75 | `frequency` must throw when built with a weight that is not a whole number of at least 1, or with weights that total more than 2^53. |
| H-76 | `integer` must throw when built unless its bounds are whole numbers in order that are at most 2^53 - 1 apart. |
| H-77 | `number` must throw when built unless its bounds are finite and in order and their difference is finite. |
| H-78 | `recursive` must throw when built unless `maxDepth` is a whole number of 0 or more. |
| H-79 | `array(element, minLength, maxLength)` must draw its length from `minLength` to `maxLength` first and then that many elements from `element`. |
| H-80 | `integer(min, max)` must give a whole number from `min` to `max`, each as likely as another. |
| H-81 | `number(min, max)` must give a number that is not below `min` and not above `max`, at the resolution of 53 bits. |
| H-82 | `boolean` must give `true` or `false`, each as likely as the other. |
| H-83 | `choice(values)` must give one of `values`, each as likely as another. |
| H-84 | `oneOf(generators)` must pick one of `generators`, each as likely as another, and give what it draws. |
| H-85 | `frequency(entries)` must pick an entry with a likelihood in proportion to its weight and give what that entry's generator draws. |
| H-86 | `choice`, `oneOf` and `frequency` must use a copy of their argument taken when they are built, so that a later change to the argument does not change what they give. |
| H-87 | `constant(value)` must give `value` and draw nothing. |
| H-88 | `map(generator, transform)` must give `transform` applied to the value that `generator` draws, and draw nothing more. |
| H-89 | `bind(generator, build)` must draw a value from `generator` and then draw from the generator that `build` makes from it. |
| H-90 | `filter(generator, shouldKeep)` must give the first drawn value that `shouldKeep` accepts, drawing again after each value it rejects. |
| H-91 | `filter` must fail the case with an error when it has drawn 100 values and `shouldKeep` has accepted none. |
| H-92 | `record(shape)` must give a table with the field names of `shape` and the value that each field's generator draws, drawing the fields in ascending order of their names whatever order `shape` is traversed in. |
| H-93 | `recursive(leaf, grow, maxDepth)` must draw a depth from 0 to `maxDepth` first and then draw from `leaf` grown that many times. |
| H-94 | `wholeNumber()` must give a whole number from 0 to 2^32 - 1 and never a larger one, wider numbers being left to `integer`. |
| H-95 | `wholeNumber()` must draw a width in bits from 0 to 32 first and then a number of that width, so that numbers of every width from 0 to 32 bits occur. |
| H-96 | `wholeNumber()` must take at most two words of its tape, one for the width and one for the number. |
| H-97 | Lowering the number's word on the tape of a `wholeNumber` to a word that fits the width must lower the number to that word and must leave the words after it as they are. |
| H-98 | A source that gives only zeros must make `integer` and `number` give `min`, `boolean` give `false` and `wholeNumber` give 0. |
| H-99 | A source that gives only zeros must make `choice`, `oneOf` and `frequency` pick their first value, generator or entry. |
| H-100 | A source that gives only zeros must make `array` give `minLength` elements and `recursive` give a leaf. |
| H-101 | For a property that fails when an array from `array(wholeNumber(), 0, n)`, with `n` up to 20, holds a number of at least `t`, with `t` up to 4000000, the shrinker must reach a tape that replays as the one-element array holding `t`, within 10000 property calls. |
| H-102 | For a property that fails when an array from `array(wholeNumber(), 0, n)` has at least `k` elements, with `k` from 1 to 4 and `n` from `k` to 20, the shrinker must reach a tape that replays as `k` zeros, within 10000 property calls. |
| H-103 | For a property that fails when a value of `integer(min, max)`, whose span `max - min` is under 2^32, is at least `t`, the shrinker must reach a tape that replays as `t`, within 1000 property calls. |
| H-104 | For a property that fails on every value of a `choice` but the first, the shrinker must reach a tape that replays as the second value, within 1000 property calls. |

## 7. Signals

A **Signal** is the harness's stand-in for an engine signal, which the simulated engine offers Lync as a
seam.

| ID | Claim |
|---|---|
| H-105 | `Signal:Connect(listener)` must add a listener that is called at every firing until it is disconnected, and must return a connection whose `Connected` is true. |
| H-106 | `Signal:Once(listener)` must add a listener that is called at the next firing only, and its connection must have `Connected` false from the moment the listener is called. |
| H-107 | A `Once` listener that is disconnected before the next firing must not be called. |
| H-108 | `Disconnect` must set `Connected` to false and stop the listener from being called again, and repeating it must do nothing. |
| H-109 | `fire` must call the connected listeners in the order they were connected, with the arguments of the firing, on the stack of the caller of `fire`. |
| H-110 | A listener that throws must stop the firing, its error must reach the caller of `fire` unchanged, and the listeners after it must not be called. |
| H-111 | A listener that is disconnected while its signal is firing must not be called after that, even when it comes later in the same firing. |
| H-112 | A listener that is connected while its signal is firing must hear the next firing and not the one under way. |
| H-113 | `connectedCount()` must count the listeners that are still connected, a disconnected listener and a `Once` listener that has been called not counting. |
| H-114 | A `Signal` must satisfy the shape of a seam signal (A-191), so that it can stand in for an engine signal. |
