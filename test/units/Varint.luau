--!strict
--!optimize 2
--[[
    The varints alone: the groups they lay down, the values they give back, and what they refuse.
]]

local Protocol = require ("@src/wire/Protocol")
local Varint = require ("@src/wire/Varint")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

-- Room for the widest varint and an offset in front of it.
const ROOM = 32

-- Values a packing case writes back to back.
const RUN = 12

const WIDEST = Protocol.EXACT - 1
const GROUPS = Protocol.VARINT_GROUPS

-- Every byte of a group but the last carries this, and the last carries none.
const MORE = 0x80

-- Types ---------------------------------------------------------------

-- A write and its read, named as a pair so one case body asks the same thing of either coding.
type Form = {
    read write: (buffer, number, number) -> number,
    read read: (buffer, number) -> (number, number),
}

-- Private -------------------------------------------------------------

-- The two codings, so a case parametrized over both is written once.
const UNSIGNED: Form = { write = Varint.write, read = Varint.read }
const SIGNED: Form = { write = Varint.writeSigned, read = Varint.readSigned }

-- The bytes one write laid down, so a case can state them outright.
local function laid (of: Form, value: number): { number }
    local out = buffer.create (ROOM)
    local after = of.write (out, 0, value)

    local bytes = table.create (after) :: { number }
    for at = 0, after - 1 do
        table.insert (bytes, buffer.readu8 (out, at))
    end
    return bytes
end

-- The value that comes back and the bytes it rode in, the two positions agreeing.
local function circles (of: Form, value: number): (number, number)
    local out = buffer.create (ROOM)
    local after = of.write (out, 0, value)

    local got, ended = of.read (out, 0)
    Expect.equal (ended, after)
    return got, after
end

local function holding (bytes: { number }): buffer
    local out = buffer.create (#bytes)
    for index, byte in bytes do
        buffer.writeu8 (out, index - 1, byte)
    end
    return out
end

--[[
    A magnitude drawn across every width a varint carries, tight to a band's edge as often as
    anywhere inside it. The edges are where the group count turns over, and a uniform draw across a
    band of 2^52 values never lands on one, so the case that finds an off-by-one at a group boundary
    never comes up.
]]
local function magnitude (rng: Rng.Rng): number
    local exponent = Rng.int (rng, 0, 53)
    if exponent == 0 then return 0 end

    local floor = 2 ^ (exponent - 1)
    local ceiling = math.min (2 ^ exponent - 1, WIDEST)
    local reach = math.min (2, ceiling - floor)

    local edge = Rng.int (rng, 0, 2)
    if edge == 0 then return floor + Rng.int (rng, 0, reach) end
    if edge == 1 then return ceiling - Rng.int (rng, 0, reach) end
    return Rng.int (rng, floor, ceiling)
end

-- A value for either form. Zero is never negated: the wire has one of it.
local function drawn (rng: Rng.Rng): (Form, number)
    local value = magnitude (rng)
    if not Rng.bool (rng) then return UNSIGNED, value end
    if value > 0 and Rng.bool (rng) then return SIGNED, -value end
    return SIGNED, value
end

-- Public --------------------------------------------------------------

return {
    Harness.case ("varint.zero", function ()
        Expect.equal (laid (UNSIGNED, 0), { 0x00 })
        Expect.equal (circles (UNSIGNED, 0), 0)
    end),

    -- Everything under seven bits is one group, and the top of that range is 127.
    Harness.case ("varint.one-group", function ()
        Expect.equal (laid (UNSIGNED, 1), { 0x01 })
        Expect.equal (laid (UNSIGNED, 127), { 0x7F })
    end),

    --[[
        The least significant group leads. 128 is the first value that needs a second, and it reads
        as an empty low group carrying on into a one.
    ]]
    Harness.case ("varint.two-groups", function ()
        Expect.equal (laid (UNSIGNED, 128), { 0x80, 0x01 })
        Expect.equal (laid (UNSIGNED, 300), { 0xAC, 0x02 })
        Expect.equal (laid (UNSIGNED, 16383), { 0xFF, 0x7F })
    end),

    Harness.case (
        "varint.three-groups",
        function () Expect.equal (laid (UNSIGNED, 16384), { 0x80, 0x80, 0x01 }) end
    ),

    -- The widest exact value fills the cap exactly: fifty-three bits in eight groups.
    Harness.case ("varint.eight-groups", function ()
        local bytes = laid (UNSIGNED, WIDEST)
        Expect.equal (#bytes, GROUPS)
        Expect.equal (bytes, { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F })
    end),

    Harness.case ("varint.continuation", function ()
        for _, value in { 0, 1, 127, 128, 300, 16384, 2 ^ 40, WIDEST } do
            local bytes = laid (UNSIGNED, value)
            for index, byte in bytes do
                local carries = byte >= MORE
                local wanted = index < #bytes
                Expect.holds (
                    carries == wanted,
                    `{value} byte {index} of {#bytes} carries {carries}`
                )
            end
        end
    end),

    -- A write answers where the next one starts, and back to back leaves no gap.
    Harness.case ("varint.position", function ()
        local out = buffer.create (ROOM)

        local after = Varint.write (out, 0, 300)
        Expect.equal (after, 2)

        local ended = Varint.write (out, after, 16384)
        Expect.equal (ended, 5)

        local first, next = Varint.read (out, 0)
        Expect.equal (first, 300)
        Expect.equal (next, after)

        local second, done = Varint.read (out, next)
        Expect.equal (second, 16384)
        Expect.equal (done, ended)
    end),

    -- Writing further in leaves what came before untouched.
    Harness.case ("varint.offset", function ()
        local out = buffer.create (ROOM)
        buffer.writeu8 (out, 0, 0xAA)
        buffer.writeu8 (out, 1, 0xBB)

        Expect.equal (Varint.write (out, 2, 300), 4)
        Expect.equal (buffer.readu8 (out, 0), 0xAA)
        Expect.equal (buffer.readu8 (out, 1), 0xBB)
        Expect.equal (Varint.read (out, 2), 300)
    end),

    --[[
        The unsigned form carries whole numbers below the exact ceiling and nothing else. A negative
        through it is a caller's mistake, not a value the wire has a shape for.
    ]]
    Harness.case ("varint.ceiling", function ()
        local out = buffer.create (ROOM)
        Expect.equal (circles (UNSIGNED, WIDEST), WIDEST)
        local carries = "a varint carries none to"
        Expect.throws (function () Varint.write (out, 0, Protocol.EXACT) end, carries)
        Expect.throws (function () Varint.write (out, 0, -1) end, carries)
    end),

    --[[
        The cap counts groups, not bytes read and not the value they build. Nine groups carrying
        nothing at all is the case that separates the two: every group is a legal zero and the value
        is zero, so only the count is wrong. Nine groups of ones would be rejected by the ceiling
        either way and would say nothing about whether a cap exists.
    ]]
    Harness.case ("varint.cap", function ()
        local overlong = { 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }
        Expect.throws (function () Varint.read (holding (overlong), 0) end)

        -- And a run that never terminates stops at the cap, not at the buffer.
        local endless = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }
        Expect.throws (function () Varint.read (holding (endless), 0) end)
    end),

    --[[
        Eight groups is a legal length and 2^53 is not a legal value, so a frame can be well formed
        and still out of range. What rejects it is the value, which the cap alone would let through.
    ]]
    Harness.case ("varint.read-ceiling", function ()
        local widest = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F }
        Expect.equal (Varint.read (holding (widest), 0), WIDEST)

        local past = { 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x10 }
        Expect.throws (function () Varint.read (holding (past), 0) end, "a varint read")
    end),

    --[[
        The signed form needs its own ceiling case, because its cap is wider than the value it has
        to hold. Eight groups carry fifty-six bits and the zigzag of the widest signed value takes
        fifty-four, so a well formed frame has two bits of room above the ceiling and only the value
        closes it. The row above says the same of the unsigned form and stops there.
    ]]
    Harness.case ("varint.signed-read-ceiling", function ()
        local widest = { 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x1F }
        Expect.equal (Varint.readSigned (holding (widest), 0), WIDEST)

        local past = { 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x20 }
        local says = "a signed varint read"
        Expect.throws (function () Varint.readSigned (holding (past), 0) end, says)
    end),

    --[[
        The signed form is the unsigned one over the zigzag, so the mapping is read straight off the
        wire: none, then the negatives and positives alternating outward from it.
    ]]
    Harness.case ("varint.zigzag", function ()
        local mapped = { [0] = 0, [-1] = 1, [1] = 2, [-2] = 3, [2] = 4, [-3] = 5, [3] = 6 }
        for value, zigzagged in mapped do
            local out = buffer.create (ROOM)
            Varint.writeSigned (out, 0, value)

            Expect.equal (Varint.read (out, 0), zigzagged)
            Expect.equal (circles (SIGNED, value), value)
        end
    end),

    --[[
        Either side of where the zigzag leaves the double domain. Doubling a negative and stepping
        back one wants a fifty-fourth bit from `-(2^52+1)` down, and rounds even without it. The
        wire form is the same eight groups either side, so what differs is the arithmetic.
    ]]
    Harness.case ("varint.signed-edge", function ()
        local edge = Protocol.VLI_EDGE
        for _, value in { edge, -edge, edge + 1, -(edge + 1), edge + 2, -(edge + 2) } do
            local got, bytes = circles (SIGNED, value)
            Expect.equal (got, value)
            Expect.equal (bytes, GROUPS)
        end
    end),

    -- The widest signed values, whose zigzag is fifty-four bits inside eight groups.
    Harness.case ("varint.signed-widest", function ()
        for _, value in { WIDEST, -WIDEST } do
            local got, bytes = circles (SIGNED, value)
            Expect.equal (got, value)
            Expect.equal (bytes, GROUPS)
        end
    end),

    Harness.case ("varint.signed-ceiling", function ()
        local out = buffer.create (ROOM)
        local carries = "a signed varint carries"
        Expect.throws (function () Varint.writeSigned (out, 0, Protocol.EXACT) end, carries)
        Expect.throws (function () Varint.writeSigned (out, 0, -Protocol.EXACT) end, carries)
    end),

    --[[
        Every magnitude either form carries, back and forth. The byte count is checked beside the
        value because a varint that answers right while spending nine bytes has broken the cap the
        boundary relies on.
    ]]
    Harness.property ("varint.round-trips", "leaves", function (rng: Rng.Rng)
        local of, value = drawn (rng)
        local got, bytes = circles (of, value)

        Expect.equal (got, value)
        Expect.holds (bytes >= 1 and bytes <= GROUPS, `{value} rode in {bytes} bytes`)
    end),

    -- A run of them, written nose to tail and read back the same way.
    Harness.property ("varint.packs", "leaves", function (rng: Rng.Rng)
        local count = Rng.int (rng, 0, RUN)
        local forms = table.create (count) :: { Form }
        local values = table.create (count) :: { number }

        local out = buffer.create (ROOM * (count + 1))
        local at = 0
        for _ = 1, count do
            local of, value = drawn (rng)
            table.insert (forms, of)
            table.insert (values, value)
            at = of.write (out, at, value)
        end

        local ended = at
        at = 0
        for index, value in values do
            local got, after = forms[index].read (out, at)
            Expect.equal (got, value)
            at = after
        end
        Expect.equal (at, ended)
    end),
}
