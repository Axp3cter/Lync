--!strict
--!optimize 2
-- What a schema reads as, and the one wording a refusal has to borrow from it.

local Compile = require ("@src/shape/Compile")
local Lync = require ("@src")
local Serial = require ("@src/shape/Serial")
local Shape = require ("@src/shape")

local Expect = require ("@test/harness/Expect")
local Generate = require ("@test/harness/Generate")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

const NAMESPACE = "describes"

--[[
    A second namespace, never opened, holding one definition at a time. It is what the containment
    check needs: a namespace whose whole contents are the definition being asked about.
]]
const ALONE = "described"

-- The rate a paced packet declares, which belongs to the frame and not to its codec.
const RATE = 20

-- The field a keyed record partitions by, and the values it takes.
const KEY = "team"
const SIDES = table.freeze ({ "red", "blue" })

--[[
    Two validate functions that answer differently, and a transform either way. Neither pair is ever
    run. A validate is counted in the descriptor and never written, an `as` is left out of it
    entirely, and those two facts are what these four exist to hold.
]]
local function refuses (): string? return "no" end

local function accepts (): string? return nil end

local function lift (of: number): number return of end

local function lower (of: number): number return of end

--[[
    Every codec here is built rather than shared, so two definitions of one layout are never one
    object. What the text has to be a function of is the layout, and a file that reused an instance
    could not tell a serializer that reads the layout from one that reads the identity.
]]
local function counter (): any return Lync.int (0, 100) end

local function asking (): any return Lync.str (1, 8) end

local function answering (): any return Lync.bool () end

-- A record's fields, marked or plain, which is one declaration's worth of difference.
local function fields (marked: boolean): { [string]: any }
    local hp = counter ()
    local pos = Lync.f32 ()

    return {
        hp = if marked then hp:monotonic () else hp,
        pos = if marked then pos:newest () else pos,
        [KEY] = Lync.enum (SIDES),
    }
end

local function record (marked: boolean): any return Lync.struct (fields (marked)) end

--[[
    Every handle this file reads, in the four groups it reads them in: the frame declarations a
    packet carries, the marks a codec carries, the two positions of a query, and a record written
    four ways.
]]
const DEFINITIONS = table.freeze ({
    plain = Lync.packet (counter ()),
    lossy = Lync.packet (counter ()):unreliable (),
    latest = Lync.packet (counter ()):newest (),
    paced = Lync.packet (counter ()):newest (RATE),
    stamped = Lync.packet (counter ()):timestamped (),

    lifted = Lync.packet (counter ():as (lift, lower)),
    checked = Lync.packet (counter ():validate (refuses)),
    otherwise = Lync.packet (counter ():validate (accepts)),
    twice = Lync.packet (counter ():validate (refuses):validate (accepts)),

    asks = Lync.query (asking (), answering ()),
    swapped = Lync.query (answering (), asking ()),
    both = Lync.query (asking (), asking ()),

    roster = Lync.replicate (record (false)),
    again = Lync.replicate (record (false)),
    keyed = Lync.replicate (record (false)):keyBy (KEY),
    marked = Lync.replicate (record (true)),
})

-- Private -------------------------------------------------------------

-- What a handle prints, widened once, because `describe` is not on the handle types.
local function text (of: any): string return of:describe () end

-- Whether a text spelled something out, which is most of what this file reads of one.
local function names (of: string, part: string, what: string)
    if string.find (of, part, 1, true) ~= nil then return end
    Expect.holds (false, `{what} reads {of}, which does not name {part}`)
end

--[[
    Two texts a declaration has to move apart. Only ever asked of a pair that agrees in everything
    else, so a failure names the one declaration that was meant to be in the text and is not.
]]
local function apart (what: string, left: string, right: string)
    if left ~= right then return end
    Expect.holds (false, `{what} both read {left}`)
end

-- How many times a text spells something out, counted without overlapping.
local function counted (of: string, part: string): number
    local found, at = 0, 1
    while true do
        local from, to = string.find (of, part, at, true)
        if from == nil then return found end

        found += 1
        at = (to :: number) + 1
    end
end

--[[
    A codec as the serializer writes one, which is what a handle's text contains and what a refusal
    borrows. Built from the same constructor the definition used rather than reached out of the
    definition, so the two texts come from two builds and agreeing between them is a claim rather
    than an identity.
]]
local function codec (of: any): string return Serial.describe (Shape.build (of, "at")) end

-- A handle compiled on its own, and the namespace text that carries it.
local function carried (of: any)
    local descriptor = Compile.build (ALONE, { lone = of }).descriptor
    names (descriptor, `lone={text (of)}`, "the namespace descriptor")
end

-- Public --------------------------------------------------------------

return {
    Harness.opens (NAMESPACE, DEFINITIONS :: any),

    --[[
        A packet as text: the codec it carries and the declarations deciding how a frame of it
        travels. Asked as differences rather than as a spelling, since what the text reads exactly
        is the goldens' charge and what is asked here is that the text is a function of the layout
        alone.
    ]]
    Harness.case ("describe.packet", function ()
        local plain = text (DEFINITIONS.plain)

        names (plain, codec (counter ()), "a packet")
        carried (Lync.packet (counter ()))

        apart ("plain and unreliable", plain, text (DEFINITIONS.lossy))
        apart ("plain and newest", plain, text (DEFINITIONS.latest))
        apart ("newest and a rate", text (DEFINITIONS.latest), text (DEFINITIONS.paced))
        apart ("plain and timestamped", plain, text (DEFINITIONS.stamped))

        Expect.equal (text (DEFINITIONS.lifted), plain)
        apart ("plain and validated", plain, text (DEFINITIONS.checked))
        apart ("one validate and two", text (DEFINITIONS.checked), text (DEFINITIONS.twice))
        Expect.equal (text (DEFINITIONS.otherwise), text (DEFINITIONS.checked))
    end),

    -- A query as text: both codecs, and which of them is which.
    Harness.case ("describe.query", function ()
        local asks = text (DEFINITIONS.asks)
        local request, reply = codec (asking ()), codec (answering ())

        names (asks, request, "a query")
        names (asks, reply, "a query")
        carried (Lync.query (asking (), answering ()))

        apart ("a query and its inverse", asks, text (DEFINITIONS.swapped))

        local both = text (DEFINITIONS.both)
        local held = counted (both, request)
        Expect.holds (held == 2, `a query of one codec twice reads {both}, naming it {held} times`)
    end),

    --[[
        A set as text: every field, the markers on them, and the key the records partition by. The
        fields are asked by name and by the codec under each, because a text naming the names alone
        would describe two records sharing their fields and no layout, and the markers and the key
        both change the wire.
    ]]
    Harness.case ("describe.set", function ()
        local roster = text (DEFINITIONS.roster)
        Expect.equal (text (DEFINITIONS.again), roster)

        for name, of in fields (false) do
            names (roster, name, "a set")
            names (roster, codec (of), "a set")
        end
        carried (Lync.replicate (record (false)))

        local keyed = text (DEFINITIONS.keyed)
        apart ("a record and the same record keyed", roster, keyed)
        names (keyed, KEY, "a keyed set")

        local marked = text (DEFINITIONS.marked)
        apart ("a record and the same record marked", roster, marked)
        names (marked, "monotonic", "a marked set")
        names (marked, "newest", "a marked set")
    end),

    -- A refusal, and where its wording came from.
    Harness.property ("describe.vocabulary", "kinds", function (rng: Rng.Rng)
        local shape = Generate.shape (rng, 0)
        if shape.at == Generate.TOTAL then return end

        local of = Shape.build (Generate.codec (shape), "at")
        local out = buffer.create (of.maxBytes * 2 + 1)
        local value = Generate.outside (shape, rng)

        Expect.throws (function () of.write (out, 0, value) end, Serial.describe (of))
    end),
}
