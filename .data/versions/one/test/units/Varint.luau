--!strict
--!optimize 2
-- The varints alone: the groups they lay down, the values they give back, and what they refuse.

local Protocol = require("@src/wire/Protocol")
local Varint = require("@src/wire/Varint")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

-- Room for the widest varint and an offset in front of it.
local ROOM = 32

-- The last value that fits one group and one that does not, so a run walks both lengths.
local WIDE = 127
local MANY = 300

-- A magnitude of whole half groups, the one negative shape the encoder spells its own way.
local SUNK = -Protocol.VARINT_HALF * 2

-- Values a packing case writes back to back.
local RUN = 12

local WIDEST = Protocol.EXACT - 1
local GROUPS = Protocol.VARINT_GROUPS
local MORE = Protocol.VARINT_MORE

-- Where the zigzag leaves the double domain: doubling a negative and stepping back one wants a
-- fifty-fourth bit from one past here.
local EDGE = 2 ^ 52 - 1

-- A write and its read, so one case body asks the same thing of either coding.
type Form = {
    read write: (buffer, number, number) -> number,
    read read: (buffer, number) -> (number, number),
}

local UNSIGNED: Form = { write = Varint.write, read = Varint.read }
local SIGNED: Form = { write = Varint.writeSigned, read = Varint.readSigned }

-- The bytes one write laid down.
local function laid(of: Form, value: number): { number }
    local out = buffer.create(ROOM)
    local after = of.write(out, 0, value)
    local bytes = table.create(after) :: { number }
    for at = 0, after - 1 do
        table.insert(bytes, buffer.readu8(out, at))
    end
    return bytes
end

-- The value that comes back and the bytes it rode in, the two positions agreeing.
local function circles(of: Form, value: number): (number, number)
    local out = buffer.create(ROOM)
    local after = of.write(out, 0, value)
    local got, ended = of.read(out, 0)
    Expect.equal(ended, after)
    return got, after
end

local function holding(bytes: { number }): buffer
    local out = buffer.create(#bytes)
    for index, byte in bytes do
        buffer.writeu8(out, index - 1, byte)
    end
    return out
end

-- A magnitude across every width a varint carries, tight to a band's edge as often as inside it.
local function magnitude(rng: Rng.Rng): number
    local exponent = rng:int(0, 53)
    if exponent == 0 then return 0 end

    local floor = 2 ^ (exponent - 1)
    local ceiling = math.min(2 ^ exponent - 1, WIDEST)
    local reach = math.min(2, ceiling - floor)
    local edge = rng:int(0, 2)
    if edge == 0 then return floor + rng:int(0, reach) end
    if edge == 1 then return ceiling - rng:int(0, reach) end
    return rng:int(floor, ceiling)
end

-- A value for either form. Zero is never negated, the wire has one of it.
local function drawn(rng: Rng.Rng): (Form, number)
    local value = magnitude(rng)
    if not rng:bool() then return UNSIGNED, value end
    if value > 0 and rng:bool() then return SIGNED, -value end
    return SIGNED, value
end

return {
    Harness.case("varint.zero", function()
        Expect.equal(laid(UNSIGNED, 0), { 0x00 })
        Expect.equal(circles(UNSIGNED, 0), 0)
    end),

    Harness.case("varint.one-group", function()
        Expect.equal(laid(UNSIGNED, 1), { 0x01 })
        Expect.equal(laid(UNSIGNED, 127), { 0x7F })
    end),

    -- The least significant group leads.
    Harness.case("varint.two-groups", function()
        Expect.equal(laid(UNSIGNED, 128), { 0x80, 0x01 })
        Expect.equal(laid(UNSIGNED, 300), { 0xAC, 0x02 })
        Expect.equal(laid(UNSIGNED, 16383), { 0xFF, 0x7F })
    end),

    Harness.case("varint.three-groups", function()
        Expect.equal(laid(UNSIGNED, 16384), { 0x80, 0x80, 0x01 })
    end),

    -- The widest exact value fills the cap exactly: fifty-three bits in eight groups.
    Harness.case("varint.eight-groups", function()
        local bytes = laid(UNSIGNED, WIDEST)
        Expect.equal(#bytes, GROUPS)
        Expect.equal(bytes, { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F })
    end),

    Harness.case("varint.continuation", function()
        for _, value in { 0, 1, 127, 128, 300, 16384, 2 ^ 40, WIDEST } do
            local bytes = laid(UNSIGNED, value)
            for index, byte in bytes do
                local carries = byte >= MORE
                Expect.holds(carries == (index < #bytes), `{value} byte {index} carries {carries}`)
            end
        end
    end),

    -- A write answers where the next one starts, and back to back leaves no gap.
    Harness.case("varint.position", function()
        local out = buffer.create(ROOM)
        local after = Varint.write(out, 0, 300)
        Expect.equal(after, 2)
        local ended = Varint.write(out, after, 16384)
        Expect.equal(ended, 5)

        local first, next = Varint.read(out, 0)
        Expect.equal(first, 300)
        Expect.equal(next, after)
        local second, done = Varint.read(out, next)
        Expect.equal(second, 16384)
        Expect.equal(done, ended)
    end),

    Harness.case("varint.offset", function()
        local out = buffer.create(ROOM)
        buffer.writeu8(out, 0, 0xAA)
        buffer.writeu8(out, 1, 0xBB)
        Expect.equal(Varint.write(out, 2, 300), 4)
        Expect.equal(buffer.readu8(out, 0), 0xAA)
        Expect.equal(buffer.readu8(out, 1), 0xBB)
        Expect.equal(Varint.read(out, 2), 300)
    end),

    -- The unsigned form carries whole numbers below the exact ceiling and nothing else.
    Harness.case("varint.ceiling", function()
        local out = buffer.create(ROOM)
        Expect.equal(circles(UNSIGNED, WIDEST), WIDEST)
        local carries = "a varint carries none to"
        Expect.throws(function()
            Varint.write(out, 0, Protocol.EXACT)
        end, carries)
        Expect.throws(function()
            Varint.write(out, 0, -1)
        end, carries)
    end),

    -- The cap counts groups: nine legal zero groups is the case only the count rejects, and a run
    -- that never terminates stops at the cap, not at the buffer.
    Harness.case("varint.cap", function()
        local overlong = { 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }
        Expect.throws(function()
            Varint.read(holding(overlong), 0)
        end)
        local endless = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }
        Expect.throws(function()
            Varint.read(holding(endless), 0)
        end)
    end),

    -- Eight groups is a legal length and 2^53 is not a legal value, so the value rejects it.
    Harness.case("varint.read-ceiling", function()
        local widest = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F }
        Expect.equal(Varint.read(holding(widest), 0), WIDEST)
        local past = { 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x10 }
        Expect.throws(function()
            Varint.read(holding(past), 0)
        end, "a varint read")
    end),

    -- Eight groups carry fifty-six bits and the widest zigzag takes fifty-four, so only the value
    -- closes the signed ceiling.
    Harness.case("varint.signed-read-ceiling", function()
        local widest = { 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x1F }
        Expect.equal(Varint.readSigned(holding(widest), 0), WIDEST)
        local past = { 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x20 }
        Expect.throws(function()
            Varint.readSigned(holding(past), 0)
        end, "a signed varint read")
    end),

    -- A run written whole lays the same bytes the single form would, and answers the offset after.
    Harness.case("varint.write-run", function()
        local held = { 0, 1, WIDE, MANY, 0 }
        local out = buffer.create(ROOM)
        local after = Varint.writeRun(out, 0, held, #held)

        local at = 0
        for _, one in held do
            local got: number
            got, at = Varint.read(out, at)
            Expect.equal(got, one)
        end
        Expect.equal(at, after)
    end),

    Harness.case("varint.signed-write-run", function()
        local held = { 0, -1, 1, -MANY, MANY, SUNK }
        local out = buffer.create(ROOM)
        local after = Varint.writeSignedRun(out, 0, held, #held)

        local at = 0
        for _, one in held do
            local got: number
            got, at = Varint.readSigned(out, at)
            Expect.equal(got, one)
        end
        Expect.equal(at, after)
    end),

    Harness.case("varint.write-run-domain", function()
        local out = buffer.create(ROOM)
        Expect.throws(function()
            Varint.writeRun(out, 0, { 0, -1 }, 2)
        end, "a varint carries")
        Expect.throws(function()
            Varint.writeSignedRun(out, 0, { 0, WIDEST + 1 }, 2)
        end, "a signed varint carries")
    end),

    Harness.case("varint.run", function()
        local held = { 0, 1, WIDE, MANY, 0 }
        local out = buffer.create(ROOM)
        local at = 0
        for _, one in held do
            at = Varint.write(out, at, one)
        end

        local into = {}
        Expect.equal(Varint.readRun(out, 0, into, #held), at)
        Expect.equal(into, held)
    end),

    Harness.case("varint.signed-run", function()
        local held = { 0, -1, 1, -MANY, MANY, SUNK }
        local out = buffer.create(ROOM)
        local at = 0
        for _, one in held do
            at = Varint.writeSigned(out, at, one)
        end

        local into = {}
        Expect.equal(Varint.readSignedRun(out, 0, into, #held), at)
        Expect.equal(into, held)
    end),

    Harness.case("varint.run-ceiling", function()
        local past = { 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x10 }
        Expect.throws(function()
            Varint.readRun(holding(past), 0, {}, 1)
        end, "a varint read")
        local signed = { 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x20 }
        Expect.throws(function()
            Varint.readSignedRun(holding(signed), 0, {}, 1)
        end, "a signed varint read")
    end),

    -- A step and a flag as one number, and the step of nothing refused.
    Harness.case("varint.flagged", function()
        local out = buffer.create(ROOM)
        for _, pair in { { 1, 0 }, { 1, 1 }, { 2, 0 }, { 64, 1 }, { MANY, 0 } } do
            local after = Varint.writeFlagged(out, 0, pair[1], pair[2])
            local step, flag, ended = Varint.readFlagged(out, 0)
            Expect.equal(step, pair[1])
            Expect.equal(flag, pair[2])
            Expect.equal(ended, after)
        end
        Expect.equal(Varint.writeFlagged(out, 0, 1, 0), 1)
        Expect.equal(Varint.read(out, 0), 0)
        Expect.throws(function()
            Varint.writeFlagged(out, 0, 0, 0)
        end, "a step of one or more")
    end),

    -- The signed form is the unsigned one over the zigzag: none, then negatives and positives
    -- alternating outward.
    Harness.case("varint.zigzag", function()
        local mapped = { [0] = 0, [-1] = 1, [1] = 2, [-2] = 3, [2] = 4, [-3] = 5, [3] = 6 }
        for value, zigzagged in mapped do
            local out = buffer.create(ROOM)
            Varint.writeSigned(out, 0, value)
            Expect.equal(Varint.read(out, 0), zigzagged)
            Expect.equal(circles(SIGNED, value), value)
        end
    end),

    Harness.case("varint.signed-edge", function()
        for _, value in { EDGE, -EDGE, EDGE + 1, -(EDGE + 1), EDGE + 2, -(EDGE + 2) } do
            local got, bytes = circles(SIGNED, value)
            Expect.equal(got, value)
            Expect.equal(bytes, GROUPS)
        end
    end),

    Harness.case("varint.signed-widest", function()
        for _, value in { WIDEST, -WIDEST } do
            local got, bytes = circles(SIGNED, value)
            Expect.equal(got, value)
            Expect.equal(bytes, GROUPS)
        end
    end),

    Harness.case("varint.signed-ceiling", function()
        local out = buffer.create(ROOM)
        local carries = "a signed varint carries"
        Expect.throws(function()
            Varint.writeSigned(out, 0, Protocol.EXACT)
        end, carries)
        Expect.throws(function()
            Varint.writeSigned(out, 0, -Protocol.EXACT)
        end, carries)
    end),

    -- The byte count rides beside the value: a varint answering right in nine bytes broke the cap.
    Harness.property("varint.round-trips", "leaves", function(rng: Rng.Rng)
        local of, value = drawn(rng)
        local got, bytes = circles(of, value)
        Expect.equal(got, value)
        Expect.holds(bytes >= 1 and bytes <= GROUPS, `{value} rode in {bytes} bytes`)
    end),

    Harness.property("varint.packs", "leaves", function(rng: Rng.Rng)
        local count = rng:int(0, RUN)
        local forms = table.create(count) :: { Form }
        local values = table.create(count) :: { number }

        local out = buffer.create(ROOM * (count + 1))
        local at = 0
        for _ = 1, count do
            local of, value = drawn(rng)
            table.insert(forms, of)
            table.insert(values, value)
            at = of.write(out, at, value)
        end

        local ended = at
        at = 0
        for index, value in values do
            local got, after = forms[index].read(out, at)
            Expect.equal(got, value)
            at = after
        end
        Expect.equal(at, ended)
    end),
}
