--!strict
--!optimize 2
-- describe/it/expect/beforeEach/afterEach with focused mode and assertion counting.

local Expectation = require(script.Expectation)
local Reporter = require(script.Reporter)

-- Public types -----------------------------------------------------------

type TestEntry = {
    name: string,
    fn: (() -> ())?,
    skipped: boolean,
    only: boolean,
}

type Suite = {
    name: string,
    tests: { TestEntry },
    beforeEach: { () -> () },
    afterEach: { () -> () },
    beforeAll: { () -> () },
    afterAll: { () -> () },
    hasOnly: boolean,
}

export type RunOptions = {
    reporter: ("pretty" | "tap" | "compact")?,
    pattern: string?,
}

-- State ------------------------------------------------------------------

local _suites: { Suite } = {}
local _current: Suite? = nil
local _hasGlobalOnly = false
local _assertionsInTest = 0
local _totalAssertions = 0

-- Private ----------------------------------------------------------------

local function ensureCurrent(): Suite
    if not _current then
        error("[Runner] describe() must wrap it()/beforeEach()/etc.")
    end
    return _current :: Suite
end

local function countAssertion(): ()
    _assertionsInTest += 1
    _totalAssertions += 1
end

local function runHooks(hooks: { () -> () }, label: string): string?
    for i, hook in hooks do
        local ok, err = pcall(hook)
        if not ok then
            return `{label} hook #{i} failed: {err}`
        end
    end
    return nil
end

-- Public -----------------------------------------------------------------

local Runner = {}

function Runner.describe(name: string, fn: () -> ()): ()
    local parent = _current
    local fullName = if parent then `{parent.name} > {name}` else name
    local suite: Suite = {
        name = fullName,
        tests = {},
        --[[
            Nested describes inherit beforeEach/afterEach from the enclosing
            describe at the moment they are created. Specs put beforeEach at
            the top of each describe body, so by the time a nested describe
            is reached the parent's hooks are already in place and the clone
            captures them.
        ]]
        beforeEach = if parent then table.clone(parent.beforeEach) else {},
        afterEach = if parent then table.clone(parent.afterEach) else {},
        beforeAll = {},
        afterAll = {},
        hasOnly = false,
    }
    table.insert(_suites, suite)

    _current = suite
    local ok, err = pcall(fn)
    _current = parent
    if not ok then
        error(`[Runner] describe("{name}") body threw: {err}`)
    end
end

local function makeIt()
    local itTbl = {}

    setmetatable(itTbl, {
        __call = function(_self, name: string, fn: () -> ()): ()
            local suite = ensureCurrent()
            table.insert(suite.tests, {
                name = name,
                fn = fn,
                skipped = false,
                only = false,
            })
        end,
    })

    function itTbl.skip(name: string, _fn: (() -> ())?): ()
        local suite = ensureCurrent()
        table.insert(suite.tests, {
            name = name,
            fn = nil,
            skipped = true,
            only = false,
        })
    end

    function itTbl.only(name: string, fn: () -> ()): ()
        local suite = ensureCurrent()
        suite.hasOnly = true
        _hasGlobalOnly = true
        table.insert(suite.tests, {
            name = name,
            fn = fn,
            skipped = false,
            only = true,
        })
    end

    return itTbl
end

Runner.it = makeIt() :: any

function Runner.beforeEach(fn: () -> ()): ()
    table.insert(ensureCurrent().beforeEach, fn)
end

function Runner.afterEach(fn: () -> ()): ()
    table.insert(ensureCurrent().afterEach, fn)
end

function Runner.beforeAll(fn: () -> ()): ()
    table.insert(ensureCurrent().beforeAll, fn)
end

function Runner.afterAll(fn: () -> ()): ()
    table.insert(ensureCurrent().afterAll, fn)
end

function Runner.expect(actual: any): Expectation.Expectation
    return Expectation.build(actual, false, countAssertion)
end

function Runner.run(options: RunOptions?): boolean
    local opts = options or {}
    local reporter = opts.reporter or "pretty"
    local pattern = opts.pattern

    _totalAssertions = 0

    local results: { Reporter.SuiteResult } = {}
    local stats: Reporter.RunStats = {
        passed = 0,
        failed = 0,
        skipped = 0,
        durationMs = 0,
        assertions = 0,
    }

    local t0 = os.clock()

    --[[
        Roblox enforces a ~10-second continuous-execution limit per thread.
        We yield unconditionally between every test so even a chain of
        fast tests can never exhaust the budget cumulatively. Tests with
        internal loops (fuzz, property, pipeline bench) MUST also call
        task.wait() inside their loops; the runner can only yield between
        tests, never mid-test.
    ]]
    local lastYieldClock = os.clock()

    for _, suite in _suites do
        local suiteResult: Reporter.SuiteResult = { name = suite.name, tests = {} }
        table.insert(results, suiteResult)

        local beforeAllErr = runHooks(suite.beforeAll, "beforeAll")
        if beforeAllErr then
            for _, entry in suite.tests do
                stats.failed += 1
                table.insert(suiteResult.tests, {
                    name = entry.name,
                    status = "failed",
                    error = beforeAllErr,
                    durationMs = 0,
                    assertions = 0,
                })
            end
            continue
        end

        for _, entry in suite.tests do
            local fullName = `{suite.name} > {entry.name}`
            if pattern and not string.find(fullName, pattern) then
                continue
            end

            if entry.skipped then
                stats.skipped += 1
                table.insert(suiteResult.tests, {
                    name = entry.name,
                    status = "skipped",
                    error = nil,
                    durationMs = 0,
                    assertions = 0,
                })
                continue
            end

            if _hasGlobalOnly and not entry.only and not suite.hasOnly then
                stats.skipped += 1
                table.insert(suiteResult.tests, {
                    name = entry.name,
                    status = "skipped",
                    error = nil,
                    durationMs = 0,
                    assertions = 0,
                })
                continue
            end

            if suite.hasOnly and not entry.only then
                stats.skipped += 1
                table.insert(suiteResult.tests, {
                    name = entry.name,
                    status = "skipped",
                    error = nil,
                    durationMs = 0,
                    assertions = 0,
                })
                continue
            end

            _assertionsInTest = 0
            local testT0 = os.clock()

            local beforeErr = runHooks(suite.beforeEach, "beforeEach")
            if beforeErr then
                stats.failed += 1
                table.insert(suiteResult.tests, {
                    name = entry.name,
                    status = "failed",
                    error = beforeErr,
                    durationMs = math.round((os.clock() - testT0) * 1000),
                    assertions = _assertionsInTest,
                })
                continue
            end

            local fullName_ = `{suite.name} > {entry.name}`
            print(`[run] {fullName_}`)

            local fn = entry.fn :: () -> ()
            local ok, err = pcall(fn)

            local afterErr = runHooks(suite.afterEach, "afterEach")

            -- Yield unconditionally so even fast tests can't accumulate past
            -- the 10s thread budget. Heavy tests must yield internally too.
            task.wait()
            lastYieldClock = os.clock()

            local elapsed = math.round((os.clock() - testT0) * 1000)
            print(`[done {elapsed}ms] {fullName_}`)

            if ok and _assertionsInTest == 0 then
                ok = false
                err = "no assertions made (test forgot to expect)"
            end

            if not ok then
                stats.failed += 1
                table.insert(suiteResult.tests, {
                    name = entry.name,
                    status = "failed",
                    error = tostring(err),
                    durationMs = elapsed,
                    assertions = _assertionsInTest,
                })
            elseif afterErr then
                stats.failed += 1
                table.insert(suiteResult.tests, {
                    name = entry.name,
                    status = "failed",
                    error = afterErr,
                    durationMs = elapsed,
                    assertions = _assertionsInTest,
                })
            else
                stats.passed += 1
                table.insert(suiteResult.tests, {
                    name = entry.name,
                    status = "passed",
                    error = nil,
                    durationMs = elapsed,
                    assertions = _assertionsInTest,
                })
            end
        end

        local afterAllErr = runHooks(suite.afterAll, "afterAll")
        if afterAllErr then
            stats.failed += 1
            table.insert(suiteResult.tests, {
                name = "afterAll",
                status = "failed",
                error = afterAllErr,
                durationMs = 0,
                assertions = 0,
            })
        end
    end

    stats.durationMs = math.round((os.clock() - t0) * 1000)
    stats.assertions = _totalAssertions

    if reporter == "tap" then
        Reporter.tap(results, stats)
    elseif reporter == "compact" then
        Reporter.compact(results, stats)
    else
        Reporter.pretty(results, stats)
    end

    -- Reset for next run; specs registered after this point start from scratch.
    table.clear(_suites)
    _current = nil
    _hasGlobalOnly = false

    return stats.failed == 0
end

return table.freeze(Runner)
