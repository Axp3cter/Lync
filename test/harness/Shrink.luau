--!strict
--!optimize 2
-- The minimizer: it shrinks the draws a case was built from, never the case itself.

local Shrink = {}

-- Constants -----------------------------------------------------------

--[[
    Predicate calls one minimization may spend. A shrink only ever runs after a red case, so the
    budget buys a smaller report and costs a green run nothing.
]]
const BUDGET = 1000

-- Types ---------------------------------------------------------------

--[[
    The words a generator drew, in order, which is the case itself. Shrinking the tape rather than
    the value it built is what lets a generated schema shrink at all: every value a shorter tape
    makes is one the generator was willing to make, so a minimized case holds its invariants.
]]
export type Tape = { number }

type Run = {
    tape: Tape,
    fails: (Tape) -> boolean,
    calls: number,
    budget: number,
}

-- Private -------------------------------------------------------------

--[[
    Shorter first, then word by word. Every accepted candidate is strictly smaller under this order
    and the order is well founded, which is the whole termination argument: no sequence of accepted
    shrinks can run forever.
]]
local function smaller (a: Tape, b: Tape): boolean
    if #a ~= #b then return #a < #b end

    for index, word in a do
        if word ~= b[index] then return word < b[index] end
    end
    return false
end

-- The fill is never read: the two moves together write every slot.
local function without (tape: Tape, from: number, count: number): Tape
    local out = table.create (#tape - count, 0)
    table.move (tape, 1, from - 1, 1, out)
    table.move (tape, from + count, #tape, from, out)
    return out
end

local function zeroed (tape: Tape, from: number, count: number): Tape
    local out = table.clone (tape)
    for index = from, from + count - 1 do
        out[index] = 0
    end
    return out
end

local function replaced (tape: Tape, index: number, word: number): Tape
    local out = table.clone (tape)
    out[index] = word
    return out
end

--[[
    Spends a call only on a candidate that would be an improvement if it held, and never the last
    one: the confirmation at the end is reserved out of the budget so the total is the number the
    caller asked for, not one more.
]]
local function attempt (run: Run, candidate: Tape): boolean
    if run.calls >= run.budget - 1 then return false end
    if not smaller (candidate, run.tape) then return false end

    run.calls += 1
    if not run.fails (candidate) then return false end

    run.tape = candidate
    return true
end

--[[
    Whole runs first, halving the width. One deletion that lands removes more than any number of
    word tweaks, and it is the only pass that can take a case from hundreds of draws to a handful.
]]
local function deletions (run: Run): boolean
    local progressed = false

    local width = #run.tape
    while width >= 1 do
        local index = 1
        while index + width - 1 <= #run.tape do
            if attempt (run, without (run.tape, index, width)) then
                progressed = true
            else
                index += 1
            end
        end
        width //= 2
    end
    return progressed
end

-- A zero is the smallest word a generator can be handed, and often the clearest.
local function zeroes (run: Run): boolean
    local progressed = false

    local width = #run.tape
    while width >= 1 do
        for index = 1, #run.tape - width + 1 do
            if attempt (run, zeroed (run.tape, index, width)) then progressed = true end
        end
        width //= 2
    end
    return progressed
end

--[[
    Whatever survived, walked down toward zero: zero first, then bisection between the last word
    that held and the first that did not. A word costs about log2 of its value rather than a pass of
    its own.
]]
local function words (run: Run): boolean
    local progressed = false

    for index = 1, #run.tape do
        local high = run.tape[index]
        if high == 0 then continue end

        if attempt (run, replaced (run.tape, index, 0)) then
            progressed = true
            continue
        end

        local low = 0
        while high - low > 1 do
            local mid = (low + high) // 2
            if attempt (run, replaced (run.tape, index, mid)) then
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

--[[
    The smallest tape this could find that still fails, and the calls it spent. `fails` must be
    deterministic and must already hold for `tape`. The answer is confirmed once more at the end,
    a minimal case that does not reproduce being worse to receive than the large one that did.
]]
function Shrink.run (tape: Tape, fails: (Tape) -> boolean, budget: number?): (Tape, number)
    for index, word in tape do
        assert (
            word % 1 == 0 and word >= 0,
            `tape word {index} is {word}, wants a whole number at or above zero`
        )
    end
    local allowance = budget or BUDGET
    assert (allowance >= 2, `shrink wants a budget of two or more calls, got {allowance}`)
    assert (fails (tape), "shrink wants a tape that already fails")

    local run: Run = { tape = tape, fails = fails, calls = 1, budget = allowance }

    local progressed = true
    while progressed and run.calls < run.budget do
        progressed = false
        if deletions (run) then progressed = true end
        if zeroes (run) then progressed = true end
        if words (run) then progressed = true end
    end

    if run.tape == tape then return tape, run.calls end

    run.calls += 1
    if not run.fails (run.tape) then return tape, run.calls end
    return run.tape, run.calls
end

return table.freeze (Shrink)
