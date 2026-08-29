--!strict
--!optimize 2
--[[
    The counters alone: what each call adds, and what a reading taken off them is.
]]

local Tally = require ("@src/kernel/Tally")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- The definitions a namespace in these cases holds, and the name it never compiled.
const NAMES = table.freeze ({ "beat", "roster", "asks" })
const STRANGER = "unheard"

-- Byte figures a case adds, kept apart so a sum says which calls made it.
const FEW = 7
const MANY = 40
const MORE = 300

-- Types ---------------------------------------------------------------

type Held = Tally.Tally

-- Private -------------------------------------------------------------

-- A namespace's counters, every definition at zero, which is what every case opens with.
local function made (): Held return Tally.new (NAMES) end

-- One definition's line as a reading gives it back, which is the shape a caller reads.
local function row (of: Held, name: string): any return Tally.reading (of).definitions[name] end

-- Public --------------------------------------------------------------

return {
    --[[
        Every definition a namespace holds, at zero, made when the namespace is. Every one rather
        than the ones that did something, because a caller subtracts two readings and a row that
        appeared between them is a row the subtraction has nothing to take away from.
    ]]
    Harness.case ("tally.opens-at-zero", function ()
        local of = made ()
        local held = Tally.reading (of)

        Expect.equal (held.flushes, 0)
        Expect.equal (held.sentBytes, 0)
        Expect.equal (held.receivedBytes, 0)
        Expect.equal (held.drops, 0)

        for _, name in NAMES do
            local line = held.definitions[name]
            Expect.holds (line ~= nil, `{name} has no line at all`)

            Expect.equal (line.sent, 0)
            Expect.equal (line.sentBytes, 0)
            Expect.equal (line.received, 0)
            Expect.equal (line.receivedBytes, 0)
            Expect.equal (line.drops, 0)
        end
    end),

    --[[
        A name nothing happened to, after everything else has moved. The reading this asks for is
        the one an absent row could not have given.
    ]]
    Harness.case ("tally.quiet-definitions-stay", function ()
        local of = made ()
        Tally.sent (of, NAMES[1], MANY)
        Tally.received (of, NAMES[1], FEW)

        local held = Tally.reading (of)
        Expect.equal (held.definitions[NAMES[2]].sent, 0)
        Expect.equal (held.definitions[NAMES[3]].receivedBytes, 0)
    end),

    --[[
        A block composed and queued, counted as one call and its bytes. Both, because a definition
        firing rarely with a wide payload and one firing constantly with a narrow one are the same
        bytes and different problems.
    ]]
    Harness.case ("tally.sent", function ()
        local of = made ()

        Tally.sent (of, NAMES[1], MANY)
        Tally.sent (of, NAMES[1], FEW)

        local line = row (of, NAMES[1])
        Expect.equal (line.sent, 2)
        Expect.equal (line.sentBytes, MANY + FEW)

        -- The namespace figure is the engine's frames, which no definition call touches.
        Expect.equal (Tally.reading (of).sentBytes, 0)
    end),

    --[[
        Two calls and one block, which is what a coalescing lane makes and the arrangement the
        two counters exist to tell apart. The count says a caller asked twice and the bytes say
        the wire carried one, and reading either alone calls a coalescing lane free or broken.
    ]]
    Harness.case ("tally.carried", function ()
        local of = made ()

        Tally.sent (of, NAMES[1], 0)
        Tally.sent (of, NAMES[1], 0)
        Tally.carried (of, NAMES[1], MANY)

        local line = row (of, NAMES[1])
        Expect.equal (line.sent, 2)
        Expect.equal (line.sentBytes, MANY)
    end),

    --[[
        A block read off a frame, whatever became of what was inside it. A payload turned away is
        counted here as well as under a drop, because a drop figure with no denominator answers no
        question: what a caller asks of the two is what fraction of a definition's traffic is junk.
    ]]
    Harness.case ("tally.received", function ()
        local of = made ()

        Tally.received (of, NAMES[2], MANY)
        Tally.dropped (of, NAMES[2])

        local line = row (of, NAMES[2])
        Expect.equal (line.received, 1)
        Expect.equal (line.receivedBytes, MANY)
        Expect.equal (line.drops, 1)
        Expect.equal (Tally.reading (of).drops, 1)
    end),

    --[[
        A drop with nobody to charge it to. A frame naming a definition this namespace has not got
        is what went wrong, so the namespace figure carries it alone and no line is made: a line
        under any name would be a line about a definition that had nothing to do with it.
    ]]
    Harness.case ("tally.dropped-unnamed", function ()
        local of = made ()

        Tally.dropped (of, nil)
        Tally.dropped (of, nil)

        local held = Tally.reading (of)
        Expect.equal (held.drops, 2)

        local counted = 0
        for _ in held.definitions do
            counted += 1
        end
        Expect.equal (counted, #NAMES)
    end),

    --[[
        A count about a definition the namespace did not compile. Nothing in this library raises one
        today, and a counter that silently dropped one would be worse than a row a reader can see is
        unexpected, so the line is made where it is first needed.
    ]]
    Harness.case ("tally.unknown-definition", function ()
        local of = made ()
        Tally.sent (of, STRANGER, FEW)

        local line = row (of, STRANGER)
        Expect.holds (line ~= nil, "a count about an unknown definition went nowhere")
        Expect.equal (line.sent, 1)
        Expect.equal (line.sentBytes, FEW)
    end),

    --[[
        The namespace's own figures, arranged so the frame total lands above the sum of the lines
        under it. One block to two clients is what pulls them apart, and a run where the two
        agreed would say the frames were never counted separately.
    ]]
    Harness.case ("tally.namespace-figures", function ()
        local of = made ()

        Tally.sent (of, NAMES[1], MANY)
        Tally.moved (of, MORE)
        Tally.moved (of, MORE)
        Tally.took (of, FEW)
        Tally.flushed (of)

        local held = Tally.reading (of)
        Expect.equal (held.flushes, 1)
        Expect.equal (held.sentBytes, MORE * 2)
        Expect.equal (held.receivedBytes, FEW)
        Expect.holds (held.sentBytes > held.definitions[NAMES[1]].sentBytes, "the frames cost less")
    end),

    --[[
        Every number only ever goes up. Two readings are taken around a run of every kind of call
        and none of them falls, which is what a caller subtracting a pair rests on and what a
        counter reset anywhere would break.
    ]]
    Harness.case ("tally.monotonic", function ()
        local of = made ()
        local was = Tally.reading (of)

        for round = 1, 4 do
            Tally.sent (of, NAMES[round % #NAMES + 1], round)
            Tally.carried (of, NAMES[1], round)
            Tally.received (of, NAMES[2], round)
            Tally.dropped (of, if round % 2 == 0 then NAMES[2] else nil)
            Tally.moved (of, round)
            Tally.took (of, round)
            Tally.flushed (of)

            local now = Tally.reading (of)
            Expect.holds (now.flushes >= was.flushes, "the flush count fell")
            Expect.holds (now.sentBytes >= was.sentBytes, "the sent bytes fell")
            Expect.holds (now.receivedBytes >= was.receivedBytes, "the received bytes fell")
            Expect.holds (now.drops >= was.drops, "the drop count fell")

            for name, line in now.definitions do
                local before = was.definitions[name]
                Expect.holds (line.sent >= before.sent, `{name} sent fewer than it had`)
                Expect.holds (line.sentBytes >= before.sentBytes, `{name} unsent bytes`)
                Expect.holds (line.received >= before.received, `{name} received fewer`)
                Expect.holds (line.drops >= before.drops, `{name} undropped`)
            end
            was = now
        end
    end),

    --[[
        A reading is copied and frozen. Two taken either side of a count are held to differing by
        it, which is what neither a shared table nor a writable one would answer.
    ]]
    Harness.case ("tally.reading-is-a-copy", function ()
        local of = made ()
        Tally.sent (of, NAMES[1], MANY)

        local first = Tally.reading (of)
        Tally.sent (of, NAMES[1], MANY)
        local second = Tally.reading (of)

        Expect.equal (first.definitions[NAMES[1]].sent, 1)
        Expect.equal (second.definitions[NAMES[1]].sent, 2)

        -- The subtraction the surface promises, which is what the copy is for.
        Expect.equal (
            second.definitions[NAMES[1]].sentBytes - first.definitions[NAMES[1]].sentBytes,
            MANY
        )

        Expect.equal (table.isfrozen (first :: any), true)
        Expect.equal (table.isfrozen (first.definitions :: any), true)
        Expect.equal (table.isfrozen (first.definitions[NAMES[1]] :: any), true)
    end),
}
