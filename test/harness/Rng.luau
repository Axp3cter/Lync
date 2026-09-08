--!strict
--!optimize 2
-- The seeded generator every suite draws from, and the tape a failing case replays.

local Rng = {}
Rng.__index = Rng

-- Constants -----------------------------------------------------------

-- xoshiro128** over four 32-bit words, seeded through SplitMix32. Plain bit32 arithmetic, so one
-- seed walks one sequence on any machine and any Luau build.
local MASK = 0xFFFFFFFF
local SPAN = 2 ^ 32
local SPLIT = 0x9E3779B9
local SCRAMBLE_A = 0x21F0AAAD
local SCRAMBLE_B = 0x735A2D97

-- The widest whole number a double holds exactly, which bounds every span drawn.
local EXACT = 2 ^ 53

-- Zeros a replay hands out past the end of its tape before it gives up.
local PADDING = 4096

-- The committed base seed, the largest word a draw answers, and the line a stuck replay raises.
Rng.BASE = 0x4C796E63
Rng.LARGEST = MASK
Rng.UNSETTLED = "the generator does not settle"

-- Types ---------------------------------------------------------------

export type Rng = typeof(setmetatable(
    {} :: {
        _seed: number,
        _state: { number },
        _tape: { number },
        _at: number?,
        _padded: number,
    },
    {} :: typeof(Rng)
))

-- Private -------------------------------------------------------------

-- Multiplication modulo 2^32 without rounding: every partial product stays under 2^48.
local function mul(a: number, b: number): number
    local high = bit32.rshift(a, 16)
    local low = bit32.band(a, 0xFFFF)
    return bit32.band(low * b + bit32.lshift(high * b, 16), MASK)
end

-- SplitMix32, which spreads one seed into words with no visible relation.
local function split(state: number): (number, number)
    local advanced = bit32.band(state + SPLIT, MASK)
    local z = mul(bit32.bxor(advanced, bit32.rshift(advanced, 16)), SCRAMBLE_A)
    z = mul(bit32.bxor(z, bit32.rshift(z, 15)), SCRAMBLE_B)
    return advanced, bit32.bxor(z, bit32.rshift(z, 15))
end

-- Public --------------------------------------------------------------

-- An all-zero state is xoshiro's fixed point, so a seed that spreads to zeros gets one bit set.
function Rng.new(seed: number?): Rng
    local base = if seed ~= nil then bit32.band(seed, MASK) else Rng.BASE
    local state = table.create(4, 0)
    local word = base
    local live = false
    for index = 1, 4 do
        word, state[index] = split(word)
        live = live or state[index] ~= 0
    end
    if not live then state[1] = 1 end

    return setmetatable(
            { _seed = base, _state = state, _tape = {}, _at = nil, _padded = 0 },
            Rng
        ) :: Rng
end

-- A generator handing back a recorded tape, zeros past its end. Its seed reads as zero.
function Rng.replay(tape: { number }): Rng
    return setmetatable(
        { _seed = 0, _state = { 0, 0, 0, 0 }, _tape = table.clone(tape), _at = 1, _padded = 0 },
        Rng
    ) :: Rng
end

function Rng.seed(self: Rng): number
    return self._seed
end

function Rng.tape(self: Rng): { number }
    return table.clone(self._tape)
end

-- One uniform 32-bit word, the only place the state advances or the tape moves.
function Rng.next(self: Rng): number
    local at = self._at
    if at ~= nil then
        self._at = at + 1
        local recorded = self._tape[at]
        if recorded ~= nil then return recorded end

        self._padded += 1
        assert(self._padded <= PADDING, `a replay drew past {PADDING} zeros, so {Rng.UNSETTLED}`)
        return 0
    end

    local s = self._state
    local result = mul(bit32.lrotate(mul(s[2], 5), 7), 9)
    local carry = bit32.lshift(s[2], 9)
    s[3] = bit32.bxor(s[3], s[1])
    s[4] = bit32.bxor(s[4], s[2])
    s[2] = bit32.bxor(s[2], s[3])
    s[1] = bit32.bxor(s[1], s[4])
    s[3] = bit32.bxor(s[3], carry)
    s[4] = bit32.lrotate(s[4], 11)

    table.insert(self._tape, result)
    return result
end

-- Two words joined into one 53-bit number.
local function wide(self: Rng): number
    local high = self:next()
    return high * 2 ^ 21 + bit32.rshift(self:next(), 11)
end

-- Rejection sampling, since `draw % n` alone favours low residues when n does not divide the range.
local function below(self: Rng, n: number): number
    local range: number, draw: (Rng) -> number = SPAN, Rng.next
    if n > SPAN then
        range, draw = EXACT, wide
    end

    local limit = range - range % n
    local drawn = draw(self)
    while drawn >= limit do
        drawn = draw(self)
    end
    return drawn % n
end

-- A whole number in [min, max], both ends reachable. The span stays under 2^53 so span + 1
-- is exact.
function Rng.int(self: Rng, min: number, max: number): number
    assert(min % 1 == 0 and max % 1 == 0, `int wants whole bounds, got {min} and {max}`)
    local span = max - min
    assert(span >= 0 and span < EXACT, `int wants 0 <= max - min < 2^53, got {min} and {max}`)
    return if span == 0 then min else min + below(self, span + 1)
end

-- A number in [min, max) at full double resolution.
function Rng.number(self: Rng, min: number, max: number): number
    assert(min <= max, `number wants min <= max, got {min} and {max}`)
    return min + wide(self) / EXACT * (max - min)
end

-- True with the given probability, or on half the draws when none is given.
function Rng.bool(self: Rng, chance: number?): boolean
    if chance == nil then return bit32.band(self:next(), 1) == 1 end
    return wide(self) / EXACT < chance
end

function Rng.pick<T>(self: Rng, from: { T }): T
    assert(#from > 0, "pick wants a list with something in it")
    return from[self:int(1, #from)]
end

-- Fisher-Yates in place, every permutation equally likely.
function Rng.shuffle<T>(self: Rng, list: { T })
    for index = #list, 2, -1 do
        local swap = self:int(1, index)
        list[index], list[swap] = list[swap], list[index]
    end
end

function Rng.bytes(self: Rng, count: number): buffer
    assert(count >= 0, `bytes wants a count of zero or more, got {count}`)
    local out = buffer.create(count)
    local whole = count - count % 4
    for offset = 0, whole - 1, 4 do
        buffer.writeu32(out, offset, self:next())
    end
    if whole < count then
        local tail = self:next()
        for offset = whole, count - 1 do
            buffer.writeu8(out, offset, bit32.band(tail, 0xFF))
            tail = bit32.rshift(tail, 8)
        end
    end
    return out
end

return table.freeze(Rng)
