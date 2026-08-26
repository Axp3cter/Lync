--!strict
--!optimize 2
--[[
    The pooled coroutines: what a call runs on, what it cannot reach, and what returns to the pile.
]]

local Threads = require ("@src/kernel/Threads")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- What a spawn carries, so a case can say the arguments arrived and not only that something did.
const CARRIED = 7
const ALSO = "beat"

-- Calls a case holds parked at once, which is what the pile has to grow to and no further.
const DEPTH = 5

-- Types ---------------------------------------------------------------

-- What a spawned call wrote down about where it ran, which is the whole of what these cases read.
type Ran = { thread: thread?, args: { n: number, [number]: any } }

-- Private -------------------------------------------------------------

-- A call that notes the thread it ran on and whatever it was handed, and the note it writes to.
local function noting (): (Ran, (...any) -> ())
    local held: Ran = { thread = nil, args = { n = 0 } }
    return held,
        function (...)
            held.thread = coroutine.running ()
            held.args = table.pack (...)
        end
end

--[[
    A call that notes where it ran and then parks, which is what keeps its thread off the pile.

    Parked with a bare yield rather than a wait, because what is being asked about is the pool and
    not the scheduler: a call that yields is a call that has not returned, however it came to yield.
]]
local function parking (): (Ran, () -> ())
    local held: Ran = { thread = nil, args = { n = 0 } }
    return held,
        function ()
            held.thread = coroutine.running ()
            coroutine.yield ()
        end
end

-- Public --------------------------------------------------------------

return {
    --[[
        A call runs now rather than next frame. A listener told about a frame a frame later is a
        listener reading a world that has moved, so the spawn has run the call by the time it comes
        back rather than having promised to.
    ]]
    Harness.case ("threads.runs-now", function ()
        local ran = false
        Threads.spawn (function () ran = true end)

        Expect.equal (ran, true)
    end),

    --[[
        The caller carries on while the call it made is still parked, which is what a listener
        that yields must not cost the fan that reached it.
    ]]
    Harness.case ("threads.its-own-thread", function ()
        local held, call = noting ()
        Threads.spawn (call)

        Expect.holds (held.thread ~= nil, "the call never ran")
        Expect.holds (held.thread ~= coroutine.running (), "the call ran on the caller's thread")
    end),

    --[[
        The arguments arrive, whatever there are of them. Asked of a fresh thread and of a reused
        one, since those are the two paths a call can take in and they answer alike.
    ]]
    Harness.case ("threads.arguments", function ()
        local first, one = noting ()
        Threads.spawn (one, CARRIED, ALSO)

        Expect.equal (first.args.n, 2)
        Expect.equal (first.args[1], CARRIED)
        Expect.equal (first.args[2], ALSO)

        local second, two = noting ()
        Threads.spawn (two, ALSO)

        Expect.equal (second.args.n, 1)
        Expect.equal (second.args[1], ALSO)
    end),

    --[[
        A thread that finished its call goes back on the pile, so the next call takes it rather than
        building one. The common case costs a pop and a push, which is the whole reason the pool is
        worth having at all.
    ]]
    Harness.case ("threads.reuses-a-parked-thread", function ()
        local first, one = noting ()
        Threads.spawn (one)

        local second, two = noting ()
        Threads.spawn (two)

        Expect.equal (second.thread, first.thread)
    end),

    --[[
        A call that yields never reaches the line that puts its thread back, so the next spawn
        builds another. That is the whole of the replacement rule and it costs a coroutine only
        where one was actually held.
    ]]
    Harness.case ("threads.a-yield-keeps-its-thread", function ()
        local parked, park = parking ()
        Threads.spawn (park)

        local other, call = noting ()
        Threads.spawn (call)

        Expect.holds (parked.thread ~= nil, "the parked call never ran")
        Expect.holds (other.thread ~= parked.thread, "a parked thread was handed out again")
    end),

    --[[
        And it goes back when the call it was holding finishes, however long that took. A pool that
        lost a thread to every yield would grow by one for every listener that ever waited, which is
        a leak with a slow fuse.
    ]]
    Harness.case ("threads.a-finished-yield-returns-its-thread", function ()
        local parked, park = parking ()
        Threads.spawn (park)

        local held = parked.thread :: thread
        coroutine.resume (held)
        Expect.equal (coroutine.status (held), "suspended")

        local after, call = noting ()
        Threads.spawn (call)

        Expect.equal (after.thread, held)
    end),

    --[[
        Five calls held at once are five threads and none of them is another, and the sixth after
        they return takes one of those five back. The pair is what says a call in flight is never
        handed out from under the one making it.
    ]]
    Harness.case ("threads.grows-to-the-depth", function ()
        local parked: { Ran } = {}
        for _ = 1, DEPTH do
            local held, park = parking ()
            Threads.spawn (park)
            table.insert (parked, held)
        end

        local seen: { [thread]: boolean } = {}
        for _, held in parked do
            local thread = held.thread :: thread
            Expect.holds (thread ~= nil, "a parked call never ran")
            Expect.holds (seen[thread] == nil, "one thread was handed to two calls at once")
            seen[thread] = true
        end

        for _, held in parked do
            coroutine.resume (held.thread :: thread)
        end
    end),

    --[[
        A call that raises does not reach whoever asked for it. A listener with a mistake in it is
        the place's own code, and a library that let that raise out of a fire would make every
        caller wrap every call in a guard against everybody else's listeners.
    ]]
    Harness.case ("threads.a-raise-does-not-reach-the-caller", function ()
        local after = false

        Threads.spawn (function () error ("a listener with a mistake in it", 0) end)
        after = true

        Expect.equal (after, true)
    end),

    --[[
        And the thread it raised on is not handed out again. The line that puts a thread back sits
        after the call, so a raise walks past it the way a yield does, and what would otherwise be
        handed out is a coroutine that is already dead.
    ]]
    Harness.case ("threads.a-raise-drops-its-thread", function ()
        local held, call = noting ()
        Threads.spawn (call)

        local was = held.thread :: thread
        Threads.spawn (function () error ("a listener with a mistake in it", 0) end)

        local after, second = noting ()
        Threads.spawn (second)

        Expect.holds (after.thread ~= nil, "the call after a raise never ran")
        Expect.holds (
            coroutine.status (after.thread :: thread) ~= "dead",
            "a dead thread was handed out"
        )
        Expect.holds (after.thread ~= was or coroutine.status (was) ~= "dead", "it took a dead one")
    end),

    --[[
        A spawn from inside a spawn, which is what a listener that fires something is. The inner
        call is on a thread of its own, since the outer one is in flight and a pool that handed it
        back would have one call running inside another.
    ]]
    Harness.case ("threads.nested", function ()
        local inner, call = noting ()
        local outer: thread? = nil

        Threads.spawn (function ()
            outer = coroutine.running ()
            Threads.spawn (call)
        end)

        Expect.holds (outer ~= nil, "the outer call never ran")
        Expect.holds (inner.thread ~= nil, "the inner call never ran")
        Expect.holds (inner.thread ~= outer, "the inner call ran on the outer call's thread")
    end),
}
