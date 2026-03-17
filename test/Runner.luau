--!strict
--!optimize 2
-- Test framework.

local Channel = require (script.Parent.Parent.internal.Channel)

-- State ------------------------------------------------------------------

type Expectation = {
    toBe: (self: Expectation, expected: any) -> (),
    toEqual: (self: Expectation, expected: any) -> (),
    toBeNil: (self: Expectation) -> (),
    toBeCloseTo: (self: Expectation, expected: number, tolerance: number?) -> (),
    toThrow: (self: Expectation, pattern: string?) -> (),
    toBeTruthy: (self: Expectation) -> (),
    toBeFalsy: (self: Expectation) -> (),
    toBeGreaterThan: (self: Expectation, n: number) -> (),
    toBeLessThan: (self: Expectation, n: number) -> (),
    toHaveLength: (self: Expectation, n: number) -> (),
    toBeType: (self: Expectation, t: string) -> (),
    never: Expectation,
}

type TestEntry = {
    name: string,
    fn: (() -> ())?,
    skipped: boolean,
}

type Suite = {
    name: string,
    tests: { TestEntry },
}

local _suites = {} :: { Suite }
local _current = nil :: Suite?
local _passed = 0
local _failed = 0
local _skipped = 0
local _errors = {} :: { string }

-- Private ----------------------------------------------------------------

local function deepEqual (a: any, b: any): boolean
    if a == b then
        return true
    end

    local typeA = typeof (a)
    if typeA ~= typeof (b) then
        return false
    end
    if typeA ~= "table" then
        return false
    end

    for k, v in a do
        if not deepEqual (v, b[k]) then
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

local function formatValue (value: any): string
    local t = typeof (value)
    if t == "string" then
        return `"{value}"`
    end
    if t == "table" then
        return "{table}"
    end
    if t == "nil" then
        return "nil"
    end
    return tostring (value)
end

local function pass (name: string): ()
    _passed += 1
    print (`    ✓ {name}`)
end

local function fail (name: string, reason: string): ()
    _failed += 1
    local msg = `    ✗ {name} — {reason}`
    print (msg)
    table.insert (_errors, msg)
end

local function createExpectation (actual: any, isNegated: boolean): Expectation
    local expectation = {} :: any

    expectation.toBe = function (_self: Expectation, expected: any): ()
        local isMatch = actual == expected
        if isNegated then
            isMatch = not isMatch
        end
        if not isMatch then
            local prefix = if isNegated then "not " else ""
            error (`Expected {formatValue (actual)} {prefix}to be {formatValue (expected)}`)
        end
    end

    expectation.toEqual = function (_self: Expectation, expected: any): ()
        local isMatch = deepEqual (actual, expected)
        if isNegated then
            isMatch = not isMatch
        end
        if not isMatch then
            local prefix = if isNegated then "not " else ""
            error (`Expected {prefix}deep equality`)
        end
    end

    expectation.toBeNil = function (_self: Expectation): ()
        local isMatch = actual == nil
        if isNegated then
            isMatch = not isMatch
        end
        if not isMatch then
            local prefix = if isNegated then "not " else ""
            error (`Expected {formatValue (actual)} {prefix}to be nil`)
        end
    end

    expectation.toBeCloseTo = function (_self: Expectation, expected: number, tolerance: number?): ()
        local tol = tolerance or 0.001
        local diff = math.abs ((actual :: number) - expected)
        local isMatch = diff <= tol
        if isNegated then
            isMatch = not isMatch
        end
        if not isMatch then
            local prefix = if isNegated then "not " else ""
            error (`Expected {actual} {prefix}to be within {tol} of {expected} (diff={diff})`)
        end
    end

    expectation.toThrow = function (_self: Expectation, pattern: string?): ()
        if typeof (actual) ~= "function" then
            error ("toThrow expects a function")
        end

        local ok, err = pcall (actual :: () -> ())
        if isNegated then
            if not ok then
                error (`Expected function not to throw, but it threw: {err}`)
            end
        else
            if ok then
                error ("Expected function to throw, but it did not")
            end
            if pattern and not string.find (tostring (err), pattern) then
                error (`Expected error matching "{pattern}", got: {err}`)
            end
        end
    end

    expectation.toBeTruthy = function (_self: Expectation): ()
        local isMatch = actual ~= nil and actual ~= false
        if isNegated then
            isMatch = not isMatch
        end
        if not isMatch then
            local prefix = if isNegated then "not " else ""
            error (`Expected {formatValue (actual)} {prefix}to be truthy`)
        end
    end

    expectation.toBeFalsy = function (_self: Expectation): ()
        local isMatch = actual == nil or actual == false
        if isNegated then
            isMatch = not isMatch
        end
        if not isMatch then
            local prefix = if isNegated then "not " else ""
            error (`Expected {formatValue (actual)} {prefix}to be falsy`)
        end
    end

    expectation.toBeGreaterThan = function (_self: Expectation, n: number): ()
        local isMatch = (actual :: number) > n
        if isNegated then
            isMatch = not isMatch
        end
        if not isMatch then
            local prefix = if isNegated then "not " else ""
            error (`Expected {actual} {prefix}to be greater than {n}`)
        end
    end

    expectation.toBeLessThan = function (_self: Expectation, n: number): ()
        local isMatch = (actual :: number) < n
        if isNegated then
            isMatch = not isMatch
        end
        if not isMatch then
            local prefix = if isNegated then "not " else ""
            error (`Expected {actual} {prefix}to be less than {n}`)
        end
    end

    expectation.toHaveLength = function (_self: Expectation, n: number): ()
        local len = #(actual :: any)
        local isMatch = len == n
        if isNegated then
            isMatch = not isMatch
        end
        if not isMatch then
            local prefix = if isNegated then "not " else ""
            error (`Expected length {len} {prefix}to be {n}`)
        end
    end

    expectation.toBeType = function (_self: Expectation, t: string): ()
        local actualType = typeof (actual)
        local isMatch = actualType == t
        if isNegated then
            isMatch = not isMatch
        end
        if not isMatch then
            local prefix = if isNegated then "not " else ""
            error (`Expected type {actualType} {prefix}to be {t}`)
        end
    end

    if not isNegated then
        expectation.never = createExpectation (actual, true) :: any
    end

    return expectation :: any
end

-- Public -----------------------------------------------------------------

local Runner = {}

function Runner.describe (name: string, fn: () -> ()): ()
    local suite: Suite = { name = name, tests = {} }
    local previous = _current
    _current = suite
    table.insert (_suites, suite)
    fn ()
    _current = previous
end

function Runner.it (name: string, fn: () -> ()): ()
    if not _current then
        error ("[Lync] Test it() must be called inside describe()")
    end
    table.insert (_current.tests, { name = name, fn = fn, skipped = false })
end

function Runner.skip (name: string, _fn: (() -> ())?): ()
    if not _current then
        error ("[Lync] Test skip() must be called inside describe()")
    end
    table.insert (_current.tests, { name = name, fn = nil, skipped = true })
end

function Runner.expect (actual: any): Expectation
    return createExpectation (actual, false)
end

function Runner.run (): boolean
    _passed = 0
    _failed = 0
    _skipped = 0
    table.clear (_errors)

    local totalStart = os.clock ()

    print (
        "\n══════════════════════════════════════════════════════════════"
    )
    print ("  Lync Test Suite")
    print (
        "══════════════════════════════════════════════════════════════\n"
    )

    for _, suite in _suites do
        local suiteStart = os.clock ()
        print (`  {suite.name}`)
        for _, entry in suite.tests do
            if entry.skipped then
                _skipped += 1
                print (`    ○ skipped: {entry.name}`)
            else
                local ok, err = pcall (entry.fn :: () -> ())
                if ok then
                    pass (entry.name)
                else
                    fail (entry.name, tostring (err))
                end
            end
        end
        local suiteMs = math.floor ((os.clock () - suiteStart) * 1000 + 0.5)
        if suiteMs > 0 then
            print (`    ({suiteMs}ms)`)
        end
        print ("")
    end

    local totalMs = math.floor ((os.clock () - totalStart) * 1000 + 0.5)

    print (
        "──────────────────────────────────────────────────────────────"
    )
    local skipStr = if _skipped > 0 then `, {_skipped} skipped` else ""
    print (
        `  {_passed} passed, {_failed} failed{skipStr}, {_passed + _failed + _skipped} total ({totalMs}ms)`
    )
    if _failed > 0 then
        print ("\n  Failures:")
        for _, msg in _errors do
            print (msg)
        end
    end
    print (
        "══════════════════════════════════════════════════════════════\n"
    )

    table.clear (_suites)
    return _failed == 0
end

-- Writes a value through a codec then reads it back.
-- Returns (decoded, bytesWritten, bytesConsumed).
function Runner.roundTrip (codec: any, value: any): (any, number, number)
    local ch = Channel.create ()
    codec.write (ch, value)

    local written = ch.cursor
    local buf = buffer.create (written)
    buffer.copy (buf, 0, ch.buff, 0, written)

    local decoded, consumed = codec.read (buf, 0, ch.refs)
    assert (consumed == written, `Consumed {consumed} but wrote {written}`)
    return decoded, written, consumed
end

-- Returns a fake Player-like table for Gate/Group tests.
function Runner.fakePlayer (name: string?, userId: number?): any
    return {
        Name = name or "TestPlayer",
        UserId = userId or 1,
    }
end

return table.freeze (Runner)
