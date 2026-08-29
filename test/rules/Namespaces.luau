--!strict
--!optimize 2
-- A namespace as the unit it is: what opens one, what drains one, and what it counts.

local Lync = require ("@src")
local Protocol = require ("@src/wire/Protocol")
local Types = require ("@src/Types")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

--[[
    Two namespaces rather than one. Half of what a namespace is is that it is not the others, and a
    claim about which of them a flush reached needs a second one to have been left alone. Both are
    this module's own, because reading another suite's counters would be reading a number that suite
    is free to change.
]]
const NAMESPACE = "namespaces"
const BESIDE = "beside"

-- The smallest budget a flush takes, and the one below it that it will not.
const FLOOR = Protocol.BUDGET_FLOOR

-- A name no `define` opened, which is what a caller reaches with a typo.
const NOWHERE = "nowhere"

-- Flushes before the first of two snapshots, against the one between them.
const BEFORE = 3

--[[
    Every kind and more than one packet, because a snapshot carries a row per definition and a
    namespace holding only packets would not show whether the rows follow the definitions or the
    kind.
]]
const DEFINITIONS = {
    beat = Lync.packet (Lync.bool ()),
    thud = Lync.packet (Lync.bool ()),
    stamp = Lync.packet (Lync.bool ()):timestamped (),
    ask = Lync.query (Lync.bool (), Lync.bool ()),
    board = Lync.replicate (Lync.struct ({ alive = Lync.bool () })),
}

-- The second namespace, which exists to be the one a flush did not reach.
const OTHERS = { pulse = Lync.packet (Lync.bool ()) }

-- A third, opened by the one check that reads what `define` hands back rather than what it did.
const SHARED = "shared"
const CARRIED = { relay = Lync.packet (Lync.bool ()) }

-- Private -------------------------------------------------------------

--[[
    Every counter a snapshot holds, flattened to one name apiece. The rows sit under the definitions
    they belong to, so a walk comparing two snapshots has to reach into them, and flattening once
    here is what keeps the comparison a loop rather than a shape.
]]
local function counted (snap: Types.Stats): { [string]: number }
    local out: { [string]: number } = {
        flushes = snap.flushes,
        sentBytes = snap.sentBytes,
        receivedBytes = snap.receivedBytes,
        drops = snap.drops,
    }

    for name, row in snap.definitions do
        out[`{name}.sent`] = row.sent
        out[`{name}.sentBytes`] = row.sentBytes
        out[`{name}.received`] = row.received
        out[`{name}.receivedBytes`] = row.receivedBytes
        out[`{name}.drops`] = row.drops
    end
    return out
end

-- How many times a namespace has been drained, which is the one counter a flush moves alone.
local function drained (name: string): number return Lync.stats (name).flushes end

-- Public --------------------------------------------------------------

return {
    Harness.opens (NAMESPACE, DEFINITIONS),
    Harness.opens (BESIDE, OTHERS),

    --[[
        A name already taken. A namespace is reached by its name from both machines, so two
        definitions tables under one name is two schemas one name resolves to, and whichever the
        handshake hashed is the one the other side does not have.
    ]]
    Harness.sealed ("ns.duplicate-name", function ()
        Expect.throws (
            function () Lync.define (NAMESPACE, DEFINITIONS :: any) end,
            "has already been defined"
        )
    end),

    --[[
        A name the descriptor cannot spell back: nothing at all, or either mark the grammar
        separates with, which the far side reads as two names. The number is here for what it is
        not. It holds neither mark, so the name guard passes it and the definitions already being
        named are what turn it away, which this says rather than reading as a name test that passes.
    ]]
    Harness.sealed ("ns.illegal-name", function ()
        Expect.throws (
            function () Lync.define ("", DEFINITIONS :: any) end,
            "cannot be required by anybody"
        )
        Expect.throws (
            function () Lync.define ("holds;a;mark", {} :: any) end,
            "which is what a descriptor separates its own names with"
        )
        Expect.throws (
            function () Lync.define (5 :: any, DEFINITIONS :: any) end,
            "is already named in"
        )
    end),

    --[[
        A value in the table that is not a definition. A bare number is the typo, and a bare codec
        is the mistake worth catching: a caller who wrote the schema and forgot to say whether it is
        a packet, a query or a set has written something that looks entirely right.
    ]]
    Harness.sealed ("ns.non-definition", function ()
        local said = "is not a packet, a query or a set"
        Expect.throws (function () Lync.define (NOWHERE, { wrong = 5 } :: any) end, said)
        Expect.throws (function () Lync.define (NOWHERE, { wrong = Lync.bool () } :: any) end, said)
    end),

    --[[
        What `define` hands back, which a caller returns from a shared module and both machines
        require. Plain data means three things: it is the definitions themselves, it carries nothing
        else, and it is read-only, so a caller cannot change a schema the two machines already
        agreed on.
    ]]
    Harness.sealed ("ns.pure-data", function ()
        local given: any = CARRIED
        local back: any = Lync.define (SHARED, CARRIED :: any)

        for name, of in given do
            Expect.holds (back[name] == of, `{name} came back as something else`)
        end
        for name in back do
            Expect.holds (given[name] ~= nil, `{name} is a name nobody declared`)
        end

        Expect.equal (table.isfrozen (back), true)
        Expect.throws (function () back.late = Lync.packet (Lync.bool ()) end)
    end),

    --[[
        A flush of a namespace nobody opened. A typo here is traffic that never leaves, and a
        library that shrugged would leave a caller watching a receiver for a frame their own machine
        still holds.
    ]]
    Harness.case ("ns.unknown-flush", function ()
        Expect.throws (
            function () Lync.flush (NOWHERE) end,
            "which is no namespace this place defined"
        )
    end),

    --[[
        The same typo read rather than flushed. A zeroed snapshot is the wrong answer twice over: it
        reads as a quiet namespace, and a caller watching the wrong name for a rate would see one
        that never moves.
    ]]
    Harness.case ("stats.unknown-namespace", function ()
        Expect.throws (
            function () Lync.stats (NOWHERE) end,
            "which is no namespace this place defined"
        )
    end),

    --[[
        What a snapshot is: a reading, not a view. A caller diffs two of them to get a rate, which
        only means anything if neither changed after it was taken, and the types say so from the top
        level down to a definition's own line.
    ]]
    Harness.case ("stats.snapshot", function ()
        local snap = Lync.stats (NAMESPACE)
        Expect.equal (table.isfrozen (snap :: any), true)
        Expect.throws (function () (snap :: any).flushes = 0 end)

        local row = snap.definitions.beat
        Expect.holds (row ~= nil, "the snapshot carries no row for beat")
        Expect.throws (function () (row :: any).sent = 0 end)
    end),

    --[[
        A row per definition, under the name `define` was given. Held from both ends: every
        definition has a line, and no line belongs to a definition this namespace never declared.
    ]]
    Harness.case ("stats.per-definition", function ()
        local snap = Lync.stats (NAMESPACE)

        for name in snap.definitions do
            Expect.holds ((DEFINITIONS :: any)[name] ~= nil, `{name} is a row for no definition`)
        end
        for name in DEFINITIONS do
            Expect.holds (snap.definitions[name] ~= nil, `{name} has no row`)
        end
    end),

    --[[
        Two definitions fired into one flush, counted apart. A run carries one definition and the
        row it counts into belongs to the run, so a second run that kept the first one's row would
        put every later fire under a name its caller never fired.
    ]]
    Harness.case ("stats.two-definitions-counted-apart", function ()
        local before = Lync.stats (NAMESPACE).definitions

        DEFINITIONS.beat:fireClient (Lync.all, true)
        DEFINITIONS.thud:fireClient (Lync.all, true)
        DEFINITIONS.thud:fireClient (Lync.all, true)
        Lync.flush (NAMESPACE)

        local after = Lync.stats (NAMESPACE).definitions
        Expect.equal (after.beat.sent - before.beat.sent, 1)
        Expect.equal (after.thud.sent - before.thud.sent, 2)
    end),

    --[[
        A definition carrying an instant, counted the same. It is written one block a fire because
        the instant is a field of its header, so it never opens a run and is counted where it is
        written instead of where a run would have counted it.
    ]]
    Harness.case ("stats.an-instant-is-counted-per-fire", function ()
        local before = Lync.stats (NAMESPACE).definitions

        DEFINITIONS.stamp:fireClient (Lync.all, true)
        DEFINITIONS.stamp:fireClient (Lync.all, true)
        Lync.flush (NAMESPACE)

        local after = Lync.stats (NAMESPACE).definitions
        Expect.equal (after.stamp.sent - before.stamp.sent, 2)
    end),

    --[[
        Counters that only climb, which is what makes two snapshots a rate rather than a guess. A
        counter that reset would give a caller a negative rate with no way to tell it from a quiet
        interval.
    ]]
    Harness.case ("stats.monotonic", function ()
        for _ = 1, BEFORE do
            DEFINITIONS.beat:fireClient (Lync.all, true)
            Lync.flush (NAMESPACE)
        end

        local before = counted (Lync.stats (NAMESPACE))

        DEFINITIONS.beat:fireClient (Lync.all, true)
        Lync.flush (NAMESPACE)

        local after = counted (Lync.stats (NAMESPACE))
        for name, held in before do
            local now = after[name]
            Expect.holds (now ~= nil, `{name} left between two snapshots`)
            Expect.holds ((now :: number) >= held, `{name} fell from {held} to {now}`)
        end
    end),

    --[[
        A budget under the floor. A number that small is a frame delta wired into `flush` by
        accident rather than a plan, and the floor is where the protocol puts the line: a section is
        bounded by the same number, so any legal budget ships at least one of them and a smaller one
        would ship nothing forever while looking like it was trying.
    ]]
    Harness.case ("life.flush-floor", function ()
        local under = "is under the floor of"
        Expect.throws (function () Lync.flush (FLOOR - 1) end, under)
        Expect.throws (function () Lync.flush (NAMESPACE, FLOOR - 1) end, under)

        Lync.flush (NAMESPACE, FLOOR)
    end),

    --[[
        A flush that names one namespace drains that one. Namespaces keep their own cadence on
        purpose: a movement stream flushed every frame and an inventory flushed on change are the
        ordinary arrangement, and a flush that reached both would make the second as expensive as
        the first.
    ]]
    Harness.case ("life.flush-one", function ()
        local mine, other = drained (NAMESPACE), drained (BESIDE)
        Lync.flush (NAMESPACE)

        Expect.equal (drained (NAMESPACE), mine + 1)
        Expect.equal (drained (BESIDE), other)
    end),

    --[[
        A flush that names nothing drains everything. The other half of the pair above, and the one
        a caller reaches first: a single call at the end of a frame, before anyone has more than one
        namespace to think about.
    ]]
    Harness.case ("life.flush-all", function ()
        local mine, other = drained (NAMESPACE), drained (BESIDE)
        Lync.flush ()

        Expect.equal (drained (NAMESPACE), mine + 1)
        Expect.equal (drained (BESIDE), other + 1)
    end),
}
