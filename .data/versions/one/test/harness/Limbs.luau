--!strict
--!optimize 2
-- Sixty-four bits carried in doubles, worked out a second time so a suite has two answers.

local Limbs = {}

-- Sixteen-bit pieces: a product of two is under 2^32 and a column sum under 2^33, both exact in a
-- double, where thirty-two bit pieces would reach 2^64 and round.
local LIMBS = 4
local PLACE = 65536
local DIGITS = 4

-- Four sixteen-bit pieces, least significant first.
export type Limbs = { number }

-- Sixteen hex digits as pieces.
function Limbs.of(text: string): Limbs
    assert(#text == LIMBS * DIGITS, `a wide value is {LIMBS * DIGITS} digits, got {#text}`)
    local out = table.create(LIMBS) :: Limbs
    for place = 1, LIMBS do
        local at = (LIMBS - place) * DIGITS + 1
        local piece = tonumber(string.sub(text, at, at + DIGITS - 1), 16)
        assert(piece ~= nil, `{text} is not sixteen hex digits`)
        table.insert(out, piece)
    end
    return out
end

function Limbs.hex(value: Limbs): string
    return string.format("%04X%04X%04X%04X", value[4], value[3], value[2], value[1])
end

-- A product modulo 2^64 in doubles, so a suite can hold the platform's wrap to something.
function Limbs.times(a: Limbs, b: Limbs): Limbs
    local out = { 0, 0, 0, 0 }
    for index = 1, LIMBS do
        local carry = 0
        for other = 1, LIMBS + 1 - index do
            local at = index + other - 1
            local sum = out[at] + a[index] * b[other] + carry
            out[at] = sum % PLACE
            carry = (sum - out[at]) / PLACE
        end
    end
    return out
end

return table.freeze(Limbs)
