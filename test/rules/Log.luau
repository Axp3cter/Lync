--!strict
--!optimize 2
-- The one record channel: what reaches it, what a record carries, and who can stop it.

local Catalog = require("@src/kernel/Catalog")
local Codecs = require("@src/codec")
local Group = require("@src/channel/Group")
local Log = require("@src/kernel/Log")
local Packet = require("@src/api/Packet")
local Types = require("@src/Types")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Records = require("@test/harness/Records")
local Replica = require("@test/harness/Replica")

local SPACE = "logs"

-- The one client, whose fires are the client input half of every claim here.
local SENDER = "alice"

-- Four definitions, because a record is only ever about one of them and three of the claims here
-- are read off which. A fifth carries the one codec whose domain is narrower than the bytes that
-- hold it, and a sixth packs two fields into a word whose grid stops short of the bits carrying
-- it: six is three bits and holds five, so the two patterns above it are ones a frame can spell
-- and the schema cannot answer.
local GUARDED = "guarded"
local OTHER = "other"
local HEARD = "heard"
local UNHEARD = "unheard"
local TAGGED = "tagged"
local NARROW = "narrow"

local LISTENED = table.freeze({ GUARDED, OTHER, HEARD, TAGGED, NARROW })
local VARIANTS = table.freeze({ "red", "green", "blue" })
local REACH = 5

-- The bound a refusal is made by putting out of order, which is the plainest refusal there is.
local TOP = 100

-- What each guard says, in words nothing else in the tree uses.
local REFUSED = "the first guard turned it away"
local DIFFERENT = "the second guard turned it away"

-- Every kind a record may carry, which the surface states as two and no more.
local KINDS = table.freeze({ "warn", "error" })

-- A refusal of a value the schema cannot hold, which is the one this file's sweep is aimed at.
local TAG = Catalog.TAG

type Held = Records.Held
type Run = Replica.Paired

-- One way of making a record, named so a check that walks them all can say which failed.
type Fault = { read what: string, read run: (Run) -> () }

-- Private -------------------------------------------------------------

local function guarded(says: string): Types.Codec<boolean>
    return Codecs.bool():validate(function(): string?
        return says
    end)
end

-- Two packets refuse with different words, which is what says a record carries the reason its
-- own site gave rather than a reason the channel composed.
local function defined(): any
    local word = Codecs.struct({ low = Codecs.int(0, REACH), high = Codecs.int(0, REACH) })
    return {
        [GUARDED] = Packet.new(guarded(REFUSED)),
        [OTHER] = Packet.new(guarded(DIFFERENT)),
        [HEARD] = Packet.new(Codecs.bool()),
        [UNHEARD] = Packet.new(Codecs.bool()),
        [TAGGED] = Packet.new(Codecs.enum(VARIANTS)),
        [NARROW] = Packet.new(word),
    }
end

-- Two machines on one lane, each definition but the unheard one listened to on the side that
-- receives it.
local function opened(): Run
    return Replica.paired({
        space = SPACE,
        defined = defined,
        label = SENDER,
        wires = function(defs: any, side: string)
            for _, name in LISTENED do
                if side == "server" then
                    defs[name]:onServer(function() end)
                else
                    defs[name]:onClient(function() end)
                end
            end
        end,
    })
end

-- Which refusals a sweep reached, in one line, sorted so a failure reads the same between runs.
local function shown(of: { [string]: boolean }): string
    local names = {}
    for code in of do
        table.insert(names, code)
    end
    table.sort(names)
    return if #names == 0 then "no refusal at all" else table.concat(names, ", ")
end

-- The one frame a piece of work put on the reliable lane on its way to the server.
local function carried(of: Run, run: () -> ()): Doubles.Carried
    local held: { Doubles.Carried } = {}
    local stop = of.wire:watch(function(frame: Doubles.Carried)
        if frame.at == "reliable" and frame.from ~= nil then table.insert(held, frame) end
    end)
    run()
    stop()
    Expect.holds(#held > 0, "the fire put no frame on the reliable lane")
    return held[#held]
end

local function reframed(of: Doubles.Carried, bytes: buffer): Doubles.Carried
    return { at = of.at, from = of.from, to = of.to, bytes = bytes, refs = of.refs }
end

-- A carried frame with one byte turned up to every bit it has.
local function louder(of: Doubles.Carried, at: number): Doubles.Carried
    local bytes = buffer.create(buffer.len(of.bytes))
    buffer.copy(bytes, 0, of.bytes)
    buffer.writeu8(bytes, at, 0xFF)
    return reframed(of, bytes)
end

-- A carried frame cut short, which is a block whose own header runs past the bytes it came in.
local function shorter(of: Doubles.Carried, held: number): Doubles.Carried
    local bytes = buffer.create(held)
    buffer.copy(bytes, 0, of.bytes, 0, held)
    return reframed(of, bytes)
end

-- A fire from the client, and the round that carries it to the server.
local function fromClient(of: Run, name: string, value: any?)
    of.client.defs[name]:fireServer(if value == nil then true else value)
    of.client.session:flush()
    of.wire:settle()
end

-- The same the other way, addressed rather than broadcast, since there is one client.
local function fromServer(of: Run, name: string)
    of.server.defs[name]:fireClient(of.player, true)
    of.server.session:flush()
    of.wire:settle()
end

local function raising(of: Run)
    of.server.defs[HEARD]:onServer(function()
        error("a listener said no", 0)
    end)
    fromClient(of, HEARD)
end

local function fault(what: string, run: (Run) -> ()): Fault
    return table.freeze({ what = what, run = run })
end

-- The four ways this file makes a record, walked whole by every check that asks something of
-- records in general rather than of one of them.
local FAULTS: { Fault } = table.freeze({
    fault("a fire the server turned away", function(of: Run)
        fromClient(of, GUARDED)
    end),
    fault("a fire the client turned away", function(of: Run)
        fromServer(of, GUARDED)
    end),
    fault("a listener that raised", raising),
    fault("a frame naming no definition", function(of: Run)
        local held = carried(of, function()
            fromClient(of, HEARD)
        end)
        of.wire:hands(louder(held, 0))
    end),
})

-- What one fault recorded on a fresh pair of machines, which is never nothing.
local function recorded(fault: Fault): { Held }
    local of = opened()
    local held = Records.made(function()
        fault.run(of)
    end)
    Expect.holds(#held > 0, `{fault.what} reached no listener`)
    return held
end

-- The one record a run made, and a failure naming the run when it made none or several.
local function only(held: { Held }, what: string): Held
    Expect.holds(#held == 1, `{what} made {#held} records`)
    return held[1]
end

-- The one record a fire from the client under `name` makes.
local function oneFrom(name: string, what: string): Held
    local of = opened()
    return only(
        Records.made(function()
            fromClient(of, name)
        end),
        what
    )
end

-- Whether a record spelled something out, which is how the two wordings are read.
local function spells(message: string, part: string, what: string)
    local said = string.find(message, part, 1, true) ~= nil
    Expect.holds(said, `{what} reads {message}, which does not say {part}`)
end

-- Public --------------------------------------------------------------

return {
    -- The default printer, handed over rather than registered, and what is left when a caller
    -- takes it. An earlier suite in the same process may have taken it already.
    Harness.case("log.console-is-connection", function()
        Expect.equal(typeof(Log.console.connected), "boolean")
        Log.console:disconnect()
        Expect.equal(Log.console.connected, false)

        local of = opened()
        local held = Records.made(function()
            fromClient(of, GUARDED)
        end)
        Expect.holds(#held > 0, "no record reached a listener once the console was dropped")
    end),

    -- Every record reaches a listener, and reaches it as three things.
    Harness.case("log.receives-all", function()
        for _, fault in FAULTS do
            for _, one in recorded(fault) do
                Expect.equal(typeof(one.kind), "string")
                Expect.equal(typeof(one.message), "string")
                Expect.equal(typeof(one.data), "table")
            end
        end
    end),

    -- A listener is a connection, and dropping it stops the records.
    Harness.case("log.returns-connection", function()
        local of = opened()
        local held = {}
        local link = Log.onLog(function()
            table.insert(held, true)
        end)
        Expect.equal(link.connected, true)

        fromClient(of, GUARDED)
        Expect.holds(#held > 0, "a record reached nothing while a listener was attached")

        local was = #held
        link:disconnect()
        Expect.equal(link.connected, false)
        fromClient(of, GUARDED)
        Expect.equal(#held, was)
    end),

    -- Two kinds and no more, and which of them each fault earns.
    Harness.case("log.kinds", function()
        for _, fault in FAULTS do
            for _, one in recorded(fault) do
                local held = table.find(KINDS, one.kind) ~= nil
                Expect.holds(held, `{fault.what} made a {one.kind} record`)
            end
        end
        Expect.equal(oneFrom(GUARDED, "a drop").kind, "warn")
        Expect.equal(only(recorded(FAULTS[3]), "a contained fault").kind, "error")
    end),

    -- Where the record was made, on every record there is, since a message is versioned prose and
    -- the position is the only part that says where to look.
    Harness.case("log.data-floor", function()
        for _, fault in FAULTS do
            for _, one in recorded(fault) do
                local file, at = one.data.file, one.data.line
                Expect.holds(typeof(file) == "string", `{fault.what}: no file`)
                Expect.holds(#file > 0, `{fault.what}: an empty file`)
                Expect.holds(typeof(at) == "number", `{fault.what}: no line`)
                Expect.holds(at > 0 and at % 1 == 0, `{fault.what}: line {at}`)
            end
        end
    end),

    -- Who sent the thing the record is about, and the records about nobody.
    Harness.case("log.data-player", function()
        local inbound = opened()
        local sent = only(
            Records.made(function()
                fromClient(inbound, GUARDED)
            end),
            "a client"
        )
        Expect.holds(sent.data.player == inbound.player, `the sender is {sent.data.player}`)

        local outbound = opened()
        local back = only(
            Records.made(function()
                fromServer(outbound, GUARDED)
            end),
            "the server"
        )
        Expect.equal(back.data.player, nil)
    end),

    -- A caller turned away, which the channel never hears about: a refusal is a mistake in the
    -- place's own code, thrown at the line that made it.
    Harness.case("log.refusal-silent", function()
        local made = Records.made(function()
            Expect.throws(function()
                Codecs.int(TOP, 0)
            end, "takes its bounds in order")
        end)
        Expect.equal(#made, 0)

        local held = Group.new()
        held:destroy()
        local after = Records.made(function()
            Expect.throws(function()
                held:has(nil :: any)
            end, "was destroyed")
        end)
        Expect.equal(#after, 0)
    end),

    -- Bytes the schema cannot answer, read by the machine around the codec: the refusal becomes a
    -- record somebody catalogued and stops there.
    Harness.case("codec.decode-drops", function()
        local of = opened()
        local frame = carried(of, function()
            fromClient(of, TAGGED, VARIANTS[1])
        end)

        local dropped: { [string]: boolean } = {}
        for at = 0, buffer.len(frame.bytes) - 1 do
            local hostile = louder(frame, at)
            local held = Records.made(function()
                of.wire:hands(hostile)
            end)
            for _, one in held do
                local code = one.data.code
                Expect.holds(
                    code ~= nil and Catalog.entries[code :: any] ~= nil,
                    `byte {at} was refused as {tostring(code)}, which no row spells`
                )
                dropped[code :: any] = true
            end
        end
        Expect.holds(
            dropped[TAG] ~= nil,
            `nothing in the frame reached the schema's own domain, only {shown(dropped)}`
        )
    end),

    -- A word's field read past the end of its grid, which the word refuses for itself, carrying
    -- the code naming a value outside its domain and the index that arrived.
    Harness.case("log.word-past-its-grid", function()
        local of = opened()
        local frame = carried(of, function()
            fromClient(of, NARROW, { low = 1, high = 2 })
        end)

        local seen = false
        for at = 0, buffer.len(frame.bytes) - 1 do
            local held = Records.made(function()
                of.wire:hands(louder(frame, at))
            end)
            for _, one in held do
                if one.data.code ~= TAG then continue end
                seen = true
                Expect.holds(
                    one.data.got ~= nil and one.data.got ~= 0,
                    `a value past its grid was refused reporting {tostring(one.data.got)}`
                )
            end
        end
        Expect.holds(seen, "no byte of a narrow word was refused for the grid it ran past")
    end),

    -- A payload the boundary turned away, which no listener is handed, while the payload beside
    -- it in the same run still arrives.
    Harness.case("codec.turned-away-reaches-nobody", function()
        local heard: { string } = {}
        local of = Replica.paired({
            space = SPACE,
            defined = defined,
            label = SENDER,
            wires = function(defs: any, side: string)
                if side ~= "server" then return end
                for _, name in { GUARDED, HEARD } do
                    defs[name]:onServer(function()
                        table.insert(heard, name)
                    end)
                end
            end,
        })

        fromClient(of, HEARD)
        Expect.equal(heard, { HEARD })
        fromClient(of, GUARDED)
        Expect.equal(heard, { HEARD })
        fromClient(of, HEARD)
        Expect.equal(heard, { HEARD, HEARD })

        -- Both in one frame, so the turned-away one is a payload the run walks past.
        of.client.defs[GUARDED]:fireServer(true)
        of.client.defs[HEARD]:fireServer(true)
        of.client.session:flush()
        of.wire:settle()
        Expect.equal(heard, { HEARD, HEARD, HEARD })
    end),

    -- A frame cut short of the header its next block needs stops and says so.
    Harness.case("codec.short-block-is-refused", function()
        local heard = 0
        local of = Replica.paired({
            space = SPACE,
            defined = defined,
            label = SENDER,
            wires = function(defs: any, side: string)
                if side ~= "server" then return end
                defs[HEARD]:onServer(function()
                    heard += 1
                end)
            end,
        })

        local frame = carried(of, function()
            fromClient(of, HEARD)
        end)
        Expect.equal(heard, 1)
        for held = 1, buffer.len(frame.bytes) - 1 do
            Records.made(function()
                of.wire:hands(shorter(frame, held))
            end)
            Expect.equal(heard, 1)
        end
    end),

    -- What a drop record says it is about, held by discrimination rather than by wording.
    Harness.case("log.drop-detail", function()
        local first = oneFrom(GUARDED, "the first guard")
        local named = oneFrom(OTHER, "the second guard")
        Expect.equal(first.data.definition, GUARDED)
        Expect.equal(named.data.definition, OTHER)
        Expect.holds(first.message ~= named.message, `both guards read {first.message}`)
    end),

    -- A validator's reason, carried whole.
    Harness.case("codec.validate-rejects", function()
        local first = oneFrom(GUARDED, "the first guard")
        local second = oneFrom(OTHER, "the second guard")
        spells(first.message, REFUSED, "the first guard")
        spells(second.message, DIFFERENT, "the second guard")
        Expect.holds(
            string.find(second.message, REFUSED, 1, true) == nil,
            `the second guard reads {second.message}, which is the first guard's words`
        )
    end),

    -- A listener that raises, the siblings that run anyway, and the record left behind.
    Harness.case("packet.listener-throws", function()
        local of = opened()
        local order = {}
        of.server.defs[HEARD]:onServer(function()
            table.insert(order, "raised")
            error("a listener said no", 0)
        end)
        of.server.defs[HEARD]:onServer(function()
            table.insert(order, "sibling")
        end)

        local held = Records.made(function()
            fromClient(of, HEARD)
        end)
        Expect.equal(order[1], "raised")
        Expect.equal(order[2], "sibling")
        Expect.holds(#held > 0, "a listener raised and nothing was recorded")
    end),

    -- A packet nobody listens for, which is a wiring bug rather than noise: recorded where the
    -- frame is read, and carried on from.
    Harness.case("packet.unheard", function()
        local of = opened()
        local held = Records.made(function()
            fromServer(of, UNHEARD)
        end)
        Expect.holds(#held > 0, "an unheard packet was not recorded")
    end),

    -- A packet whose every listener has since disconnected is as unheard as one nobody ever
    -- listened for, since what counts is who is attached when the frame is read.
    Harness.case("packet.unheard-after-the-last-disconnect", function()
        local of = opened()
        local reached = 0
        local only = of.client.defs[UNHEARD]:onClient(function()
            reached += 1
        end)
        local quiet = Records.made(function()
            fromServer(of, UNHEARD)
        end)
        Expect.equal(reached, 1)
        Expect.equal(#quiet, 0)

        only:disconnect()
        local held = Records.made(function()
            fromServer(of, UNHEARD)
        end)
        Expect.equal(reached, 1)
        Expect.holds(#held > 0, "a packet with no listener left was not recorded")

        -- The same for a block carrying several payloads, which reaches listeners as one batch.
        local batched = Records.made(function()
            for _ = 1, 3 do
                of.server.defs[UNHEARD]:fireClient(of.player, true)
            end
            of.server.session:flush()
            of.wire:settle()
        end)
        Expect.equal(reached, 1)
        Expect.holds(#batched > 0, "a batch with no listener left was not recorded")
    end),
}
