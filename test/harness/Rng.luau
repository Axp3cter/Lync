--!strict
--!optimize 2
-- The seeded generator every suite draws from, the base seed, and the tape a case replays.

local Protocol = require ("@src/wire/Protocol")

local Rng = {}

-- Constants -----------------------------------------------------------

--[[
    `xoshiro128**` over four 32-bit words. It needs nothing wider than bit32 and is plain
    arithmetic, so a server and a client walk the same sequence from the same seed. Roblox's own
    Random is deliberately not used: a committed seed has to replay identically across engine
    versions, and nothing promises that of an engine generator.
]]
const MASK = 0xFFFFFFFF
const SPAN = 4294967296

-- The widest a double counts without gaps, which the wire calls its ceiling.
const WIDE = Protocol.EXACT

const SPLIT = 0x9E3779B9
const SCRAMBLE_A = 0x21F0AAAD
const SCRAMBLE_B = 0x735A2D97

-- Zeros a replay hands out past the end of its tape before it gives up.
const PADDING = 4096

-- Types ---------------------------------------------------------------

-- A draw in progress, as a record every function below is handed.
export type Rng = {
    _seed: number,
    _s: { number },
    _tape: { number },
    _at: number?,
    _padded: number,
}

-- Private -------------------------------------------------------------

--[[
    Multiplication modulo 2^32, exact. Splitting the left operand keeps every partial product inside
    2^48, which a double holds without rounding. A plain `a * b` would reach 2^64 and quietly lose
    the low bits that matter here.
]]
local function mul (a: number, b: number): number
    local high = bit32.rshift (a, 16)
    local low = bit32.band (a, 0xFFFF)
    return bit32.band (low * b + bit32.lshift (high * b, 16), MASK)
end

-- SplitMix32, which spreads one seed into four words with no visible relation.
local function split (state: number): (number, number)
    local advanced = bit32.band (state + SPLIT, MASK)

    local z = mul (bit32.bxor (advanced, bit32.rshift (advanced, 16)), SCRAMBLE_A)
    z = mul (bit32.bxor (z, bit32.rshift (z, 15)), SCRAMBLE_B)

    return advanced, bit32.bxor (z, bit32.rshift (z, 15))
end

-- Fifty-three bits, the widest a double counts without gaps.
local function wide (of: Rng): number
    return Rng.next (of) * 2097152 + bit32.rshift (Rng.next (of), 11)
end

--[[
    Rejection sampling, because `draw % n` alone favours the low residues whenever n does not divide
    the draw's range, and a generator that leans is a suite that never visits the values it leans
    away from.
]]
local function below (of: Rng, n: number): number
    if n <= SPAN then
        local limit = SPAN - SPAN % n
        local drawn = Rng.next (of)
        while drawn >= limit do
            drawn = Rng.next (of)
        end
        return drawn % n
    end

    local limit = WIDE - WIDE % n
    local drawn = wide (of)
    while drawn >= limit do
        drawn = wide (of)
    end
    return drawn % n
end

-- Public --------------------------------------------------------------

--[[
    The committed base seed. Two runs of the same tree explore the same cases, so a red run
    reproduces anywhere. Pass a seed to reach past what it covers.
]]
Rng.BASE = 0x4C796E63

-- The largest word a draw answers, which is what a stored case has to hold.
Rng.LARGEST = MASK

--[[
    The line a replay raises once it has padded past its limit, which says the generator does not
    terminate on an all-zero tape. A harness that hangs is worse than one that says so, and a
    minimizer has to recognize this: a candidate that trips it is a different fault, not a smaller
    version of one.
]]
Rng.UNSETTLED = "the generator does not settle"

--[[
    An all-zero state is xoshiro's one fixed point, and it would answer a constant forever while
    every property passed. It cannot arise from the seeds a run uses, and the cost of being wrong
    about that is a suite that reports green having tested one value, so the state is checked once
    here.
]]
function Rng.new (seed: number?): Rng
    local base = if seed ~= nil then bit32.band (seed, MASK) else Rng.BASE

    local state = base
    local words = table.create (4)
    local live = false
    for index = 1, 4 do
        local advanced, word = split (state)
        state = advanced
        words[index] = word
        if word ~= 0 then live = true end
    end
    if not live then words[1] = 1 end

    local of = { _seed = base, _s = words, _tape = {}, _at = nil, _padded = 0 }
    return setmetatable (of, Rng) :: Rng
end

--[[
    A generator handing back a recorded tape instead of drawing, which is how a corpus case and
    every shrink candidate are replayed. Past the end every draw is zero, so deleting a run of
    words takes the simplest path rather than a different one. A generator must terminate there.
]]
function Rng.replay (tape: { number }): Rng
    return setmetatable (
        { _seed = 0, _s = { 0, 0, 0, 0 }, _tape = table.clone (tape), _at = 1, _padded = 0 },
        Rng
    ) :: Rng
end

--[[
    The seed this generator was built from, which is what a failure reprints. A replayed generator
    answers zero: its tape is its identity, not a seed.
]]
function Rng.seed (of: Rng): number return of._seed end

-- Every word drawn so far, which replays the case exactly.
function Rng.tape (of: Rng): { number } return table.clone (of._tape) end

-- One uniform 32-bit word, and the only place the state advances or the tape moves.
function Rng.next (of: Rng): number
    local at = of._at
    if at ~= nil then
        of._at = at + 1

        local recorded = of._tape[at]
        if recorded ~= nil then return recorded end

        of._padded += 1
        assert (of._padded <= PADDING, `a replay drew past {PADDING} zeros, so {Rng.UNSETTLED}`)
        return 0
    end

    local s = of._s
    local result = mul (bit32.lrotate (mul (s[2], 5), 7), 9)
    local carry = bit32.lshift (s[2], 9)

    s[3] = bit32.bxor (s[3], s[1])
    s[4] = bit32.bxor (s[4], s[2])
    s[2] = bit32.bxor (s[2], s[3])
    s[1] = bit32.bxor (s[1], s[4])
    s[3] = bit32.bxor (s[3], carry)
    s[4] = bit32.lrotate (s[4], 11)

    table.insert (of._tape, result)
    return result
end

--[[
    A whole number in [min, max], both ends reachable. The span is bounded by 2^53 because span + 1
    has to survive as a double: at 2^53 the addition rounds back down and the stated maximum becomes
    unreachable, and past it the rejection limit falls to zero and the sampler never returns.
]]
function Rng.int (of: Rng, min: number, max: number): number
    assert (min % 1 == 0 and max % 1 == 0, `int wants whole bounds, got {min} and {max}`)

    local span = max - min
    assert (span >= 0 and span < WIDE, `int wants 0 <= max - min < 2^53, got {min} and {max}`)

    if span == 0 then return min end
    return min + below (of, span + 1)
end

-- A number in [min, max), at the full resolution a double carries.
function Rng.number (of: Rng, min: number, max: number): number
    assert (min <= max, `number wants min <= max, got {min} and {max}`)
    return min + wide (of) / WIDE * (max - min)
end

-- True with the given probability, or on half the draws when none is given.
function Rng.bool (of: Rng, chance: number?): boolean
    if chance == nil then return bit32.band (Rng.next (of), 1) == 1 end
    return wide (of) / WIDE < chance
end

function Rng.pick <T>(of: Rng, from: { T }): T
    assert (#from > 0, "pick wants a list with something in it")
    return from[Rng.int (of, 1, #from)]
end

--[[
    Fisher-Yates in place, every permutation equally likely. A caller drawing a selection of a
    set's fields needs a subset without repeats and in no particular order, and a draw that took
    each field independently would answer a count nobody asked for.
]]
function Rng.shuffle <T>(of: Rng, list: { T })
    for index = #list, 2, -1 do
        local swap = Rng.int (of, 1, index)
        list[index], list[swap] = list[swap], list[index]
    end
end

function Rng.bytes (of: Rng, count: number): buffer
    assert (count >= 0, `bytes wants a count of zero or more, got {count}`)

    local out = buffer.create (count)
    local whole = count - count % 4
    for offset = 0, whole - 1, 4 do
        buffer.writeu32 (out, offset, Rng.next (of))
    end

    local tail = Rng.next (of)
    for offset = whole, count - 1 do
        buffer.writeu8 (out, offset, bit32.band (tail, 0xFF))
        tail = bit32.rshift (tail, 8)
    end
    return out
end

return table.freeze (Rng)
