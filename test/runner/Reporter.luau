--!strict
--!optimize 2
-- Pretty/TAP reporters. Receives suite results and emits formatted output.

-- Public types -----------------------------------------------------------

export type TestResult = {
    name: string,
    status: "passed" | "failed" | "skipped",
    error: string?,
    durationMs: number,
    assertions: number,
}

export type SuiteResult = {
    name: string,
    tests: { TestResult },
}

export type RunStats = {
    passed: number,
    failed: number,
    skipped: number,
    durationMs: number,
    assertions: number,
}

-- Private ----------------------------------------------------------------

local function pad(str: string, width: number): string
    local len = #str
    if len >= width then
        return str
    end
    return str .. string.rep(" ", width - len)
end

-- Public -----------------------------------------------------------------

local Reporter = {}

function Reporter.pretty(suites: { SuiteResult }, stats: RunStats): ()
    print("==============================================================")
    print("                       Lync Test Suite                       ")
    print("==============================================================")

    local failures: { string } = {}

    for _, suite in suites do
        if #suite.tests == 0 then
            continue
        end
        print(`  > {suite.name}`)
        for _, test in suite.tests do
            local marker: string
            if test.status == "passed" then
                marker = "  +"
            elseif test.status == "failed" then
                marker = "  X"
                table.insert(failures, `[{suite.name}] {test.name}: {test.error}`)
            else
                marker = "  -"
            end
            local annot = if test.assertions > 0 then ` ({test.assertions} asserts)` else ""
            print(`    {marker} {test.name}{annot}`)
        end
    end

    print("  --------------------------------------------------------------")
    if stats.failed == 0 then
        print(
            `  PASS  {stats.passed} passed, {stats.skipped} skipped ({stats.assertions} assertions, {stats.durationMs}ms)`
        )
    else
        print(
            `  FAIL  {stats.passed} passed, {stats.failed} FAILED, {stats.skipped} skipped ({stats.assertions} assertions, {stats.durationMs}ms)`
        )
        print("  Failures:")
        for _, msg in failures do
            print(`    - {msg}`)
        end
    end
    print("==============================================================")
end

function Reporter.tap(suites: { SuiteResult }, stats: RunStats): ()
    local total = stats.passed + stats.failed + stats.skipped
    print(`1..{total}`)
    local idx = 0
    for _, suite in suites do
        for _, test in suite.tests do
            idx += 1
            local fullName = `{suite.name} :: {test.name}`
            if test.status == "passed" then
                print(`ok {idx} {fullName}`)
            elseif test.status == "failed" then
                print(`not ok {idx} {fullName}`)
                print(`# {test.error}`)
            else
                print(`ok {idx} {fullName} # SKIP`)
            end
        end
    end
    print(`# tests {total}`)
    print(`# pass {stats.passed}`)
    print(`# fail {stats.failed}`)
    print(`# skip {stats.skipped}`)
end

function Reporter.compact(suites: { SuiteResult }, stats: RunStats): ()
    --[[
        Compact reporter: one line per suite. Only failed tests show details.
        Useful when running thousands of tests where pretty would flood output.
    ]]
    print("==============================================================")
    print("                       Lync Test Suite                       ")
    print("==============================================================")

    local failures: { { suite: string, test: string, error: string } } = {}

    for _, suite in suites do
        local p, f, s = 0, 0, 0
        for _, test in suite.tests do
            if test.status == "passed" then
                p += 1
            elseif test.status == "failed" then
                f += 1
                table.insert(failures, {
                    suite = suite.name,
                    test = test.name,
                    error = test.error or "?",
                })
            else
                s += 1
            end
        end
        --[[
            Skip empty suites. Outer describes that only contain nested
            describes (no direct it() tests) carry zero results and would
            otherwise print as "0/0", which is misleading noise.
        ]]
        if p + f + s == 0 then
            continue
        end
        local marker = if f == 0 then "PASS" else "FAIL"
        local label = pad(suite.name, 60)
        print(`  {marker}  {label}  {p}/{p + f + s}`)
    end

    print("  --------------------------------------------------------------")
    if stats.failed == 0 then
        print(
            `  ALL PASS  {stats.passed} passed, {stats.skipped} skipped ({stats.assertions} assertions, {stats.durationMs}ms)`
        )
    else
        print(
            `  FAIL  {stats.passed} passed, {stats.failed} FAILED, {stats.skipped} skipped ({stats.assertions} assertions, {stats.durationMs}ms)`
        )
        print("  Failures:")
        for _, f in failures do
            print(`    [{f.suite}] {f.test}`)
            print(`      {f.error}`)
        end
    end
    print("==============================================================")
end

return table.freeze(Reporter)
