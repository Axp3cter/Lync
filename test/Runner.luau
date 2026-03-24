--!strict
--!optimize 2
-- Test framework with describe/it/expect and round-trip helpers.

local Channel = require(script.Parent.Parent.internal.Channel)

-- Types ---------------------------------------------------------------

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

-- State ---------------------------------------------------------------

local _suites: { Suite } = {}
local _current: Suite? = nil
local _passed = 0
local _failed = 0
local _skipped = 0
local _errors: { string } = {}

-- Private -------------------------------------------------------------

local function deepEqual(a: any, b: any): boolean
    if a == b then
        return true
    end
    local tA = typeof(a)
    if tA ~= typeof(b) then
        return false
    end
    if tA ~= "table" then
        return false
    end
    for k, v in a do
        if not deepEqual(v, b[k]) then
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

local function fmt(value: any): string
    local t = typeof(value)
    if t == "string" then
        return `"{value}"`
    end
    if t == "table" then
        return "{table}"
    end
    if t == "nil" then
        return "nil"
    end
    return tostring(value)
end

local function createExpectation(actual: any, neg: boolean): Expectation
    local e = {} :: any
    local p = if neg then "not " else ""

    e.toBe = function(_s: Expectation, expected: any): ()
        local ok = (actual == expected)
        if neg then
            ok = not ok
        end
        if not ok then
            error(`Expected {fmt(actual)} {p}to be {fmt(expected)}`)
        end
    end

    e.toEqual = function(_s: Expectation, expected: any): ()
        local ok = deepEqual(actual, expected)
        if neg then
            ok = not ok
        end
        if not ok then
            error(`Expected {p}deep equality`)
        end
    end

    e.toBeNil = function(_s: Expectation): ()
        local ok = (actual == nil)
        if neg then
            ok = not ok
        end
        if not ok then
            error(`Expected {fmt(actual)} {p}to be nil`)
        end
    end

    e.toBeCloseTo = function(_s: Expectation, expected: number, tolerance: number?): ()
        local tol = tolerance or 0.001
        local diff = math.abs((actual :: number) - expected)
        local ok = (diff <= tol)
        if neg then
            ok = not ok
        end
        if not ok then
            error(`Expected {actual} {p}within {tol} of {expected} (diff={diff})`)
        end
    end

    e.toThrow = function(_s: Expectation, pattern: string?): ()
        if typeof(actual) ~= "function" then
            error("toThrow expects a function")
        end
        local ok, err = pcall(actual :: () -> ())
        if neg then
            if not ok then
                error(`Expected no throw, got: {err}`)
            end
        else
            if ok then
                error("Expected throw, got none")
            end
            if pattern and not string.find(tostring(err), pattern, 1, true) then
                error(`Expected error matching "{pattern}", got: {err}`)
            end
        end
    end

    e.toBeTruthy = function(_s: Expectation): ()
        local ok = (actual ~= nil and actual ~= false)
        if neg then
            ok = not ok
        end
        if not ok then
            error(`Expected {fmt(actual)} {p}to be truthy`)
        end
    end

    e.toBeFalsy = function(_s: Expectation): ()
        local ok = (actual == nil or actual == false)
        if neg then
            ok = not ok
        end
        if not ok then
            error(`Expected {fmt(actual)} {p}to be falsy`)
        end
    end

    e.toBeGreaterThan = function(_s: Expectation, n: number): ()
        local ok = ((actual :: number) > n)
        if neg then
            ok = not ok
        end
        if not ok then
            error(`Expected {actual} {p}> {n}`)
        end
    end

    e.toBeLessThan = function(_s: Expectation, n: number): ()
        local ok = ((actual :: number) < n)
        if neg then
            ok = not ok
        end
        if not ok then
            error(`Expected {actual} {p}< {n}`)
        end
    end

    e.toHaveLength = function(_s: Expectation, n: number): ()
        local len = #(actual :: any)
        local ok = (len == n)
        if neg then
            ok = not ok
        end
        if not ok then
            error(`Expected length {len} {p}to be {n}`)
        end
    end

    e.toBeType = function(_s: Expectation, t: string): ()
        local at = typeof(actual)
        local ok = (at == t)
        if neg then
            ok = not ok
        end
        if not ok then
            error(`Expected type {at} {p}to be {t}`)
        end
    end

    if not neg then
        e.never = createExpectation(actual, true) :: any
    end

    return e :: any
end

-- Public --------------------------------------------------------------

local Runner = {}

function Runner.describe(name: string, fn: () -> ()): ()
    local suite: Suite = { name = name, tests = {} }
    local prev = _current
    _current = suite
    table.insert(_suites, suite)
    fn()
    _current = prev
end

function Runner.it(name: string, fn: () -> ()): ()
    if not _current then
        error("it() must be inside describe()")
    end
    table.insert(_current.tests, { name = name, fn = fn, skipped = false })
end

function Runner.skip(name: string, _fn: (() -> ())?): ()
    if not _current then
        error("skip() must be inside describe()")
    end
    table.insert(_current.tests, { name = name, fn = nil, skipped = true })
end

function Runner.expect(actual: any): Expectation
    return createExpectation(actual, false)
end

function Runner.run(): boolean
    _passed = 0
    _failed = 0
    _skipped = 0
    table.clear(_errors)

    local t0 = os.clock()

    print(
        "╔══════════════════════════════════════════════════════════╗"
    )
    print("║                    Lync Test Suite                      ║")
    print(
        "╚══════════════════════════════════════════════════════════╝"
    )

    for _, suite in _suites do
        print(`  ┌ {suite.name}`)
        for _, entry in suite.tests do
            if entry.skipped then
                _skipped += 1
                print(`  │  ○ {entry.name}`)
            else
                local ok, err = pcall(entry.fn :: () -> ())
                if ok then
                    _passed += 1
                    print(`  │  ✓ {entry.name}`)
                else
                    _failed += 1
                    local msg = `  │  ✗ {entry.name} — {err}`
                    print(msg)
                    table.insert(_errors, msg)
                end
            end
        end
        print("  └")
    end

    local ms = math.round((os.clock() - t0) * 1000)
    local skipStr = if _skipped > 0 then `, {_skipped} skipped` else ""
    local total = _passed + _failed + _skipped

    print(
        "  ──────────────────────────────────────────────────────"
    )
    if _failed == 0 then
        print(`  ✓ {_passed} passed{skipStr} ({total} total, {ms}ms)`)
    else
        print(`  ✗ {_passed} passed, {_failed} FAILED{skipStr} ({total} total, {ms}ms)`)
        print("  ·")
        print("  Failures:")
        for _, msg in _errors do
            print(msg)
        end
    end
    print(
        "  ──────────────────────────────────────────────────────"
    )

    table.clear(_suites)
    return _failed == 0
end

function Runner.roundTrip(codec: any, value: any): (any, number, number)
    local ch = Channel.create()
    codec.write(ch, value)
    local written = ch.cursor
    local buf = buffer.create(written)
    buffer.copy(buf, 0, ch.buff, 0, written)
    local decoded, consumed = codec.read(buf, 0, ch.refs)
    assert(consumed == written, `Read {consumed} but wrote {written}`)
    return decoded, written, consumed
end

function Runner.roundTripRaw(codec: any, value: any): (any, number, buffer)
    local ch = Channel.create()
    codec.write(ch, value)
    local written = ch.cursor
    local buf = buffer.create(written)
    buffer.copy(buf, 0, ch.buff, 0, written)
    local decoded, consumed = codec.read(buf, 0, ch.refs)
    assert(consumed == written, `Read {consumed} but wrote {written}`)
    return decoded, written, buf
end

function Runner.fakePlayer(name: string?, userId: number?): any
    return {
        Name = name or "TestPlayer",
        UserId = userId or 1,
        IsA = function(_self: any, className: string): boolean
            return className == "Player"
        end,
        IsDescendantOf = function(): boolean
            return true
        end,
    }
end

return table.freeze(Runner)
