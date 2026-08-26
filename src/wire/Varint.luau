--!strict
--!optimize 2
-- The two variable-length forms, `vlq` and `vli`.

local Log = require ("@src/kernel/Log")
local Protocol = require ("@src/wire/Protocol")

local Varint = {}

-- Constants -----------------------------------------------------------

-- The continuation bit, the seven bits under it, and half a group, which the format owns.
const MORE = Protocol.VARINT_MORE
const GROUP = Protocol.VARINT_GROUP
const HALF = Protocol.VARINT_HALF

const EXACT = Protocol.EXACT
const GROUPS = Protocol.VARINT_GROUPS

-- Private -------------------------------------------------------------

--[[
    A value is carried as a head group and the rest, never as one number: the zigzag of the widest
    signed value wants fifty-four bits and a double holds fifty-three, and neither part wants more
    than fifty-three. That is why nothing here reaches the integer domain.
]]
@native
local function laid (out: buffer, at: number, head: number, tail: number): number
    while tail > 0 do
        buffer.writeu8 (out, at, head + MORE)
        at += 1
        head, tail = tail % MORE, tail // MORE
    end

    buffer.writeu8 (out, at, head)
    return at + 1
end

@native
local function taken (b: buffer, at: number): (number, number, number)
    local head = buffer.readu8 (b, at)
    at += 1
    if head < MORE then return head, 0, at end
    head -= MORE

    local tail, shift = 0, 1
    for _ = 2, GROUPS do
        local byte = buffer.readu8 (b, at)
        at += 1
        if byte < MORE then return head, tail + byte * shift, at end

        tail += (byte - MORE) * shift
        shift *= MORE
    end

    -- Raised bare: this answers three numbers, where a call answering `never` reads as a fall thro
    error (`a varint ran past {GROUPS} groups`, 0)
end

-- Public --------------------------------------------------------------

--[[
    Answers the offset past what it wrote, and refuses a value the exact domain has no place for.
    A varint carries a whole number and the domain is what a double holds exactly, so what is
    turned away here is a caller's own value rather than anything a frame could have carried.
]]
@native
function Varint.write (out: buffer, at: number, value: number): number
    if value < 0 or value >= EXACT then
        Log.refuse (`a varint carries none to {EXACT - 1}, not {value}`)
    end
    return laid (out, at, value % MORE, value // MORE)
end

--[[
    Answers the value and the offset past it, and refuses bytes that spell a number past the exact
    domain. Refused rather than answered, because a value a double cannot hold exactly is a value
    the two machines would disagree about the moment either did arithmetic on it.
]]
@native
function Varint.read (b: buffer, at: number): (number, number)
    local head, tail, after = taken (b, at)

    local value = head + tail * MORE
    if value >= EXACT then Log.refuse (`a varint read {value}, past the exact ceiling`) end
    return value, after
end

--[[
    Taken off the magnitude rather than the doubled value. A negative one sitting on a group
    boundary has nothing left in its head, so the head carries the whole group and the rest gives
    one up, which is the one place the two branches differ.
]]
@native
function Varint.writeSigned (out: buffer, at: number, value: number): number
    if value <= -EXACT or value >= EXACT then
        Log.refuse (`a signed varint carries {1 - EXACT} to {EXACT - 1}, not {value}`)
    end
    if value >= 0 then return laid (out, at, (value % HALF) * 2, value // HALF) end

    local magnitude = -value
    local head = magnitude % HALF
    if head == 0 then return laid (out, at, GROUP, magnitude // HALF - 1) end
    return laid (out, at, head * 2 - 1, magnitude // HALF)
end

--[[
    The same pair for the signed form, refused at both ends of the domain rather than at one. A
    reader that checked only the top would take a magnitude one past the bottom and answer a number
    no encoder could have written.
]]
@native
function Varint.readSigned (b: buffer, at: number): (number, number)
    local head, tail, after = taken (b, at)

    local rest = tail * HALF
    local value = if head % 2 == 0 then head / 2 + rest else -((head + 1) / 2 + rest)
    if value <= -EXACT or value >= EXACT then
        Log.refuse (`a signed varint read {value}, past the exact ceiling`)
    end
    return value, after
end

--[[
    A step of one or more and a flag, written as one, for the reason the pair above folds a sign
    into the low bit: a number that always carries a second small thing beside it would spend a
    whole group on it. One or more because a step of nothing is the same number twice.
]]
@native
function Varint.writeFlagged (out: buffer, at: number, step: number, flag: number): number
    if step < 1 then Log.refuse (`a flagged varint carries a step of one or more, not {step}`) end

    return Varint.write (out, at, (step - 1) * 2 + flag)
end

-- The same pair, taken apart: the step it climbed and the bit it carried beside it.
@native
function Varint.readFlagged (b: buffer, at: number): (number, number, number)
    local held, after = Varint.read (b, at)

    return held // 2 + 1, held % 2, after
end

return table.freeze (Varint)
