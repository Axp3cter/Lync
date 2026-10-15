--!strict
--!optimize 2
-- The descriptor: the text a schema writes as, the interner, and the hash a handshake carries.

local Base = require("@src/codec/Base")
local Codecs = require("@src/codec")
local Serial = require("@src/shape/Serial")
local Wide = require("@src/kernel/Wide")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Limbs = require("@test/harness/Limbs")
local Rng = require("@test/harness/Rng")

-- FNV-1a's two constants, the algorithm's rather than the library's, so stated here.
local BASIS = "CBF29CE484222325"
local PRIME = "00000100000001B3"

local NOTABLE = table.freeze({ 0, 1, 0x7F, 0x80, 0xFE, 0xFF })
local MOST = 48

local BASIS_LIMBS = table.freeze(Limbs.of(BASIS))
local PRIME_LIMBS = table.freeze(Limbs.of(PRIME))

-- The same fold in sixteen-bit limbs, sharing no instruction with the thing it checks.
local function folded(text: string): Limbs.Limbs
    local h = table.clone(BASIS_LIMBS)
    for index = 1, #text do
        h[1] = bit32.bxor(h[1], string.byte(text, index))
        h = Limbs.times(h, PRIME_LIMBS)
    end
    return h
end

local function drawn(rng: Rng.Rng): string
    local count = rng:int(0, MOST)
    local out = table.create(count) :: { string }
    for _ = 1, count do
        local byte = if rng:bool() then rng:pick(NOTABLE) else rng:int(0, 255)
        table.insert(out, string.char(byte))
    end
    return table.concat(out)
end

-- Every octet, four times over.
local function every(): string
    local out = table.create(256 * 4) :: { string }
    for _ = 1, 4 do
        for byte = 0, 255 do
            table.insert(out, string.char(byte))
        end
    end
    return table.concat(out)
end

local function described(of: any): string
    return Serial.describe({ cell = Base.cell(of) })
end

return {
    -- A descriptor of nothing hashes to the offset basis.
    Harness.case("serial.basis", function()
        Expect.equal(Wide.toHex(Serial.hash("")), BASIS)
    end),

    -- The standard's own vectors, which also prove the wrap on the first multiply.
    Harness.case("serial.vectors", function()
        for _, vector in
            {
                { text = "a", hash = "AF63DC4C8601EC8C" },
                { text = "b", hash = "AF63DF4C8601F1A5" },
                { text = "c", hash = "AF63DE4C8601EFF2" },
                { text = "d", hash = "AF63D94C8601E773" },
                { text = "e", hash = "AF63D84C8601E5C0" },
                { text = "f", hash = "AF63DB4C8601EAD9" },
                { text = "fo", hash = "08985907B541D342" },
                { text = "foo", hash = "DCB27518FED9D577" },
                { text = "foob", hash = "DD120E790C2512AF" },
                { text = "fooba", hash = "CAC165AFA2FEF40A" },
                { text = "foobar", hash = "85944171F73967E8" },
            }
        do
            local got = Wide.toHex(Serial.hash(vector.text))
            Expect.holds(got == vector.hash, `"{vector.text}" hashed {got}, not {vector.hash}`)
        end
    end),

    -- Every octet is a byte the fold counts, none included, and none above 0x7F reads negative.
    Harness.case("serial.bytes", function()
        Expect.equal(Wide.toHex(Serial.hash("\0")), "AF63BD4C8601B7DF")
        Expect.equal(Wide.toHex(Serial.hash("\255")), "AF64724C8602EB6E")
        Expect.equal(Wide.toHex(Serial.hash("\0\0")), "08328807B4EB6FED")

        local seen = {}
        for byte = 0, 255 do
            local answer = Wide.toHex(Serial.hash(string.char(byte)))
            Expect.holds(seen[answer] == nil, `byte {byte} hashed as byte {seen[answer]} did`)
            seen[answer] = byte
        end
    end),

    Harness.case("serial.long", function()
        Expect.equal(Wide.toHex(Serial.hash(every())), "1E5698F9D66E6F25")
    end),

    Harness.property("serial.folds", "leaves", function(rng: Rng.Rng)
        local text = drawn(rng)
        Expect.equal(Wide.toHex(Serial.hash(text)), Limbs.hex(folded(text)))
    end),

    -- A node reads the way a caller wrote it, parameters in surface order, children sorted.
    Harness.case("serial.describe", function()
        Expect.equal(described(Codecs.int(0, 100)), "int(0,100)")
        Expect.equal(described(Codecs.str.alphabet("abc", 0, 6)), 'str("abc",0,6)')
        Expect.equal(described(Codecs.vec3.unit(1)), "vec3(unit,1)")
        Expect.equal(described(Codecs.quant(0, 1, 0.1)), "quant(0,1,0.1)")
        Expect.equal(described(Codecs.enum({ "b", "a" })), 'enum(["a","b"])')
        Expect.equal(described(Codecs.inst("Part")), 'inst("Part")')
        Expect.equal(
            described(Codecs.struct({ b = Codecs.bool(), a = Codecs.f32() })),
            'struct(){"a"=f32();"b"=bool();}'
        )
        Expect.equal(
            described(Codecs.tagged("k", { v = Codecs.struct({}) })),
            'tagged("k"){"v"=struct(){};}'
        )
    end),

    -- Marks and validators are part of the text, and a quoted name escapes its own marks.
    Harness.case("serial.describe-marks", function()
        Expect.equal(described(Codecs.int(0, 1):newest()), "int(0,1):newest")
        Expect.equal(described(Codecs.int(0, 1):newest(20)), "int(0,1):newest(20)")
        Expect.equal(
            described(Codecs.int(0, 1):validate(function()
                return nil
            end)),
            "int(0,1):validate"
        )
        Expect.equal(
            described(Codecs.struct({ ['a"b'] = Codecs.bool() })),
            'struct(){"a\\"b"=bool();}'
        )
    end),

    -- A number is written so it reads back to itself, never rounded into a neighbour.
    Harness.case("serial.decimals", function()
        Expect.equal(described(Codecs.quant(0, 1, 1 / 3)), "quant(0,1,0.33333333333333331)")
        Expect.equal(described(Codecs.quant(0, 1, 0.25)), "quant(0,1,0.25)")
        Expect.equal(described(Codecs.quant(0, 1, 0.1 + 0.2)), "quant(0,1,0.30000000000000004)")
        Expect.equal(described(Codecs.int(-5, 2 ^ 40)), "int(-5,1099511627776)")

        -- A negative zero spells as zero, so a bound written -0 hashes the same as one written 0.
        Expect.equal(described(Codecs.int(-0, 5)), described(Codecs.int(0, 5)))
        Expect.equal(described(Codecs.quant(-0, 1, 0.5)), "quant(0,1,0.5)")
    end),

    -- A frame carries its delivery and rate, and a namespace opens with its name.
    Harness.case("serial.frames", function()
        local of = { cell = Base.cell(Codecs.bool()) }
        local packet: Serial.Frame = {
            kind = "packet",
            of = of,
            delivery = "newest",
            hz = 20,
            timestamped = true,
        }
        Expect.equal(Serial.frame(packet), "packet[newest,20,true](bool())")

        local query: Serial.Frame = { kind = "query", of = of, reply = of }
        Expect.equal(Serial.frame(query), "query(bool())(bool())")

        local set: Serial.Frame = { kind = "set", of = of, keyField = "team" }
        Expect.equal(Serial.frame(set), 'set["team"](bool())')
        Expect.equal(Serial.frame({ kind = "set", of = of, keyField = nil }), "set[](bool())")

        local text = Serial.namespace("arena", { z = set, a = query })
        Expect.equal(text, 'arena;a=query(bool())(bool());z=set["team"](bool())')
    end),

    -- The same text twice is the same number, and a tag is two of them.
    Harness.case("serial.interner", function()
        local held = Serial.interner()
        Expect.equal(Serial.intern(held, "a"), 1)
        Expect.equal(Serial.intern(held, "b"), 2)
        Expect.equal(Serial.intern(held, "a"), 1)
        Expect.equal(held.texts, { "a", "b" })
        Expect.equal(Serial.under("root", "hp"), "root.hp")

        local paths, expected = Serial.interner(), Serial.interner()
        local path, want = Serial.tagged(paths, expected, "root.hp", Base.cell(Codecs.int(0, 9)))
        Expect.equal(paths.texts[path], "root.hp")
        Expect.equal(expected.texts[want], "int(0,9)")
    end),
}
