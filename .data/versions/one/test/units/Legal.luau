--!strict
--!optimize 2
-- What a declaration or a write has to be before the other side is trusted to take it: refused
-- where it is written, rather than where the receiver gives up the frame it rode in.

local Compile = require("@src/shape/Compile")
local Define = require("@src/api/Define")
local Legality = require("@src/shape/Legality")
local Lync = require("@src")
local Protocol = require("@src/wire/Protocol")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local SET = "roster"
local AT = table.freeze({ file = "Origin", line = 1 })

local function replicating(of: any, key: string?): any
    return { kind = "set" :: "set", of = of, keyField = key, at = AT }
end

-- A refusal naming the definition and containing the phrase.
local function refuses(declared: any, phrase: string)
    local said = Expect.throws(function()
        Legality.definition(SET, declared)
    end, phrase)
    Expect.holds(string.find(said, "Origin:1", 1, true) ~= nil, `it named no site: {said}`)
end

local function same(value: any): any
    return value
end

local function fine(_: any): string?
    return nil
end

-- A write that comes back, and one refused naming where it was.
local function writes(codec: any, value: any)
    Lync.encode(codec, value)
end

local function refusesWrite(codec: any, value: any, path: string)
    Expect.throws(function()
        writes(codec, value)
    end, path)
end

return {
    -- An instance is held to its class on the way out, nil is no instance at all, and a slot a
    -- wider field already filed for the same instance is no pass for a narrower one.
    Harness.case("legal.inst-write", function()
        local part = Lync.inst("BasePart")
        writes(part, nil)
        writes(part, Instance.new("Part"))
        refusesWrite(part, Instance.new("Folder"), "encode")
        refusesWrite(part, {}, "encode")
        refusesWrite(part, "Workspace", "encode")

        local any = Lync.inst()
        writes(any, Instance.new("Folder"))
        refusesWrite(any, {}, "encode")

        local pair = Lync.struct({ a = Lync.inst(), b = Lync.inst("BasePart") })
        local folder = Instance.new("Folder")
        refusesWrite(pair, { a = folder, b = folder }, "encode.b")
    end),

    -- A packet's rate is held as a field's: above zero and short of forever.
    Harness.case("legal.packet-newest-rate", function()
        Lync.packet(Lync.bool()):newest()
        Lync.packet(Lync.bool()):newest(20)
        for _, hz in { 0, -1, math.huge, 0 / 0 } do
            Expect.throws(function()
                Lync.packet(Lync.bool()):newest(hz)
            end, "rate above zero")
        end
    end),

    -- A newest field streams a record at a time, so one record of it has to fit one fire.
    Harness.case("legal.set-newest-cap", function()
        local cap = Protocol.UNRELIABLE_CAP
        local fits = replicating(Lync.struct({ id = Lync.vlq(), text = Lync.str(0, 900):newest() }))
        Compile.build("LegalFits", { [SET] = fits })

        local wide = replicating(Lync.struct({ text = Lync.str(0, 2000):newest() }))
        Expect.throws(function()
            Compile.build("LegalWide", { [SET] = wide })
        end, `past the {cap} one fire carries`)

        -- The key leads every section, so it is counted against the same fire.
        local keyed = replicating(
            Lync.struct({ zone = Lync.str(0, 500), text = Lync.str(0, 500):newest() }),
            "zone"
        )
        Expect.throws(function()
            Compile.build("LegalKeyed", { [SET] = keyed })
        end, `{SET}.text`)
    end),

    -- A key partitions exactly, so only the kinds that compare exactly are keys, and neither a
    -- transform nor a check may stand between the value and what the wire spells.
    Harness.case("legal.set-keys-exact", function()
        local exact = Lync.struct({
            a = Lync.bool(),
            b = Lync.int(0, 10),
            c = Lync.enum({ "x", "y" }),
            d = Lync.vlq(),
            e = Lync.vli(),
            f = Lync.str(0, 8),
        })
        for _, key in { "a", "b", "c", "d", "e", "f" } do
            Legality.definition(SET, replicating(exact, key))
        end

        refuses(
            replicating(Lync.struct({ zone = Lync.quant(0, 10, 1) }), "zone"),
            "compare exactly"
        )
        refuses(replicating(Lync.struct({ zone = Lync.angle(90) }), "zone"), "compare exactly")
        refuses(
            replicating(Lync.struct({ zone = Lync.int(0, 10):as(same, same) }), "zone"),
            "declares as on it"
        )
        refuses(
            replicating(Lync.struct({ zone = Lync.int(0, 10):validate(fine) }), "zone"),
            "declares a validate"
        )
    end),

    -- A set's values come from the server, so a check anywhere in its record is refused, and a
    -- transform off the key stays.
    Harness.case("legal.set-validate", function()
        Legality.definition(SET, replicating(Lync.struct({ hp = Lync.int(0, 10):as(same, same) })))

        refuses(
            replicating(Lync.struct({ hp = Lync.int(0, 10):validate(fine) })),
            `validate at {SET}.hp`
        )
        refuses(
            replicating(Lync.struct({ pos = Lync.vec2(Lync.quant(0, 1, 0.5):validate(fine)) })),
            `validate at {SET}.pos.component`
        )
        refuses(
            replicating(Lync.struct({ tags = Lync.array(Lync.str(0, 4):validate(fine), 0, 4) })),
            `validate at {SET}.tags.element`
        )
        refuses(replicating(Lync.struct({ hp = Lync.bool() }):validate(fine)), `validate at {SET}`)
    end),

    -- A bitfield names its flags as a record names its fields, and takes no others.
    Harness.case("legal.bitfield-names", function()
        local flags = Lync.bitfield({ "a", "b" })
        writes(flags, { a = true })
        writes(flags, {})
        refusesWrite(flags, { a = true, zzz = true }, "encode")
    end),

    Harness.case("legal.define-name", function()
        Expect.throws(function()
            Define.define(nil :: any, {})
        end, "named by a string, not a nil")
        Expect.throws(function()
            Define.define(5 :: any, {})
        end, "not a number")
    end),
    -- A definition whose worst case no remote call could carry is refused at start, before a
    -- buffer is sized for it.
    Harness.case("legal.fits-one-call", function()
        local huge = Lync.str(0, Protocol.MAX_FIRE)
        local function firing(of: any): any
            return {
                kind = "packet" :: "packet",
                of = of,
                isUnreliable = false,
                isNewest = false,
                isTimestamped = false,
                at = AT,
            }
        end
        Expect.throws(function()
            Compile.build("Big", { Huge = firing(huge) } :: any)
        end, "past the 1000000 one remote call carries")
        Expect.throws(function()
            Compile.build("Big", { Wide = replicating(Lync.struct({ text = huge })) } :: any)
        end, "past the 1000000 one remote call carries")
        Compile.build("Big", { Fine = firing(Lync.str(0, 1000)) } :: any)
    end),
}
