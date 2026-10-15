--!strict
--!optimize 2
-- The pooled coroutines: what a call runs on, what it cannot reach, and what returns to the pool.

local Threads = require("@src/kernel/Threads")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local CARRIED = 7
local ALSO = "beat"

-- Calls a case holds parked at once, which is what the pool has to grow to and no further.
local DEPTH = 5

type Ran = { thread: thread?, args: { n: number, [number]: any } }

-- A call that notes the thread it ran on and what it was handed.
local function noting(): (Ran, (...any) -> ())
    local held: Ran = { thread = nil, args = { n = 0 } }
    return held,
        function(...)
            held.thread = coroutine.running()
            held.args = table.pack(...)
        end
end

-- A call that notes where it ran and then parks on a bare yield, keeping its thread off the pool.
local function parking(): (Ran, () -> ())
    local held: Ran = { thread = nil, args = { n = 0 } }
    return held,
        function()
            held.thread = coroutine.running()
            coroutine.yield()
        end
end

return {
    Harness.case("threads.runs-now", function()
        local ran = false
        Threads.spawn(function()
            ran = true
        end)
        Expect.equal(ran, true)
    end),

    Harness.case("threads.its-own-thread", function()
        local held, call = noting()
        Threads.spawn(call)
        Expect.holds(held.thread ~= nil, "the call never ran")
        Expect.holds(held.thread ~= coroutine.running(), "the call ran on the caller's thread")
    end),

    -- Asked of a fresh thread and of a reused one, the two paths a call can take in.
    Harness.case("threads.arguments", function()
        local first, one = noting()
        Threads.spawn(one, CARRIED, ALSO)
        Expect.equal(first.args.n, 2)
        Expect.equal(first.args[1], CARRIED)
        Expect.equal(first.args[2], ALSO)

        local second, two = noting()
        Threads.spawn(two, ALSO)
        Expect.equal(second.args.n, 1)
        Expect.equal(second.args[1], ALSO)
    end),

    Harness.case("threads.reuses-a-parked-thread", function()
        local first, one = noting()
        Threads.spawn(one)
        local second, two = noting()
        Threads.spawn(two)
        Expect.equal(second.thread, first.thread)
    end),

    Harness.case("threads.a-yield-keeps-its-thread", function()
        local parked, park = parking()
        Threads.spawn(park)
        local other, call = noting()
        Threads.spawn(call)
        Expect.holds(parked.thread ~= nil, "the parked call never ran")
        Expect.holds(other.thread ~= parked.thread, "a parked thread was handed out again")
    end),

    Harness.case("threads.a-finished-yield-returns-its-thread", function()
        local parked, park = parking()
        Threads.spawn(park)

        local held = parked.thread :: thread
        coroutine.resume(held)
        Expect.equal(coroutine.status(held), "suspended")

        local after, call = noting()
        Threads.spawn(call)
        Expect.equal(after.thread, held)
    end),

    Harness.case("threads.grows-to-the-depth", function()
        local parked: { Ran } = {}
        for _ = 1, DEPTH do
            local held, park = parking()
            Threads.spawn(park)
            table.insert(parked, held)
        end

        local seen: { [thread]: boolean } = {}
        for _, held in parked do
            local thread = held.thread :: thread
            Expect.holds(thread ~= nil, "a parked call never ran")
            Expect.holds(seen[thread] == nil, "one thread was handed to two calls at once")
            seen[thread] = true
        end

        for _, held in parked do
            coroutine.resume(held.thread :: thread)
        end
    end),

    Harness.case("threads.a-raise-does-not-reach-the-caller", function()
        local after = false
        Threads.spawn(function()
            error("a listener with a mistake in it", 0)
        end)
        after = true
        Expect.equal(after, true)
    end),

    -- The line that returns a thread sits after the call, so a raise walks past it like a yield.
    Harness.case("threads.a-raise-drops-its-thread", function()
        local held, call = noting()
        Threads.spawn(call)

        local was = held.thread :: thread
        Threads.spawn(function()
            error("a listener with a mistake in it", 0)
        end)

        local after, second = noting()
        Threads.spawn(second)
        Expect.holds(after.thread ~= nil, "the call after a raise never ran")
        Expect.holds(
            coroutine.status(after.thread :: thread) ~= "dead",
            "a dead thread was handed out"
        )
        Expect.holds(after.thread ~= was or coroutine.status(was) ~= "dead", "it took a dead one")
    end),

    Harness.case("threads.nested", function()
        local inner, call = noting()
        local outer: thread? = nil

        Threads.spawn(function()
            outer = coroutine.running()
            Threads.spawn(call)
        end)

        Expect.holds(outer ~= nil, "the outer call never ran")
        Expect.holds(inner.thread ~= nil, "the inner call never ran")
        Expect.holds(inner.thread ~= outer, "the inner call ran on the outer call's thread")
    end),
}
