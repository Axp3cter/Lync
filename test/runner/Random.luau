--!strict
--!optimize 2
-- Seeded PRNG for property tests. Linear congruential generator with full 32-bit state.

-- Constants --------------------------------------------------------------

local A = 1664525
local C = 1013904223
local M = 0x100000000
local DEFAULT_SEED = 0x4C796E63

-- Public types -----------------------------------------------------------

export type RNG = {
    seed: number,
    state: number,
    next: (self: RNG) -> number,
    nextU32: (self: RNG) -> number,
    int: (self: RNG, min: number, max: number) -> number,
    float: (self: RNG, min: number, max: number) -> number,
    bool: (self: RNG) -> boolean,
    choice: <T>(self: RNG, list: { T }) -> T,
    bytes: (self: RNG, len: number) -> buffer,
    string: (self: RNG, len: number) -> string,
}

-- Private ----------------------------------------------------------------

local function step(state: number): number
    return (state * A + C) % M
end

-- Public -----------------------------------------------------------------

local Random = {}

Random.DEFAULT_SEED = DEFAULT_SEED

function Random.new(seed: number?): RNG
    local s = seed or DEFAULT_SEED
    local self = {
        seed = s,
        state = s,
    }

    function self:next(): number
        self.state = step(self.state)
        return self.state / M
    end

    function self:nextU32(): number
        self.state = step(self.state)
        return self.state
    end

    function self:int(min: number, max: number): number
        if max < min then
            error(`[Random.int] max ({max}) < min ({min})`)
        end
        local span = max - min + 1
        return min + (self:nextU32() % span)
    end

    function self:float(min: number, max: number): number
        return min + (max - min) * self:next()
    end

    function self:bool(): boolean
        return self:nextU32() % 2 == 0
    end

    function self:choice<T>(list: { T }): T
        return list[self:int(1, #list)]
    end

    function self:bytes(len: number): buffer
        local b = buffer.create(len)
        for i = 0, len - 1 do
            buffer.writeu8(b, i, self:int(0, 255))
        end
        return b
    end

    function self:string(len: number): string
        local parts = table.create(len)
        for i = 1, len do
            parts[i] = string.char(self:int(32, 126))
        end
        return table.concat(parts)
    end

    return (self :: any) :: RNG
end

return table.freeze(Random)
