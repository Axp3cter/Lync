--!strict
-- The Lune runner: loads src and test through one resolver, drives every declaration at its
-- budget, and shrinks what fails. Usage: lune run test/run.luau [seed] [name filter]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Load = require("../scripts/Load")

-- Constants -----------------------------------------------------------

local TREES = { "units", "rules", "wire" }

-- Types ---------------------------------------------------------------

type Declaration = {
    kind: string,
    name: string,
    source: string?,
    run: (...any) -> (),
}

type Outcome = {
    ok: boolean,
    note: string?,
    detail: string?,
    cases: number,
}

local Expect = Load.file("test/harness/Expect.luau")
local Harness = Load.file("test/harness/init.luau")
local Rng = Load.file("test/harness/Rng.luau")
local Shrink = Load.file("test/harness/Shrink.luau")

-- Driving -------------------------------------------------------------

local seed: number = tonumber(process.args[1]) or Rng.BASE
local filter = process.args[2]

local function crashed(thrown: unknown): boolean
    return Expect.failed(thrown) == nil
end

local function reason(thrown: unknown): string
    local failure = Expect.failed(thrown)
    return if failure ~= nil then failure.message else `crashed: {tostring(thrown)}`
end

-- The name folded into the seed, so two properties on one schedule draw different streams.
local function schedule(name: string): number
    local folded = 0
    for index = 1, #name do
        folded = bit32.band(folded * 31 + string.byte(name, index), 0xFFFFFFFF)
    end
    return bit32.bxor(seed, folded)
end

-- Whether a shrink candidate reproduces the same class of fault, so the minimizer never wanders
-- toward a different bug or toward a generator that cannot settle.
local function repeats(run: (...any) -> (), tape: { number }, wasCrash: boolean): boolean
    local ok, thrown = pcall(run, Rng.replay(tape))
    if ok then return false end
    if string.find(tostring(thrown), Rng.UNSETTLED, 1, true) ~= nil then return false end
    return crashed(thrown) == wasCrash
end

local function drive(declaration: Declaration): Outcome
    if declaration.kind == "case" then
        local ok, thrown = pcall(declaration.run)
        return { ok = ok, note = if ok then nil else reason(thrown), cases = 1 }
    end

    local from = schedule(declaration.name)
    local budget: number = Harness.BUDGETS[declaration.source]
    for index = 1, budget do
        local rng = Rng.new(from + index)
        local ok, thrown = pcall(declaration.run, rng)
        if ok then continue end

        local wasCrash = crashed(thrown)
        local minimal = Shrink.run(rng:tape(), function(tape: { number }): boolean
            return repeats(declaration.run, tape, wasCrash)
        end)
        return {
            ok = false,
            note = reason(thrown),
            detail = `seed {from + index}, tape {table.concat(minimal, " ")}`,
            cases = index,
        }
    end
    return { ok = true, cases = budget }
end

local function elapsed(from: number): string
    return string.format("%.0f ms", (os.clock() - from) * 1000)
end

-- Run -----------------------------------------------------------------

local started = os.clock()
local passed, failed = 0, 0
print(`Lync test: seed {seed}`)

for _, tree in TREES do
    local dir = `test/{tree}`
    if not fs.isDir(dir) then continue end

    local files = fs.readDir(dir)
    table.sort(files)
    print(`  {tree}`)

    for _, file in files do
        local list = Load.file(`{dir}/{file}`) :: { Declaration }
        assert(typeof(list) == "table" and #list > 0, `{dir}/{file} returns no declarations`)

        for _, declaration in list do
            if filter ~= nil and not string.find(declaration.name, filter, 1, true) then
                continue
            end

            local began = os.clock()
            local outcome = drive(declaration)
            if outcome.ok then
                passed += 1
                print(`    ok   {declaration.name}  {outcome.cases} cases  {elapsed(began)}`)
                continue
            end

            failed += 1
            print(`    FAIL {declaration.name}  after {outcome.cases} cases`)
            print(`         {outcome.note}`)
            if outcome.detail ~= nil then print(`         {outcome.detail}`) end
        end
    end
end

print(`\n  {passed} passed, {failed} failed in {elapsed(started)}`)
process.exit(if failed == 0 then 0 else 1)
