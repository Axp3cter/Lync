--!strict
--!optimize 2
-- The one record channel: what reaches it, what a record carries, and who can stop it.

local Catalog = require ("@src/kernel/Catalog")
local Lync = require ("@src")

local Doubles = require ("@fixtures/Doubles")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Records = require ("@test/harness/Records")
local Replica = require ("@test/harness/Replica")

-- Constants -----------------------------------------------------------

const SPACE = "logs"

-- The one client, whose fires are the client input half of every claim here.
const SENDER = "alice"

--[[
    Four definitions, because a record is only ever about one of them and three of the claims here
    are read off which.
]]
const GUARDED = "guarded"
const OTHER = "other"
const HEARD = "heard"
const UNHEARD = "unheard"

-- The bound a refusal is made by putting out of order, which is the plainest refusal there is.
const TOP = 100

-- A fifth, carrying the one codec here whose domain is narrower than the bytes that hold it.
const TAGGED = "tagged"
const VARIANTS = table.freeze ({ "red", "green", "blue" })

--[[
    A sixth, whose fields are packed into a word and whose grid stops short of the bits carrying
    it. Six is three bits and holds five, so the two patterns above it are ones a frame can spell
    and the schema cannot answer, which is the refusal a word raises for itself.
]]
const NARROW = "narrow"
const REACH = 5

-- What each guard says, in words nothing else in the tree uses.
const REFUSED = "the first guard turned it away"
const DIFFERENT = "the second guard turned it away"

-- Every kind a record may carry, which the surface states as three and no more.
const KINDS = table.freeze ({ "warn", "error", "debug" })

-- Types ---------------------------------------------------------------

-- What a record reads as, kept in one place because more than one suite reads them.
type Held = Records.Held

type Run = Replica.Paired

-- One way of making a record, named so a check that walks them all can say which failed.
type Fault = { read what: string, read run: (Run) -> () }

-- Private -------------------------------------------------------------

--[[
    Two packets that turn a value away with different words, two that take one, and one carrying a
    name rather than a truth. The pair of refusals is what says a record carries the reason its own
    site gave rather than a reason the channel composed.
]]
local function defined (): any
    return {
        [GUARDED] = Lync.packet (Lync.bool ():validate (function (): string? return REFUSED end)),
        [OTHER] = Lync.packet (Lync.bool ():validate (function (): string? return DIFFERENT end)),
        [HEARD] = Lync.packet (Lync.bool ()),
        [UNHEARD] = Lync.packet (Lync.bool ()),
        [TAGGED] = Lync.packet (Lync.enum (VARIANTS)),
        [NARROW] = Lync.packet (
            Lync.struct ({ low = Lync.int (0, REACH), high = Lync.int (0, REACH) })
        ),
    }
end

--[[
    Two machines on one lane, each definition listened to on the side that receives it.

    Every definition but `UNHEARD`, which is the one a check about a fire nobody hears needs to
    stay unlistened to.
]]
local function opened (): Run
    return Replica.paired ({
        space = SPACE,
        defined = defined,
        label = SENDER,
        wires = function (defs: any, side: string)
            for _, name in { GUARDED, OTHER, HEARD, TAGGED, NARROW } do
                if side == "server" then
                    defs[name]:onServer (function () end)
                else
                    defs[name]:onClient (function () end)
                end
            end
        end,
    })
end

-- A refusal of a value the schema cannot hold, which is the one this file's sweep is aimed at.
const TAG = Catalog.TAG

--[[
    Which refusals a sweep reached, in one line, so a failure says what happened instead of what did
    not. Sorted, because a walk of a table keyed by code has no order and a message that changed
    between runs would read as two different failures.
]]
local function shown (of: { [string]: boolean }): string
    local names = {}
    for code in of do
        table.insert (names, code)
    end

    table.sort (names)
    return if #names == 0 then "no refusal at all" else table.concat (names, ", ")
end

-- The one frame a piece of work put on the reliable lane on its way to the server.
local function carried (of: Run, run: () -> ()): Doubles.Carried
    local held: { Doubles.Carried } = {}
    local stop = of.wire:watch (function (frame: Doubles.Carried)
        if frame.at ~= "reliable" or frame.from == nil then return end

        table.insert (held, frame)
    end)

    run ()
    stop ()

    Expect.holds (#held > 0, "the fire put no frame on the reliable lane")
    return held[#held]
end

-- The same frame with one byte turned up to every bit it has.
local function louder (of: Doubles.Carried, at: number): Doubles.Carried
    local bytes = buffer.create (buffer.len (of.bytes))
    buffer.copy (bytes, 0, of.bytes)
    buffer.writeu8 (bytes, at, 0xFF)

    return { at = of.at, from = of.from, to = of.to, bytes = bytes, refs = of.refs }
end

-- A fire from the client, and the round that carries it to the server.
local function fromClient (of: Run, name: string, value: any?)
    of.client.defs[name]:fireServer (if value == nil then true else value)
    of.client.session:flush ()
    of.wire:settle ()
end

-- The same the other way, addressed rather than broadcast, since there is one client.
local function fromServer (of: Run, name: string)
    of.server.defs[name]:fireClient (of.player, true)
    of.server.session:flush ()
    of.wire:settle ()
end

--[[
    The four ways this file makes a record, walked whole by every check that asks something of
    records in general rather than of one of them.
]]
const FAULTS: { Fault } = table.freeze ({
    table.freeze ({
        what = "a fire the server turned away",
        run = function (of: Run) fromClient (of, GUARDED) end,
    }),
    table.freeze ({
        what = "a fire the client turned away",
        run = function (of: Run) fromServer (of, GUARDED) end,
    }),
    table.freeze ({
        what = "a listener that raised",
        run = function (of: Run)
            of.server.defs[HEARD]:onServer (function () error ("a listener said no", 0) end)
            fromClient (of, HEARD)
        end,
    }),
    table.freeze ({
        what = "a frame naming no definition",
        run = function (of: Run)
            local held = carried (of, function () fromClient (of, HEARD) end)
            of.wire:hands (louder (held, 0))
        end,
    }),
})

-- The one record a run made, and a failure naming the run when it made none or several.
local function only (held: { Held }, what: string): Held
    Expect.holds (#held == 1, `{what} made {#held} records`)
    return held[1]
end

-- Whether a record spelled something out, which is how the two wordings are read.
local function spells (message: string, part: string, what: string)
    if string.find (message, part, 1, true) ~= nil then return end
    Expect.holds (false, `{what} reads {message}, which does not say {part}`)
end

-- Public --------------------------------------------------------------

return {
    --[[
        The default printer, handed over rather than registered, and what is left when a caller
        takes it.
    ]]
    Harness.case ("log.console-is-connection", function ()
        Expect.equal (Lync.console.connected, true)

        Lync.console:disconnect ()
        Expect.equal (Lync.console.connected, false)

        local of = opened ()
        local held = Records.made (function () fromClient (of, GUARDED) end)
        Expect.holds (#held > 0, "no record reached a listener once the console was dropped")
    end),

    -- Every record reaches a listener, and reaches it as three things.
    Harness.case ("log.receives-all", function ()
        for _, fault in FAULTS do
            local of = opened ()
            local held = Records.made (function () fault.run (of) end)

            Expect.holds (#held > 0, `{fault.what} reached no listener`)
            for _, one in held do
                Expect.equal (typeof (one.kind), "string")
                Expect.equal (typeof (one.message), "string")
                Expect.equal (typeof (one.data), "table")
            end
        end
    end),

    -- A listener is a connection, and dropping it stops the records.
    Harness.case ("log.returns-connection", function ()
        local of = opened ()
        local held = {}

        local link = Lync.onLog (function () table.insert (held, true) end)
        Expect.equal (link.connected, true)

        fromClient (of, GUARDED)
        Expect.holds (#held > 0, "a record reached nothing while a listener was attached")

        local was = #held
        link:disconnect ()
        Expect.equal (link.connected, false)

        fromClient (of, GUARDED)
        Expect.equal (#held, was)
    end),

    -- Three kinds and no more, and which of them each fault earns.
    Harness.case ("log.kinds", function ()
        for _, fault in FAULTS do
            local of = opened ()

            for _, one in Records.made (function () fault.run (of) end) do
                local held = table.find (KINDS, one.kind) ~= nil
                Expect.holds (held, `{fault.what} made a {one.kind} record`)
            end
        end

        local dropped = opened ()
        local turned = only (Records.made (function () fromClient (dropped, GUARDED) end), "a drop")
        Expect.equal (turned.kind, "warn")

        local raised = opened ()
        local contained = Records.made (function () FAULTS[3].run (raised) end)
        Expect.equal (only (contained, "a contained fault").kind, "error")
    end),

    --[[
        Where the record was made, on every record there is. A message is versioned prose and a
        caller is told not to match on it, so the position is the only part that says where to look.
    ]]
    Harness.case ("log.data-floor", function ()
        for _, fault in FAULTS do
            local of = opened ()
            local held = Records.made (function () fault.run (of) end)
            Expect.holds (#held > 0, `{fault.what} reached no listener`)

            for _, one in held do
                local file, at = one.data.file, one.data.line

                Expect.holds (typeof (file) == "string", `{fault.what}: no file`)
                Expect.holds (#file > 0, `{fault.what}: an empty file`)

                Expect.holds (typeof (at) == "number", `{fault.what}: no line`)
                Expect.holds (at > 0 and at % 1 == 0, `{fault.what}: line {at}`)
            end
        end
    end),

    -- Who sent the thing the record is about, and the records about nobody.
    Harness.case ("log.data-player", function ()
        local inbound = opened ()
        local sent = only (Records.made (function () fromClient (inbound, GUARDED) end), "a client")

        Expect.holds (sent.data.player == inbound.player, `the sender is {sent.data.player}`)

        local outbound = opened ()
        local back =
            only (Records.made (function () fromServer (outbound, GUARDED) end), "the server")

        Expect.equal (back.data.player, nil)
    end),

    --[[
        A caller turned away, which the channel never hears about. The library says four things
        about something being wrong and three of them are for whoever is watching. A refusal is a
        mistake in the place's own code, thrown at the line that made it.
    ]]
    Harness.case ("log.refusal-silent", function ()
        local made = Records.made (function ()
            Expect.throws (function () Lync.int (TOP, 0) end, "takes its bounds in order")
        end)
        Expect.equal (#made, 0)

        local held = Lync.group ()
        held:destroy ()

        local after = Records.made (function ()
            Expect.throws (function () held:has (nil :: any) end, "was destroyed")
        end)
        Expect.equal (#after, 0)
    end),

    --[[
        Bytes the schema cannot answer, read by the machine around the codec rather than by the
        codec: the refusal becomes a record somebody catalogued and stops there.
    ]]
    Harness.case ("codec.decode-drops", function ()
        local of = opened ()
        local frame = carried (of, function () fromClient (of, TAGGED, VARIANTS[1]) end)

        local dropped: { [string]: boolean } = {}
        for at = 0, buffer.len (frame.bytes) - 1 do
            local hostile = louder (frame, at)
            for _, one in Records.made (function () of.wire:hands (hostile) end) do
                local code = one.data.code
                Expect.holds (
                    code ~= nil and Catalog.entries[code :: any] ~= nil,
                    `byte {at} was refused as {tostring (code)}, which no row spells`
                )
                dropped[code :: any] = true
            end
        end

        Expect.holds (
            dropped[TAG] ~= nil,
            `nothing in the frame reached the schema's own domain, only {shown (dropped)}`
        )
    end),

    --[[
        A word's field read past the end of its grid, which the word refuses for itself rather
        than leaving to the frame around it. What the refusal carries is the code naming a value
        outside its domain and the index that arrived, and a drop catalogued as something else or
        reporting nothing of what it read leaves a reader with damage they cannot go and look at.
    ]]
    Harness.case ("log.word-past-its-grid", function ()
        local of = opened ()
        local frame = carried (of, function () fromClient (of, NARROW, { low = 1, high = 2 }) end)

        local seen = false
        for at = 0, buffer.len (frame.bytes) - 1 do
            for _, one in Records.made (function () of.wire:hands (louder (frame, at)) end) do
                if one.data.code ~= TAG then continue end

                seen = true
                Expect.holds (
                    one.data.got ~= nil and one.data.got ~= 0,
                    `a value past its grid was refused reporting {tostring (one.data.got)}`
                )
            end
        end

        Expect.holds (seen, "no byte of a narrow word was refused for the grid it ran past")
    end),

    -- What a drop record says it is about, held by discrimination rather than by wording.
    Harness.case ("log.drop-detail", function ()
        local of = opened ()

        local first =
            only (Records.made (function () fromClient (of, GUARDED) end), "the first guard")
        local named =
            only (Records.made (function () fromClient (of, OTHER) end), "the second guard")

        Expect.equal (first.data.definition, GUARDED)
        Expect.equal (named.data.definition, OTHER)
        Expect.holds (first.message ~= named.message, `both guards read {first.message}`)
    end),

    -- A validator's reason, carried whole.
    Harness.case ("codec.validate-rejects", function ()
        local of = opened ()
        local first =
            only (Records.made (function () fromClient (of, GUARDED) end), "the first guard")
        local next_ =
            only (Records.made (function () fromClient (of, OTHER) end), "the second guard")

        spells (first.message, REFUSED, "the first guard")
        spells (next_.message, DIFFERENT, "the second guard")

        Expect.holds (
            string.find (next_.message, REFUSED, 1, true) == nil,
            `the second guard reads {next_.message}, which is the first guard's words`
        )
    end),

    --[[
        A listener that raises, the siblings that run anyway, and the record the library leaves
        behind.
    ]]
    Harness.case ("packet.listener-throws", function ()
        local of = opened ()
        local order = {}

        of.server.defs[HEARD]:onServer (function ()
            table.insert (order, "raised")
            error ("a listener said no", 0)
        end)
        of.server.defs[HEARD]:onServer (function () table.insert (order, "sibling") end)

        local held = Records.made (function () fromClient (of, HEARD) end)

        Expect.equal (order[1], "raised")
        Expect.equal (order[2], "sibling")
        Expect.holds (#held > 0, "a listener raised and nothing was recorded")
    end),

    --[[
        A packet nobody listens for, which is a wiring bug rather than noise. A development build
        throws where the frame is read so whoever wired it meets it at once, and a shipped one
        records and carries on. The record is the half both builds owe.
    ]]
    Harness.case ("packet.unheard", function ()
        local of = opened ()

        local held = Records.made (function ()
            of.server.defs[UNHEARD]:fireClient (of.player, true)
            of.server.session:flush ()

            if __DEV__ then
                Expect.throws (function () of.wire:settle () end)
                return
            end

            of.wire:settle ()
        end)

        Expect.holds (#held > 0, "an unheard packet was not recorded")
    end),
}
