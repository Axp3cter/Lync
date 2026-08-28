--!strict
--!optimize 2
-- Every diagnosis the library can reach, reached, so no row of the catalogue is a dead letter.

local Catalog = require ("@src/kernel/Catalog")
local Lync = require ("@src")
local Session = require ("@src/runtime/Session")
local Shape = require ("@src/shape")

local Doubles = require ("@fixtures/Doubles")
local Schemas = require ("@fixtures/Schemas")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Records = require ("@test/harness/Records")
local Turns = require ("@test/harness/Turns")

-- Constants -----------------------------------------------------------

-- The namespace this suite opens under, and the client every frame it reads is attributed to.
const SPACE = "catalogue"
const SENDER = "alice"

-- The definitions the session half drives, each carrying a shape the codec half cannot reach.
const PLAIN = "plain"
const HOLDER = "holder"
const REFERRED = "referred"

-- The class a reference is declared as, and the class the stubs actually are.
const WANTED = "Part"
const STAND_IN = "Folder"

-- The player who joins and never speaks, whose name is what a frame attributed to them carries.
const QUIET = "bob"

-- The one who is still joining when a frame arrives for them.
const LATE = "carol"

-- The one field a record carries, the width it is padded to, and the id it is filed under.
const TEXT = "text"
const WIDE = 8
const ID = 1

-- The bound the packet's value is drawn inside.
const TOP = 100

-- The two lanes this file names, one for ordinary traffic and one for introductions.
const RELIABLE: Doubles.Channel = "reliable"
const HANDSHAKE: Doubles.Channel = "handshake"

-- The bytes a sweep writes over a position: none of the bits, the low seven, and all of them.
const HOSTILE = table.freeze ({ 0x00, 0x7F, 0xFF })

-- Types ---------------------------------------------------------------

-- Two machines on one lane, and the handles the server sends through.
type Run = {
    read wire: Doubles.Wire,
    read roster: Doubles.Roster,
    read player: Player,
    read silent: Player,
    read server: Session.Session,
    read defs: any,
}

--[[
    What one sweep found: which rows of the catalogue something reached, and every record that named
    no row.
]]
type Survey = { read seen: { [string]: boolean }, read loose: { string } }

-- Private -------------------------------------------------------------

--[[
    The definitions one machine requires, built fresh once a side. A packet and a set, because a
    section's own framing is refused in a place a packet's bytes never reach.
]]
local function defined (): any
    return {
        [PLAIN] = Lync.packet (Lync.int (0, TOP)),
        [HOLDER] = Lync.replicate (Lync.struct ({ [TEXT] = Lync.str (1, WIDE) })),
        [REFERRED] = Lync.packet (Lync.inst (WANTED)),
    }
end

--[[
    Two machines started and settled, with a second player standing by who never opens a session.

    Settled before it is handed back, so the handshake is behind both of them and every frame a
    check catches afterwards is one this file caused.
]]
local function opened (): Run
    local wire = Doubles.wire ()
    local roster = Doubles.roster ()

    local defs = defined ()
    for _, name in { PLAIN, REFERRED } do
        defs[name]:onServer (function () end)
    end

    local server = Session.new (SPACE, defs, wire:server (), roster, "server")
    server:start ()

    local player = roster:join (SENDER)
    local clientDefs = defined ()
    for _, name in { PLAIN, REFERRED } do
        clientDefs[name]:onClient (function () end)
    end

    Session.new (SPACE, clientDefs, wire:client (player), roster, "client"):start ()
    wire:settle ()

    return {
        wire = wire,
        roster = roster,
        player = player,
        silent = roster:join (QUIET),
        server = server,
        defs = defs,
    }
end

--[[
    Whatever the library recorded while `run` ran, with every code it named noted down.

    Records rather than raises, because past the boundary a refusal is no longer a thrown table.
    This is the same diagnosis read one layer up, which is where a caller reads it.
]]
local function noting (into: Survey, run: () -> ())
    for _, one in Records.made (run) do
        local code = one.data.code
        if code ~= nil and Catalog.entries[code :: any] ~= nil then
            into.seen[code :: any] = true
            continue
        end

        local said = if code == nil then "no code at all" else `the code {code}`
        table.insert (into.loose, `a {one.kind} carrying {said}: {one.message}`)
    end
end

-- The last frame a piece of work put on one lane, which is what a sweep then takes apart.
local function caught (of: Run, lane: string, run: () -> ()): Doubles.Carried?
    local frames: { Doubles.Carried } = {}
    local stop = of.wire:watch (function (frame: Doubles.Carried)
        if frame.at ~= lane then return end

        table.insert (frames, frame)
    end)

    run ()
    stop ()
    return frames[#frames]
end

--[[
    One frame handed back to a machine once per byte it has, each time with that byte turned to
    something the sender would not have written.
]]
local function replays (into: Survey, of: Run, frame: Doubles.Carried, from: Player?, to: Player?)
    for at = 0, buffer.len (frame.bytes) - 1 do
        for _, byte in HOSTILE do
            local bytes = buffer.create (buffer.len (frame.bytes))
            buffer.copy (bytes, 0, frame.bytes)
            buffer.writeu8 (bytes, at, byte)

            local hostile: Doubles.Carried =
                { at = frame.at, from = from, to = to, bytes = bytes, refs = frame.refs }

            noting (into, function () of.wire:hands (hostile) end)
        end
    end

    --[[
        The same frame cut short at every length it could arrive at. A corrupted byte reaches a
        header that says the wrong thing, and a cut reaches one that is not all there, which is a
        different refusal and one no length of frame should be needed to provoke.
    ]]
    for size = 0, buffer.len (frame.bytes) - 1 do
        local bytes = buffer.create (size)
        buffer.copy (bytes, 0, frame.bytes, 0, size)

        local hostile: Doubles.Carried =
            { at = frame.at, from = from, to = to, bytes = bytes, refs = frame.refs }

        noting (into, function () of.wire:hands (hostile) end)
    end
end

-- A read of hostile bytes, with whatever it refused with noted down.
local function refused (seen: { [string]: boolean }, of: any, text: string)
    local ok, why = pcall (of.read, Turns.held (text), 0, Turns.CTX)
    if ok or type (why) ~= "table" then return end

    local code = (why :: any).code
    if code ~= nil then seen[code] = true end
end

-- Every codec in the fixture corpus, read back from bytes that are nearly its own.
local function sweeps (seen: { [string]: boolean })
    for _, fixture in Schemas.all do
        local of = Shape.build (fixture.codec, fixture.name)
        for _, case in fixture.cases do
            local bytes = Turns.text (of, case.value)

            for at = 1, #bytes do
                local before, after = string.sub (bytes, 1, at - 1), string.sub (bytes, at + 1)
                for _, byte in HOSTILE do
                    refused (seen, of, `{before}{string.char (byte)}{after}`)
                end

                refused (seen, of, before)
            end
        end
    end
end

-- A client mid-join, handed one frame before its verdict has come back.
local function joining (bytes: buffer)
    local wire = Doubles.wire ()
    local roster = Doubles.roster ()

    Session.new (SPACE, defined (), wire:server (), roster, "server"):start ()

    local who = roster:join (LATE)
    local mine = defined ()
    for _, name in { PLAIN, REFERRED } do
        mine[name]:onClient (function () end)
    end

    Session.new (SPACE, mine, wire:client (who), roster, "client"):start ()
    wire:hands ({ at = RELIABLE, from = nil, to = who, bytes = bytes })
end

--[[
    A namespace of a different shape, opened on a lane of its own, as the hello it introduces itself
    with.
]]
local function apart (): any return { [PLAIN] = Lync.packet (Lync.bool ()) } end

local function stranger (): Doubles.Carried?
    local wire = Doubles.wire ()
    local roster = Doubles.roster ()

    local held: { Doubles.Carried } = {}
    wire:watch (function (frame: Doubles.Carried)
        if frame.at ~= HANDSHAKE or frame.from == nil then return end

        table.insert (held, frame)
    end)

    Session.new (SPACE, apart (), wire:server (), roster, "server"):start ()

    local who = roster:join (SENDER)
    local mine = apart ()
    mine[PLAIN]:onClient (function () end)

    Session.new (SPACE, mine, wire:client (who), roster, "client"):start ()
    wire:settle ()

    return held[#held]
end

-- Every hostile input this file knows how to make, run once, with what came back.
local function surveyed (): Survey
    local into: Survey = { seen = {}, loose = {} }
    local seen = into.seen
    sweeps (seen)

    local of = opened ()

    -- A packet's frame, which is where a definition's own number rides.
    local fired = caught (of, RELIABLE, function ()
        of.defs[PLAIN]:fireClient (of.player, TOP)
        of.server:flush ()
        of.wire:settle ()
    end)
    if fired ~= nil then
        replays (into, of, fired, of.player, nil)
        replays (into, of, fired, nil, of.player)
    end

    -- A set's frame, whose sections are framed in ways a packet has no room to be wrong in.
    local shipped = caught (of, RELIABLE, function ()
        of.defs[HOLDER]:add (ID, { [TEXT] = string.rep ("x", WIDE) })
        of.server:flush ()
        of.wire:settle ()
    end)
    if shipped ~= nil then
        replays (into, of, shipped, of.player, nil)
        replays (into, of, shipped, nil, of.player)
    end

    -- A reference of a class the schema did not declare.
    local referred = caught (of, RELIABLE, function ()
        of.defs[REFERRED]:fireClient (of.player, Instance.new (WANTED))
        of.server:flush ()
        of.wire:settle ()
    end)

    if referred ~= nil then
        local wrong: Doubles.Carried = {
            at = referred.at,
            from = nil,
            to = of.player,
            bytes = referred.bytes,
            refs = { { Instance.new (STAND_IN) } },
        }
        noting (into, function () of.wire:hands (wrong) end)
    end

    -- A frame from somebody the server has never heard from.
    if fired ~= nil then
        noting (
            into,
            function ()
                of.wire:hands ({
                    at = fired.at,
                    from = of.silent,
                    to = nil,
                    bytes = fired.bytes,
                    refs = fired.refs,
                })
            end
        )
    end

    --[[
        The handshake lane carrying something that is not a hello, and then a hello from a machine
        holding a different schema under this name.
    ]]
    noting (
        into,
        function ()
            of.wire:hands ({
                at = HANDSHAKE,
                from = of.player,
                to = nil,
                bytes = buffer.create (1),
            })
        end
    )

    local other = stranger ()
    if other ~= nil then
        noting (
            into,
            function ()
                of.wire:hands ({
                    at = HANDSHAKE,
                    from = of.silent,
                    to = nil,
                    bytes = other.bytes,
                })
            end
        )
    end

    --[[
        A frame reaching a client that has asked to join and has not been answered. A server
        broadcasts to everyone the engine knows about, so this is an ordinary part of a join rather
        than a mistake, and it is still a payload that went nowhere.
    ]]
    if fired ~= nil then noting (into, function () joining (fired.bytes) end) end

    return into
end

-- Public --------------------------------------------------------------

return {
    -- Every row of the catalogue, reached by something.
    Harness.case ("log.catalog-complete", function ()
        local seen = surveyed ().seen

        local missing = {}
        for code in Catalog.entries do
            if seen[code] then continue end
            table.insert (missing, code)
        end

        table.sort (missing)
        Expect.holds (#missing == 0, `nothing reaches {table.concat (missing, ", ")}`)
    end),

    --[[
        Nothing reaching a caller that the catalogue does not spell. A record carrying a code no row
        explains is something that happened to somebody's game with nothing they can branch on,
        arriving exactly when they are least able to work it out.
    ]]
    Harness.case ("log.catalog-closed", function ()
        local loose = surveyed ().loose
        Expect.holds (#loose == 0, `{#loose} records name no row: {table.concat (loose, " | ")}`)
    end),
}
