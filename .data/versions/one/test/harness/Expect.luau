--!strict
--!optimize 2
-- The expectation surface: checks that raise a marked failure, and two that answer instead.

local Expect = {}

-- Constants -----------------------------------------------------------

-- Longest string shown in a difference, and bytes shown either side of a buffer mismatch.
local SHOWN = 48
local WINDOW = 6

-- Types ---------------------------------------------------------------

-- A failure carries this metatable so a runner can tell a wrong claim from a crash.
local Failure = {}
Failure.__tostring = function(self: Failure): string
    return self.message
end

export type Failure = typeof(setmetatable({} :: { read message: string }, Failure))

-- Private -------------------------------------------------------------

local function raise(message: string): never
    error(table.freeze(setmetatable({ message = message }, Failure)), 0)
end

local function hex(b: buffer, from: number, to: number): string
    local parts = table.create(to - from + 1)
    for offset = from, to do
        table.insert(parts, string.format("%02X", buffer.readu8(b, offset)))
    end
    return table.concat(parts, " ")
end

local function show(value: unknown): string
    local kind = typeof(value)
    if kind == "string" then
        local text = value :: string
        if #text > SHOWN then return `"{string.sub(text, 1, SHOWN)}"+{#text - SHOWN}` end
        return `"{text}"`
    elseif kind == "number" then
        local n = value :: number
        if n ~= n then return "nan" end
        if n == 0 and 1 / n < 0 then return "-0" end
        return tostring(n)
    elseif kind == "buffer" then
        local b = value :: buffer
        local size = buffer.len(b)
        if size == 0 then return "buffer(0)" end
        return `buffer({size}) {hex(b, 0, math.min(size, WINDOW) - 1)}`
    elseif kind == "table" then
        local count = 0
        for _ in value :: { [unknown]: unknown } do
            count += 1
        end
        return `table({count})`
    end
    return tostring(value)
end

-- NaN equals NaN and -0 differs from 0, since both are distinct bytes on the wire.
local function sameNumber(a: number, b: number): boolean
    if a ~= a then return b ~= b end
    if a == 0 then return b == 0 and 1 / a == 1 / b end
    return a == b
end

-- The components of the value types lossy codecs round. `vector` is the native form the leaves use.
local function components(value: unknown): { number }?
    local kind = typeof(value)
    if kind == "vector" then
        local v = value :: vector
        return { v.x, v.y, v.z }
    elseif kind == "Vector2" then
        local v = value :: Vector2
        return { v.X, v.Y }
    elseif kind == "Vector3" then
        local v = value :: Vector3
        return { v.X, v.Y, v.Z }
    elseif kind == "Color3" then
        local c = value :: Color3
        return { c.R, c.G, c.B }
    elseif kind == "CFrame" then
        return { (value :: CFrame):GetComponents() }
    end
    return nil
end

local function compareBuffers(a: buffer, b: buffer, path: string): string?
    local left, right = buffer.len(a), buffer.len(b)
    if left ~= right then return `{path}: length {left}, expected {right}` end

    for offset = 0, left - 1 do
        if buffer.readu8(a, offset) ~= buffer.readu8(b, offset) then
            local from = math.max(0, offset - WINDOW)
            local to = math.min(left - 1, offset + WINDOW)
            return `{path}: byte {offset} is {hex(a, from, to)}, expected {hex(b, from, to)}`
        end
    end
    return nil
end

-- The path of the first difference, or nil. A tolerance of zero is exact equality.
local function compare(
    a: unknown,
    b: unknown,
    tolerance: number,
    path: string,
    seen: { [unknown]: unknown }
): string?
    local kind = typeof(a)
    if kind ~= typeof(b) then return `{path}: {show(a)}, expected {show(b)}` end

    if kind == "number" then
        local left, right = a :: number, b :: number
        local close = sameNumber(left, right)
            or (tolerance > 0 and math.abs(left - right) <= tolerance)
        return if close then nil else `{path}: {show(a)}, expected {show(b)}`
    end

    if kind == "buffer" then return compareBuffers(a :: buffer, b :: buffer, path) end

    local left = components(a)
    if left ~= nil then
        local right = components(b) :: { number }
        for index, value in left do
            if math.abs(value - right[index]) > tolerance then
                return `{path}: {show(a)}, expected {show(b)}`
            end
        end
        return nil
    end

    if kind ~= "table" then
        return if a == b then nil else `{path}: {show(a)}, expected {show(b)}`
    end

    if seen[a] == b then return nil end
    seen[a] = b

    local from = a :: { [unknown]: unknown }
    local into = b :: { [unknown]: unknown }
    for key, value in from do
        local where = `{path}.{tostring(key)}`
        if into[key] == nil then return `{where}: {show(value)}, expected nothing` end

        local difference = compare(value, into[key], tolerance, where, seen)
        if difference ~= nil then return difference end
    end
    for key, value in into do
        if from[key] == nil then
            return `{path}.{tostring(key)}: nothing, expected {show(value)}`
        end
    end
    return nil
end

-- A thrown value as text, honouring `{ code, message }` error tables.
local function thrownMessage(value: unknown): string
    if typeof(value) == "table" then
        local message = (value :: { [string]: unknown }).message
        if typeof(message) == "string" then return message end
    end
    return tostring(value)
end

-- Public --------------------------------------------------------------

-- The failure this value carries, or nil when it is an ordinary error.
function Expect.failed(value: unknown): Failure?
    if typeof(value) ~= "table" then return nil end
    if getmetatable(value :: any) ~= Failure then return nil end
    return value :: Failure
end

function Expect.holds(condition: boolean, why: string)
    if not condition then raise(why) end
end

-- Structural equality with exact numbers, so a lost sign or a rounded field fails.
function Expect.equal(actual: unknown, expected: unknown)
    local difference = compare(actual, expected, 0, "value", {})
    if difference ~= nil then raise(difference) end
end

-- The same walk with slack at every numeric leaf, for codecs that round on purpose.
function Expect.near(actual: unknown, expected: unknown, tolerance: number)
    assert(tolerance > 0, `near wants a tolerance above zero, got {tolerance}`)
    local difference = compare(actual, expected, tolerance, "value", {})
    if difference ~= nil then raise(`{difference} (within {tolerance})`) end
end

-- Structural equality answered rather than raised.
function Expect.alike(left: unknown, right: unknown): boolean
    return compare(left, right, 0, "value", {}) == nil
end

-- The message the call threw. A failure raised inside the call is re-raised, not counted.
function Expect.throws(call: () -> (), contains: string?): string
    local ok, caught = pcall(call)
    if not ok and Expect.failed(caught) ~= nil then error(caught, 0) end
    if ok then raise("expected a throw, the call returned") end

    local message = thrownMessage(caught)
    if contains ~= nil and string.find(message, contains, 1, true) == nil then
        raise(`threw "{message}", expected a throw containing "{contains}"`)
    end
    return message
end

return table.freeze(Expect)
