--!strict
--!optimize 2
-- The minimizer: shrinks the draws a failing case was built from, never the case itself.

local Shrink = {}

-- Constants -----------------------------------------------------------

-- Predicate calls one minimization may spend. It only runs after a red case, so a green run pays
-- nothing.
local BUDGET = 1000

-- Types ---------------------------------------------------------------

-- The words a generator drew, in order. Every value a shorter tape builds is one the generator
-- was willing to build, so a minimized case keeps its invariants.
export type Tape = { number }

type Run = {
    tape: Tape,
    fails: (Tape) -> boolean,
    calls: number,
    budget: number,
}

-- Private -------------------------------------------------------------

-- Shorter first, then word by word. Well founded, so no run of accepted shrinks can go on forever.
local function isSmaller(a: Tape, b: Tape): boolean
    if #a ~= #b then return #a < #b end
    for index, word in a do
        if word ~= b[index] then return word < b[index] end
    end
    return false
end

local function deleted(tape: Tape, from: number, count: number): Tape
    local out = table.create(#tape - count, 0)
    table.move(tape, 1, from - 1, 1, out)
    table.move(tape, from + count, #tape, from, out)
    return out
end

local function zeroed(tape: Tape, from: number, count: number): Tape
    local out = table.clone(tape)
    for index = from, from + count - 1 do
        out[index] = 0
    end
    return out
end

local function replaced(tape: Tape, index: number, word: number): Tape
    local out = table.clone(tape)
    out[index] = word
    return out
end

-- Spends a call only on a candidate that would be an improvement, and keeps the last call of the
-- budget for the confirmation at the end.
local function accept(run: Run, candidate: Tape): boolean
    if run.calls >= run.budget - 1 then return false end
    if not isSmaller(candidate, run.tape) then return false end

    run.calls += 1
    if not run.fails(candidate) then return false end

    run.tape = candidate
    return true
end

-- Whole runs first, halving the width. One deletion that lands removes more than any word tweak.
local function deletions(run: Run): boolean
    local progressed = false
    local width = #run.tape
    while width >= 1 do
        local index = 1
        while index + width - 1 <= #run.tape do
            if accept(run, deleted(run.tape, index, width)) then
                progressed = true
            else
                index += 1
            end
        end
        width //= 2
    end
    return progressed
end

local function zeroes(run: Run): boolean
    local progressed = false
    local width = #run.tape
    while width >= 1 do
        for index = 1, #run.tape - width + 1 do
            if accept(run, zeroed(run.tape, index, width)) then progressed = true end
        end
        width //= 2
    end
    return progressed
end

-- Each surviving word walked toward zero: zero first, then bisection between the last word that
-- held and the first that did not.
local function words(run: Run): boolean
    local progressed = false
    for index = 1, #run.tape do
        local high = run.tape[index]
        if high == 0 then continue end

        if accept(run, replaced(run.tape, index, 0)) then
            progressed = true
            continue
        end

        local low = 0
        while high - low > 1 do
            local mid = (low + high) // 2
            if accept(run, replaced(run.tape, index, mid)) then
                progressed = true
                high = mid
            else
                low = mid
            end
        end
    end
    return progressed
end

-- Public --------------------------------------------------------------

-- The smallest tape found that still fails, and the calls spent. `fails` must be deterministic and
-- already hold for `tape`. The answer is confirmed once more at the end.
function Shrink.run(tape: Tape, fails: (Tape) -> boolean, budget: number?): (Tape, number)
    for index, word in tape do
        assert(word % 1 == 0 and word >= 0, `tape word {index} is {word}, wants a whole number`)
    end
    local allowance = budget or BUDGET
    assert(allowance >= 2, `shrink wants a budget of two or more calls, got {allowance}`)
    assert(fails(tape), "shrink wants a tape that already fails")

    local run: Run = { tape = tape, fails = fails, calls = 1, budget = allowance }
    local progressed = true
    while progressed and run.calls < run.budget do
        progressed = deletions(run)
        progressed = zeroes(run) or progressed
        progressed = words(run) or progressed
    end

    if run.tape == tape then return tape, run.calls end

    run.calls += 1
    if not run.fails(run.tape) then return tape, run.calls end
    return run.tape, run.calls
end

return table.freeze(Shrink)
