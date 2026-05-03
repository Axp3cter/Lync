--!strict
--!optimize 2
-- Expectation methods: each call counts as one assertion in the runner.

-- Public types -----------------------------------------------------------

export type Expectation = {
    toBe: (self: Expectation, expected: any) -> (),
    toEqual: (self: Expectation, expected: any) -> (),
    toBeNil: (self: Expectation) -> (),
    toBeCloseTo: (self: Expectation, expected: number, tolerance: number?) -> (),
    toThrow: (self: Expectation, pattern: string?) -> (),
    toBeTruthy: (self: Expectation) -> (),
    toBeFalsy: (self: Expectation) -> (),
    toBeGreaterThan: (self: Expectation, n: number) -> (),
    toBeGreaterThanOrEqual: (self: Expectation, n: number) -> (),
    toBeLessThan: (self: Expectation, n: number) -> (),
    toBeLessThanOrEqual: (self: Expectation, n: number) -> (),
    toHaveLength: (self: Expectation, n: number) -> (),
    toBeType: (self: Expectation, t: string) -> (),
    toBeFrozen: (self: Expectation) -> (),
    toMatchBuffer: (self: Expectation, bytes: { number }) -> (),
    toBeBuffer: (self: Expectation, len: number?) -> (),
    toContain: (self: Expectation, value: any) -> (),
    toContainKey: (self: Expectation, key: any) -> (),
    toBeNaN: (self: Expectation) -> (),
    never: Expectation,
}

-- Private ----------------------------------------------------------------

local function fmt(value: any): string
    local t = typeof(value)
    if t == "string" then
        return `"{value}"`
    end
    if t == "table" then
        local n = 0
        for _ in value do
            n += 1
        end
        return `<table:{n}>`
    end
    if t == "buffer" then
        return `<buffer:{buffer.len(value)}>`
    end
    if t == "nil" then
        return "nil"
    end
    return tostring(value)
end

local function deepEqual(a: any, b: any, seen: { [any]: any }?): boolean
    if a == b then
        return true
    end
    local tA = typeof(a)
    if tA ~= typeof(b) then
        return false
    end
    if tA ~= "table" then
        if tA == "number" and a ~= a and b ~= b then
            -- Both NaN: deepEqual treats them as equal for structural compare.
            return true
        end
        return false
    end

    seen = seen or {}
    if (seen :: any)[a] == b then
        return true
    end
    (seen :: any)[a] = b

    for k, v in a do
        if not deepEqual(v, b[k], seen) then
            return false
        end
    end
    for k in b do
        if a[k] == nil then
            return false
        end
    end
    return true
end

--[[
    Build an expectation backed by `actual`. `neg` controls inversion
    (`.never` chain). `count` is invoked once per assertion call.
]]
local function build(actual: any, neg: boolean, count: () -> ()): Expectation
    local prefix = if neg then "not " else ""
    local e = {} :: any

    local function fail(msg: string): ()
        error(msg, 0)
    end

    e.toBe = function(_self, expected: any): ()
        count()
        local ok = (actual == expected)
        if neg then
            ok = not ok
        end
        if not ok then
            fail(`Expected {fmt(actual)} {prefix}to be {fmt(expected)}`)
        end
    end

    e.toEqual = function(_self, expected: any): ()
        count()
        local ok = deepEqual(actual, expected)
        if neg then
            ok = not ok
        end
        if not ok then
            fail(`Expected {fmt(actual)} {prefix}to deep-equal {fmt(expected)}`)
        end
    end

    e.toBeNil = function(_self): ()
        count()
        local ok = (actual == nil)
        if neg then
            ok = not ok
        end
        if not ok then
            fail(`Expected {fmt(actual)} {prefix}to be nil`)
        end
    end

    e.toBeCloseTo = function(_self, expected: number, tolerance: number?): ()
        count()
        local tol = tolerance or 1e-3
        local diff = math.abs((actual :: number) - expected)
        local ok = (diff <= tol)
        if neg then
            ok = not ok
        end
        if not ok then
            fail(`Expected {actual} {prefix}within {tol} of {expected} (diff={diff})`)
        end
    end

    e.toThrow = function(_self, pattern: string?): ()
        count()
        if typeof(actual) ~= "function" then
            fail(`Expected a function, got {typeof(actual)}`)
        end
        local ok, err = pcall(actual :: () -> ())
        if neg then
            if not ok then
                fail(`Expected no throw, got: {err}`)
            end
            return
        end
        if ok then
            fail("Expected throw, got none")
        end
        if pattern and not string.find(tostring(err), pattern, 1, true) then
            fail(`Expected error matching "{pattern}", got: {err}`)
        end
    end

    e.toBeTruthy = function(_self): ()
        count()
        local ok = (actual ~= nil and actual ~= false)
        if neg then
            ok = not ok
        end
        if not ok then
            fail(`Expected {fmt(actual)} {prefix}to be truthy`)
        end
    end

    e.toBeFalsy = function(_self): ()
        count()
        local ok = (actual == nil or actual == false)
        if neg then
            ok = not ok
        end
        if not ok then
            fail(`Expected {fmt(actual)} {prefix}to be falsy`)
        end
    end

    e.toBeGreaterThan = function(_self, n: number): ()
        count()
        local ok = ((actual :: number) > n)
        if neg then
            ok = not ok
        end
        if not ok then
            fail(`Expected {actual} {prefix}> {n}`)
        end
    end

    e.toBeGreaterThanOrEqual = function(_self, n: number): ()
        count()
        local ok = ((actual :: number) >= n)
        if neg then
            ok = not ok
        end
        if not ok then
            fail(`Expected {actual} {prefix}>= {n}`)
        end
    end

    e.toBeLessThan = function(_self, n: number): ()
        count()
        local ok = ((actual :: number) < n)
        if neg then
            ok = not ok
        end
        if not ok then
            fail(`Expected {actual} {prefix}< {n}`)
        end
    end

    e.toBeLessThanOrEqual = function(_self, n: number): ()
        count()
        local ok = ((actual :: number) <= n)
        if neg then
            ok = not ok
        end
        if not ok then
            fail(`Expected {actual} {prefix}<= {n}`)
        end
    end

    e.toHaveLength = function(_self, n: number): ()
        count()
        local len: number
        if typeof(actual) == "buffer" then
            len = buffer.len(actual)
        elseif typeof(actual) == "string" then
            len = #(actual :: string)
        else
            len = #(actual :: any)
        end
        local ok = (len == n)
        if neg then
            ok = not ok
        end
        if not ok then
            fail(`Expected length {len} {prefix}to be {n}`)
        end
    end

    e.toBeType = function(_self, t: string): ()
        count()
        local at = typeof(actual)
        local ok = (at == t)
        if neg then
            ok = not ok
        end
        if not ok then
            fail(`Expected type "{at}" {prefix}to be "{t}"`)
        end
    end

    e.toBeFrozen = function(_self): ()
        count()
        local ok = typeof(actual) == "table" and table.isfrozen(actual)
        if neg then
            ok = not ok
        end
        if not ok then
            fail(`Expected {fmt(actual)} {prefix}to be a frozen table`)
        end
    end

    e.toMatchBuffer = function(_self, bytes: { number }): ()
        count()
        if typeof(actual) ~= "buffer" then
            fail(`Expected buffer, got {typeof(actual)}`)
        end
        local b = actual :: buffer
        local n = #bytes
        local len = buffer.len(b)
        local ok = (len == n)
        if ok then
            for i = 1, n do
                if buffer.readu8(b, i - 1) ~= bytes[i] then
                    ok = false
                    break
                end
            end
        end
        if neg then
            ok = not ok
        end
        if not ok then
            local actualBytes = table.create(len)
            for i = 0, len - 1 do
                actualBytes[i + 1] = string.format("%02X", buffer.readu8(b, i))
            end
            local expectedBytes = table.create(n)
            for i = 1, n do
                expectedBytes[i] = string.format("%02X", bytes[i])
            end
            fail(
                `Expected buffer bytes [{table.concat(expectedBytes, " ")}] {prefix}to match, got [{table.concat(
                    actualBytes,
                    " "
                )}]`
            )
        end
    end

    e.toBeBuffer = function(_self, len: number?): ()
        count()
        local isBuf = typeof(actual) == "buffer"
        local ok = isBuf
        if ok and len then
            ok = buffer.len(actual :: buffer) == len
        end
        if neg then
            ok = not ok
        end
        if not ok then
            fail(
                if len
                    then `Expected {fmt(actual)} {prefix}to be a buffer of length {len}`
                    else `Expected {fmt(actual)} {prefix}to be a buffer`
            )
        end
    end

    e.toContain = function(_self, value: any): ()
        count()
        local ok = false
        if typeof(actual) == "string" then
            ok = string.find(actual :: string, value, 1, true) ~= nil
        elseif typeof(actual) == "table" then
            for _, v in actual do
                if deepEqual(v, value) then
                    ok = true
                    break
                end
            end
        end
        if neg then
            ok = not ok
        end
        if not ok then
            fail(`Expected {fmt(actual)} {prefix}to contain {fmt(value)}`)
        end
    end

    e.toContainKey = function(_self, key: any): ()
        count()
        if typeof(actual) ~= "table" then
            fail(`Expected table, got {typeof(actual)}`)
        end
        local ok = (actual :: any)[key] ~= nil
        if neg then
            ok = not ok
        end
        if not ok then
            fail(`Expected table {prefix}to contain key {fmt(key)}`)
        end
    end

    e.toBeNaN = function(_self): ()
        count()
        local ok = typeof(actual) == "number" and actual ~= actual
        if neg then
            ok = not ok
        end
        if not ok then
            fail(`Expected {fmt(actual)} {prefix}to be NaN`)
        end
    end

    if not neg then
        e.never = build(actual, true, count)
    end

    return e :: Expectation
end

-- Public -----------------------------------------------------------------

local Expectation = {}

Expectation.build = build
Expectation.deepEqual = deepEqual

return table.freeze(Expectation)
