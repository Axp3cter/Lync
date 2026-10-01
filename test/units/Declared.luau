--!strict
--!optimize 2
-- What a declaration has to be before a namespace will carry it, read off the shape a caller
-- declared rather than off the codec under it.

local Codecs = require("@src/codec")
local Legality = require("@src/shape/Legality")
local Protocol = require("@src/wire/Protocol")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local SET = "roster"
local PACKET = "beat"

-- A step a turn does not divide into a whole number of.
local ASKEW = 7

-- A name holding what a descriptor separates its own names with.
local MARKED = "holds;a;mark"

local AT = table.freeze({ file = "Origin", line = 1 })

local function replicating(of: any, key: string?): any
    return { kind = "set" :: "set", of = of, keyField = key, at = AT }
end

local function firing(of: any, unreliable: boolean?, newest: boolean?): any
    return {
        kind = "packet" :: "packet",
        of = of,
        isUnreliable = unreliable == true,
        isNewest = newest == true,
        hz = nil,
        isTimestamped = false,
        at = AT,
    }
end

local function asking(of: any, reply: any): any
    return { kind = "query" :: "query", of = of, reply = reply, at = AT }
end

-- A refusal naming the definition and containing the phrase.
local function refuses(name: string, declared: any, phrase: string)
    local said = Expect.throws(function()
        Legality.definition(name, declared)
    end, phrase)
    Expect.holds(string.find(said, name, 1, true) ~= nil, `it named no definition: {said}`)
    Expect.holds(string.find(said, "Origin:1", 1, true) ~= nil, `it named no site: {said}`)
end

return {
    -- A set says what changed by naming fields, so a record of none has nothing to say.
    Harness.case("declared.set-of-no-fields", function()
        Legality.definition(SET, replicating(Codecs.struct({ held = Codecs.bool() })))
        refuses(SET, replicating(Codecs.struct({})), "no fields")
    end),

    -- An angle whose step does not divide a turn rounds to two indices on two machines.
    Harness.case("declared.set-of-an-imprecise-field", function()
        refuses(SET, replicating(Codecs.struct({ spun = Codecs.angle(ASKEW) })), "divide a turn")
        refuses(SET, replicating(Codecs.struct({ far = Codecs.int(0, 2 ^ 53) })), "counts exactly")
        refuses(
            PACKET,
            firing(Codecs.struct({ deep = Codecs.struct({ spun = Codecs.angle(ASKEW) }) })),
            "divide a turn"
        )
    end),

    Harness.case("declared.refuses-a-name-it-cannot-spell", function()
        local held = replicating(Codecs.struct({ held = Codecs.bool() }))
        Legality.definition(SET, held)
        refuses(MARKED, held, "separates its own names with")
        Expect.holds(Legality.named("plain") == nil, "a plain name was refused")
        Expect.holds(Legality.named("a=b") ~= nil, "an equals sign was taken")
    end),

    Harness.case("declared.set-of-what-is-not-a-record", function()
        refuses(SET, replicating(Codecs.int(0, 1)), "and a set replicates records")
    end),

    -- A key is what a set partitions by, so every record has to answer it with one value that
    -- compares as a table key does and always arrives.
    Harness.case("declared.set-keys", function()
        local of = Codecs.struct({ held = Codecs.bool(), team = Codecs.int(0, 3) })
        Legality.definition(SET, replicating(of, "held"))
        Legality.definition(SET, replicating(of, "team"))
        refuses(SET, replicating(of, "elsewhere"), "which its record does not declare")

        local late = Codecs.struct({ team = Codecs.int(0, 3):newest() })
        refuses(SET, replicating(late, "team"), "a key has to arrive")

        local loose = Codecs.struct({
            owner = Codecs.vlq(),
            delta = Codecs.vli(),
            zone = Codecs.str(0, 4),
        })
        Legality.definition(SET, replicating(loose, "owner"))
        Legality.definition(SET, replicating(loose, "delta"))
        Legality.definition(SET, replicating(loose, "zone"))

        local floating = Codecs.struct({ team = Codecs.f32() })
        refuses(SET, replicating(floating, "team"), "not a value to partition by")
    end),

    -- One dirty mask covers a fixed number of fields.
    Harness.case("declared.set-field-cap", function()
        local fields: { [string]: any } = {}
        for index = 1, Protocol.MAX_FIELDS do
            fields[`f{index}`] = Codecs.bool()
        end
        Legality.definition(SET, replicating(Codecs.struct(fields)))

        fields.extra = Codecs.bool()
        refuses(SET, replicating(Codecs.struct(fields)), "one dirty mask covers")
    end),

    -- A set deltas its own fields, so a marker deeper than one field is refused.
    Harness.case("declared.set-marker-depth", function()
        Legality.definition(SET, replicating(Codecs.struct({ pos = Codecs.f32():newest(10) })))
        local deep = Codecs.struct({ inner = Codecs.struct({ pos = Codecs.f32():newest() }) })
        refuses(SET, replicating(deep), "deltas its own fields")
    end),

    -- A packet and a query keep nothing between frames, so a state marker anywhere in them is
    -- refused, and a packet may name one lane.
    Harness.case("declared.stateless", function()
        Legality.definition(PACKET, firing(Codecs.int(0, 1)))
        Legality.definition(PACKET, firing(Codecs.int(0, 1), true))
        Legality.definition(PACKET, firing(Codecs.int(0, 1), false, true))
        refuses(PACKET, firing(Codecs.int(0, 1), true, true), "two ways of delivering")
        refuses(PACKET, firing(Codecs.struct({ a = Codecs.int(0, 1):newest() })), "keeps nothing")

        local plain = Codecs.int(0, 1)
        Legality.definition("ask", asking(plain, plain))
        refuses("ask", asking(plain, Codecs.struct({ a = plain:newest() })), "ask.response.a")
        refuses("ask", asking(Codecs.struct({ a = plain:newest() }), plain), "ask.request.a")
    end),

    -- A lossy block has to fit one fire.
    Harness.case("declared.block-cap", function()
        local cap = Protocol.UNRELIABLE_CAP
        Legality.block(PACKET, firing(Codecs.int(0, 1)), cap * 2)
        Legality.block(PACKET, firing(Codecs.int(0, 1), true), cap)
        Expect.throws(function()
            Legality.block(PACKET, firing(Codecs.int(0, 1), true), cap + 1)
        end, "one fire carries")
        Expect.throws(function()
            Legality.block(PACKET, firing(Codecs.int(0, 1), false, true), cap + 1)
        end, "is newest")
        Expect.equal(Legality.delivery(firing(Codecs.int(0, 1))), "reliable")
        Expect.equal(Legality.delivery(firing(Codecs.int(0, 1), true)), "unreliable")
        Expect.equal(Legality.delivery(firing(Codecs.int(0, 1), false, true)), "newest")
    end),
}
