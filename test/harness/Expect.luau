--!strict
--!optimize 2
--[[
    The one expectation surface. Four checks raise where the claim is wrong, one walk answers so a
    caller can decide instead, and a failure carries a mark telling it from an ordinary crash.
]]

local Expect = {}

-- Constants -----------------------------------------------------------

-- A rendered string past this is cut, because a diff nobody reads is noise.
const SHOWN = 48

-- Bytes either side of a mismatch, enough to recognize where a frame diverged.
const WINDOW = 6

-- Types ---------------------------------------------------------------

--[[
    A failure carries its own metatable so a runner can tell an expectation that did not hold from
    code that crashed, which are different reports. The __tostring keeps it readable if it ever
    escapes uncaught.
]]
local Failure = {}
Failure.__tostring = function (self: Failure): string return self.message end

export type Failure = typeof(setmetatable ({} :: { read message: string }, Failure))

-- Private -------------------------------------------------------------

-- Every failure leaves through here, wearing the metatable that tells it from a crash.
local function raise (message: string): never
    error (table.freeze (setmetatable ({ message = message }, Failure)), 0)
end

-- A run of bytes as a reader compares them, spaced so a mismatch can be counted along by eye.
local function hex (value: buffer, from: number, to: number): string
    local parts = table.create (to - from + 1)
    for offset = from, to do
        table.insert (parts, string.format ("%02X", buffer.readu8 (value, offset)))
    end
    return table.concat (parts, " ")
end

-- Enough of a value to recognize it, never enough to bury the line it sits on.
local function show (value: unknown): string
    local kind = typeof (value)

    if kind == "nil" then return "nil" end
    if kind == "string" then
        local text = value :: string
        if #text > SHOWN then return `"{string.sub (text, 1, SHOWN)}"+{#text - SHOWN}` end
        return `"{text}"`
    end
    if kind == "number" then
        local n = value :: number
        if n ~= n then return "nan" end
        if n == 0 and 1 / n < 0 then return "-0" end
        return tostring (n)
    end
    if kind == "buffer" then
        local b = value :: buffer
        local size = buffer.len (b)
        if size == 0 then return "buffer(0)" end
        return `buffer({size}) {hex (b, 0, math.min (size, WINDOW) - 1)}`
    end
    if kind == "table" then
        local count = 0
        for _ in value :: { [unknown]: unknown } do
            count += 1
        end
        return `table({count})`
    end
    return tostring (value)
end

--[[
    Exact number equality with two deliberate departures from `==`. NaN matches NaN, because a
    record holding one should still compare equal to itself. Negative zero does not match zero,
    because they are different bytes under f32 and f64, and a roundtrip that lost the sign has to
    fail here.
]]
local function exactly (a: number, b: number): boolean
    if a ~= a then return b ~= b end
    if a == 0 then return b == 0 and 1 / a == 1 / b end
    return a == b
end

--[[
    Component lists for the value types a lossy codec rounds. `vector` is here beside Vector3
    because the leaves work in the native type and only build the Roblox datatype at the boundary,
    so a unit compares one and a suite the other.
]]
local function components (value: unknown): { number }?
    local kind = typeof (value)
    if kind == "vector" then
        local v = value :: vector
        return { v.x, v.y, v.z }
    end
    if kind == "Vector2" then
        local v = value :: Vector2
        return { v.X, v.Y }
    end
    if kind == "Vector3" then
        local v = value :: Vector3
        return { v.X, v.Y, v.Z }
    end
    if kind == "Color3" then
        local c = value :: Color3
        return { c.R, c.G, c.B }
    end
    if kind == "CFrame" then return { (value :: CFrame):GetComponents () } end
    return nil
end

-- Where two frames first differ, with a window either side so the place is recognizable.
local function buffers (a: buffer, b: buffer, path: string): string?
    local left, right = buffer.len (a), buffer.len (b)
    if left ~= right then return `{path}: length {left}, expected {right}` end

    for offset = 0, left - 1 do
        if buffer.readu8 (a, offset) ~= buffer.readu8 (b, offset) then
            local from = math.max (0, offset - WINDOW)
            local to = math.min (left - 1, offset + WINDOW)
            return `{path}: byte {offset} is {hex (a, from, to)}, expected {hex (b, from, to)}`
        end
    end
    return nil
end

--[[
    One walk serves both checks: a tolerance of zero is exact equality, and any other tolerance is
    applied at the numeric leaves and at the components of a rounded value type. Answers the path of
    the first difference, or nil.
]]
local function compare (
    a: unknown,
    b: unknown,
    tolerance: number,
    path: string,
    seen: { [unknown]: unknown }
): string?
    local kind = typeof (a)
    if kind ~= typeof (b) then return `{path}: {show (a)}, expected {show (b)}` end

    if kind == "number" then
        local left, right = a :: number, b :: number
        if tolerance == 0 then
            if exactly (left, right) then return nil end
        elseif left == right or math.abs (left - right) <= tolerance then
            return nil
        end
        return `{path}: {show (a)}, expected {show (b)}`
    end

    if kind == "buffer" then return buffers (a :: buffer, b :: buffer, path) end

    local left = components (a)
    if left ~= nil then
        local right = components (b) :: { number }
        for index, value in left do
            local slack = if tolerance == 0 then 0 else tolerance
            if math.abs (value - right[index]) > slack then
                return `{path}: {show (a)}, expected {show (b)}`
            end
        end
        return nil
    end

    if kind ~= "table" then
        if a == b then return nil end
        return `{path}: {show (a)}, expected {show (b)}`
    end

    -- A cycle would otherwise recurse until the stack gave out.
    if seen[a] == b then return nil end
    seen[a] = b

    local from = a :: { [unknown]: unknown }
    local into = b :: { [unknown]: unknown }
    for key, value in from do
        local where = `{path}.{tostring (key)}`
        if into[key] == nil then return `{where}: {show (value)}, expected nothing` end

        local difference = compare (value, into[key], tolerance, where, seen)
        if difference ~= nil then return difference end
    end
    for key, value in into do
        if from[key] == nil then
            return `{path}.{tostring (key)}: nothing, expected {show (value)}`
        end
    end
    return nil
end

-- A thrown value as a line, honouring the code base's `{ code, message }` errors.
local function thrown (value: unknown): string
    if typeof (value) == "table" then
        local message = (value :: { [string]: unknown }).message
        if typeof (message) == "string" then return message :: string end
    end
    return tostring (value)
end

-- Public --------------------------------------------------------------

-- The failure this value carries, or nil when it is an ordinary error.
function Expect.failed (value: unknown): Failure?
    if typeof (value) ~= "table" then return nil end
    if getmetatable (value :: any) ~= Failure then return nil end
    return value :: Failure
end

-- A claim in the checker's own words, for a failure that is a sentence rather than a difference.
function Expect.holds (condition: boolean, why: string)
    if condition then return end
    raise (why)
end

-- Structural equality. Numbers are exact, so a lost sign or a rounded field fails.
function Expect.equal (actual: unknown, expected: unknown)
    local difference = compare (actual, expected, 0, "value", {})
    if difference == nil then return end
    raise (difference)
end

--[[
    The same walk with slack at every numeric leaf, for the codecs that round on purpose: quant,
    angle, the unit and quaternion rotations, and rgb565.
]]
function Expect.near (actual: unknown, expected: unknown, tolerance: number)
    assert (tolerance > 0, `near wants a tolerance above zero, got {tolerance}`)

    local difference = compare (actual, expected, tolerance, "value", {})
    if difference == nil then return end
    raise (`{difference} (within {tolerance})`)
end

--[[
    The same walk answering rather than raising. The one caller is a model asking whether an
    update wrote the value a record already held, which is what decides whether a flush says
    anything, and a model rolling its own comparison would be a second opinion about NaN, a buffer
    and a nested table.
]]
function Expect.alike (left: unknown, right: unknown): boolean
    return compare (left, right, 0, "value", {}) == nil
end

--[[
    Answers the line the call threw, so a caller can look closer than `contains` allows. An
    expectation that failed inside the function is re-raised rather than counted as the throw under
    test, which would pass for the wrong reason.
]]
function Expect.throws (call: () -> (), contains: string?): string
    local ok, caught = pcall (call)

    if not ok and Expect.failed (caught) ~= nil then error (caught, 0) end
    if ok then raise ("expected a throw, the call returned") end

    local line = thrown (caught)
    if contains ~= nil and string.find (line, contains, 1, true) == nil then
        raise (`threw "{line}", expected a throw containing "{contains}"`)
    end
    return line
end

return table.freeze (Expect)
