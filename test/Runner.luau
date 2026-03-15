--!strict
--!optimize 2
-- Test framework.

local Channel = require(script.Parent.Parent.core.Channel)
local Types   = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T>     = Types.Codec<T>

-- State ------------------------------------------------------------------

type Expectation = {
    toBe:       (self: Expectation, expected: any) -> (),
    toEqual:    (self: Expectation, expected: any) -> (),
    toBeNil:    (self: Expectation) -> (),
    toBeCloseTo:(self: Expectation, expected: number, tolerance: number?) -> (),
    toThrow:    (self: Expectation, pattern: string?) -> (),
    never:      Expectation,
}

type TestEntry = {
    name: string,
    fn:   () -> (),
}

type Suite = {
    name:  string,
    tests: { TestEntry },
}

local _suites  = {} :: { Suite }
local _current = nil :: Suite?
local _passed  = 0
local _failed  = 0
local _errors  = {} :: { string }

-- Private ----------------------------------------------------------------

local function deepEqual(a: any, b: any): boolean
    if a == b then return true end

    local typeA = typeof(a)
    if typeA ~= typeof(b) then return false end
    if typeA ~= "table" then return false end

    for k, v in a do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in b do
        if a[k] == nil then return false end
    end

    return true
end

local function formatValue(value: any): string
    local t = typeof(value)
    if t == "string" then return `"{value}"` end
    if t == "table" then return "{table}" end
    if t == "nil" then return "nil" end
    return tostring(value)
end

local function pass(name: string): ()
    _passed += 1
    print(`    ✓ {name}`)
end

local function fail(name: string, reason: string): ()
    _failed += 1
    local msg = `    ✗ {name} — {reason}`
    print(msg)
    table.insert(_errors, msg)
end

local function createExpectation(actual: any, isNegated: boolean): Expectation
    local expectation = {} :: any

    expectation.toBe = function(_self: Expectation, expected: any): ()
        local isMatch = actual == expected
        if isNegated then isMatch = not isMatch end

        if not isMatch then
            local prefix = if isNegated then "not " else ""
            error(`Expected {formatValue(actual)} {prefix}to be {formatValue(expected)}`)
        end
    end

    expectation.toEqual = function(_self: Expectation, expected: any): ()
        local isMatch = deepEqual(actual, expected)
        if isNegated then isMatch = not isMatch end

        if not isMatch then
            local prefix = if isNegated then "not " else ""
            error(`Expected {prefix}deep equality`)
        end
    end

    expectation.toBeNil = function(_self: Expectation): ()
        local isMatch = actual == nil
        if isNegated then isMatch = not isMatch end

        if not isMatch then
            local prefix = if isNegated then "not " else ""
            error(`Expected {formatValue(actual)} {prefix}to be nil`)
        end
    end

    expectation.toBeCloseTo = function(_self: Expectation, expected: number, tolerance: number?): ()
        local tol     = tolerance or 0.001
        local diff    = math.abs((actual :: number) - expected)
        local isMatch = diff <= tol
        if isNegated then isMatch = not isMatch end

        if not isMatch then
            local prefix = if isNegated then "not " else ""
            error(`Expected {actual} {prefix}to be within {tol} of {expected} (diff={diff})`)
        end
    end

    expectation.toThrow = function(_self: Expectation, pattern: string?): ()
        if typeof(actual) ~= "function" then
            error("toThrow expects a function")
        end

        local ok, err = pcall(actual :: () -> ())
        local didThrow = not ok
        if isNegated then didThrow = not didThrow end

        if isNegated then
            if not didThrow then
                error(`Expected function not to throw, but it threw: {err}`)
            end
        else
            if ok then
                error("Expected function to throw, but it did not")
            end
            if pattern and not string.find(tostring(err), pattern) then
                error(`Expected error matching "{pattern}", got: {err}`)
            end
        end
    end

    if not isNegated then
        expectation.never = createExpectation(actual, true) :: any
    end

    return expectation :: any
end

-- Public -----------------------------------------------------------------

local Runner = {}

function Runner.describe(name: string, fn: () -> ()): ()
    local suite: Suite = { name = name, tests = {} }
    local previous = _current
    _current = suite
    table.insert(_suites, suite)
    fn()
    _current = previous
end

function Runner.it(name: string, fn: () -> ()): ()
    if not _current then error("[Test] it() must be called inside describe()") end
    table.insert(_current.tests, { name = name, fn = fn })
end

function Runner.expect(actual: any): Expectation
    return createExpectation(actual, false)
end

function Runner.run(): boolean
    _passed = 0
    _failed = 0
    table.clear(_errors)

    print("\n══════════════════════════════════════════════════════════════")
    print("  Lync Test Suite")
    print("══════════════════════════════════════════════════════════════\n")

    for _, suite in _suites do
        print(`  {suite.name}`)
        for _, entry in suite.tests do
            local ok, err = pcall(entry.fn)
            if ok then
                pass(entry.name)
            else
                fail(entry.name, tostring(err))
            end
        end
        print("")
    end

    print("──────────────────────────────────────────────────────────────")
    print(`  {_passed} passed, {_failed} failed, {_passed + _failed} total`)
    if _failed > 0 then
        print("\n  Failures:")
        for _, msg in _errors do
            print(msg)
        end
    end
    print("══════════════════════════════════════════════════════════════\n")

    table.clear(_suites)
    return _failed == 0
end

--[[
    Writes a value through a codec then reads it back.
    Returns (decoded, bytesWritten, bytesConsumed).
    Callers that only need the value discard the trailing returns.
]]
function Runner.roundTrip(codec: Codec<any>, value: any): (any, number, number)
    local ch = Channel.create()
    codec.write(ch, value)

    local written = ch.cursor
    local buf     = buffer.create(written)
    buffer.copy(buf, 0, ch.buff, 0, written)

    local decoded, consumed = codec.read(buf, 0, ch.refs)
    assert(consumed == written, `Consumed {consumed} but wrote {written}`)
    return decoded, written, consumed
end

-- Returns a fake Player-like table for Gate/Group tests.
function Runner.fakePlayer(name: string?, userId: number?): any
    return {
        Name   = name or "TestPlayer",
        UserId = userId or 1,
    }
end

return table.freeze(Runner)
