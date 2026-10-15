--!strict
--!optimize 2
-- Every diagnosis the library can reach, reached, so no row of the catalogue is a dead letter.

local Catalog = require("@src/kernel/Catalog")
local Codecs = require("@src/codec")
local Packet = require("@src/api/Packet")
local Protocol = require("@src/wire/Protocol")
local Session = require("@src/runtime/Session")
local Set = require("@src/api/Set")
local Shape = require("@src/shape")

local Doubles = require("@fixtures/Doubles")
local Schemas = require("@fixtures/Schemas")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Records = require("@test/harness/Records")
local Turns = require("@test/harness/Turns")

-- The namespace this suite opens under, the client every frame is attributed to, the player who
-- joins and never speaks, and the one still joining when a frame arrives.
local SPACE = "catalogue"
local SENDER = "alice"
local QUIET = "bob"
local LATE = "carol"

-- The definitions the session half drives, each carrying a shape the codec half cannot reach.
local PLAIN = "plain"
local HOLDER = "holder"
local REFERRED = "referred"

-- The class a reference is declared as, and the class the stubs actually are.
local WANTED = "Part"
local STAND_IN = "Folder"

local TEXT = "text"
local WIDE = 8
local ID = 1
local TOP = 100

local RELIABLE: Doubles.Channel = "reliable"
local HANDSHAKE: Doubles.Channel = "handshake"

-- The bytes a sweep writes over a position: none of the bits, the low seven, and all of them.
local HOSTILE = table.freeze({ 0x00, 0x7F, 0xFF })

-- How many frames a client keeps before its verdict.
local KEPT = Protocol.EARLY_FRAMES

-- Two machines on one lane, and the handles the server sends through.
type Run = {
    read wire: Doubles.Wire,
    read roster: Doubles.Roster,
    read player: Player,
    read silent: Player,
    read server: Session.Session,
    read defs: any,
}

-- What one sweep found: which rows something reached, and every record that named no row.
type Survey = { read seen: { [string]: boolean }, read loose: { string } }

-- The definitions one machine requires: a packet, a set and a reference, built fresh once a side.
local function defined(): any
    return {
        [PLAIN] = Packet.new(Codecs.int(0, TOP)),
        [HOLDER] = Set.new(Codecs.struct({ [TEXT] = Codecs.str(1, WIDE) })),
        [REFERRED] = Packet.new(Codecs.inst(WANTED)),
    }
end

-- Two machines started and settled, with a second player standing by who never opens a session.
local function opened(): Run
    local wire = Doubles.wire()
    local roster = Doubles.roster()
    local defs = defined()
    for _, name in { PLAIN, REFERRED } do
        defs[name]:onServer(function() end)
    end
    local server = Session.new(SPACE, defs, wire:server(), roster, "server")
    server:start()

    local player = roster:join(SENDER)
    local theirs = defined()
    for _, name in { PLAIN, REFERRED } do
        theirs[name]:onClient(function() end)
    end
    Session.new(SPACE, theirs, wire:client(player), roster, "client"):start()
    wire:settle()
    return {
        wire = wire,
        roster = roster,
        player = player,
        silent = roster:join(QUIET),
        server = server,
        defs = defs,
    }
end

-- Whatever the library recorded while `run` ran, with every code it named noted down. Records
-- rather than raises, because past the boundary a refusal is no longer a thrown table.
local function noting(into: Survey, run: () -> ())
    for _, one in Records.made(run) do
        local code = one.data.code
        if code ~= nil and Catalog.entries[code :: any] ~= nil then
            into.seen[code :: any] = true
            continue
        end
        local said = if code == nil then "no code at all" else `the code {code}`
        table.insert(into.loose, `a {one.kind} carrying {said}: {one.message}`)
    end
end

-- The last frame a piece of work put on one lane, which is what a sweep then takes apart.
local function caught(of: Run, lane: string, run: () -> ()): Doubles.Carried?
    local frames: { Doubles.Carried } = {}
    local stop = of.wire:watch(function(frame: Doubles.Carried)
        if frame.at == lane then table.insert(frames, frame) end
    end)
    run()
    stop()
    return frames[#frames]
end

-- One frame handed back once per byte with that byte turned hostile, then cut short at every
-- length it could arrive at.
local function replays(into: Survey, of: Run, frame: Doubles.Carried, from: Player?, to: Player?)
    local size = buffer.len(frame.bytes)
    local function handed(bytes: buffer)
        noting(into, function()
            of.wire:hands({ at = frame.at, from = from, to = to, bytes = bytes, refs = frame.refs })
        end)
    end
    for at = 0, size - 1 do
        for _, byte in HOSTILE do
            local bytes = buffer.create(size)
            buffer.copy(bytes, 0, frame.bytes)
            buffer.writeu8(bytes, at, byte)
            handed(bytes)
        end
    end
    for cut = 0, size - 1 do
        local bytes = buffer.create(cut)
        buffer.copy(bytes, 0, frame.bytes, 0, cut)
        handed(bytes)
    end
end

local function refused(seen: { [string]: boolean }, of: any, text: string)
    local ok, why = pcall(of.read, Turns.held(text), 0, Turns.CTX)
    if ok or type(why) ~= "table" then return end
    local code = (why :: any).code
    if code ~= nil then seen[code] = true end
end

-- Every codec in the fixture corpus, read back from bytes that are nearly its own, and a value a
-- validate turns away.
local function sweeps(seen: { [string]: boolean })
    local checked = Shape.build(
        Codecs.int(0, 100):validate(function(value: number): string?
            return if value % 5 == 0 then nil else "not a step of five"
        end),
        "checked"
    )
    refused(seen, checked, Turns.text(checked, 3))
    for _, fixture in Schemas.all do
        local of = Shape.build(fixture.codec, fixture.name)
        for _, one in fixture.cases do
            local bytes = Turns.text(of, one.value)
            for at = 1, #bytes do
                local before, after = string.sub(bytes, 1, at - 1), string.sub(bytes, at + 1)
                for _, byte in HOSTILE do
                    refused(seen, of, `{before}{string.char(byte)}{after}`)
                end
                refused(seen, of, before)
            end
        end
    end
end

-- A client mid-join, handed more frames before its verdict than it keeps for after it.
local function joining(bytes: buffer)
    local wire = Doubles.wire()
    local roster = Doubles.roster()
    Session.new(SPACE, defined(), wire:server(), roster, "server"):start()
    local who = roster:join(LATE)
    local mine = defined()
    for _, name in { PLAIN, REFERRED } do
        mine[name]:onClient(function() end)
    end
    Session.new(SPACE, mine, wire:client(who), roster, "client"):start()
    for _ = 1, KEPT + 1 do
        wire:hands({ at = RELIABLE, from = nil, to = who, bytes = bytes })
    end
end

-- A namespace of a different shape opened on a lane of its own, as the hello it introduces
-- itself with.
local function stranger(): Doubles.Carried?
    local wire = Doubles.wire()
    local roster = Doubles.roster()
    local held: { Doubles.Carried } = {}
    wire:watch(function(frame: Doubles.Carried)
        if frame.at == HANDSHAKE and frame.from ~= nil then table.insert(held, frame) end
    end)
    local theirs: any = { [PLAIN] = Packet.new(Codecs.bool()) }
    Session.new(SPACE, theirs, wire:server(), roster, "server"):start()
    local who = roster:join(SENDER)
    local mine: any = { [PLAIN] = Packet.new(Codecs.bool()) }
    mine[PLAIN]:onClient(function() end)
    Session.new(SPACE, mine, wire:client(who), roster, "client"):start()
    wire:settle()
    return held[#held]
end

-- Every hostile input this file knows how to make, run once, with what came back.
local function surveyed(): Survey
    local into: Survey = { seen = {}, loose = {} }
    sweeps(into.seen)
    local of = opened()

    -- A packet's frame, where a definition's own number rides.
    local fired = caught(of, RELIABLE, function()
        of.defs[PLAIN]:fireClient(of.player, TOP)
        of.server:flush()
        of.wire:settle()
    end)
    if fired ~= nil then
        replays(into, of, fired, of.player, nil)
        replays(into, of, fired, nil, of.player)
    end

    -- A set's frame, whose sections are framed in ways a packet has no room to be wrong in.
    local shipped = caught(of, RELIABLE, function()
        of.defs[HOLDER]:add(ID, { [TEXT] = string.rep("x", WIDE) })
        of.server:flush()
        of.wire:settle()
    end)
    if shipped ~= nil then
        replays(into, of, shipped, of.player, nil)
        replays(into, of, shipped, nil, of.player)
    end

    -- A reference of a class the schema did not declare.
    local referred = caught(of, RELIABLE, function()
        of.defs[REFERRED]:fireClient(of.player, Instance.new(WANTED))
        of.server:flush()
        of.wire:settle()
    end)
    if referred ~= nil then
        noting(into, function()
            of.wire:hands({
                at = referred.at,
                from = nil,
                to = of.player,
                bytes = referred.bytes,
                refs = { { Instance.new(STAND_IN) } },
            })
        end)
    end

    -- A frame from somebody the server has never heard from, the handshake lane carrying no hello,
    -- a hello from a machine holding another schema under this name, and a frame reaching a client
    -- still joining.
    if fired ~= nil then
        noting(into, function()
            of.wire:hands({ at = fired.at, from = of.silent, to = nil, bytes = fired.bytes })
        end)
        noting(into, function()
            joining(fired.bytes)
        end)
    end
    noting(into, function()
        of.wire:hands({ at = HANDSHAKE, from = of.player, to = nil, bytes = buffer.create(1) })
    end)
    local other = stranger()
    if other ~= nil then
        noting(into, function()
            of.wire:hands({ at = HANDSHAKE, from = of.silent, to = nil, bytes = other.bytes })
        end)
    end
    return into
end

return {
    -- Every row of the catalogue reached by something, and nothing reaching a caller that the
    -- catalogue does not spell.
    Harness.case("log.catalog-complete-and-closed", function()
        local survey = surveyed()
        local missing = {}
        for code in Catalog.entries do
            if not survey.seen[code] then table.insert(missing, code) end
        end
        table.sort(missing)
        Expect.holds(#missing == 0, `nothing reaches {table.concat(missing, ", ")}`)
        local loose = survey.loose
        Expect.holds(#loose == 0, `{#loose} records name no row: {table.concat(loose, " | ")}`)
    end),
}
