--!strict
--!optimize 2
--[[
    What a fan reaches while it is walking, and what the list holds once it has finished.
]]

local Listeners = require ("@src/kernel/Listeners")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- What a fan carries, so a case can say the arguments arrived and not only that something did.
const CARRIED = 7
const ALSO = "beat"

-- Rounds a churn case attaches and drops over, which is far more than any list would hold at once.
const CHURN = 64

-- Types ---------------------------------------------------------------

type List = Listeners.List<...any>

-- Private -------------------------------------------------------------

-- A list reached by a plain call, which is what a fan does with the runner it was made with.
local function list (): List
    return Listeners.list (function (fn: (...any) -> (), ...: any) fn (...) end)
end

-- A listener that writes its own name down when it is reached, and the list it writes to.
local function noting (into: { string }, name: string): (...any) -> ()
    return function () table.insert (into, name) end
end

-- Every listener a fan reached, in the order it reached them.
local function reached (of: List, into: { string }): string
    table.clear (into)
    Listeners.fan (of)
    return table.concat (into, " ")
end

-- Public --------------------------------------------------------------

return {
    --[[
        A list nobody has registered on. The count is a number kept rather than a walk, because
        whether anybody is listening is the first test a packet arriving at nobody makes and a walk
        would make that test cost the length of the list.
    ]]
    Harness.case ("listeners.empty", function ()
        local of = list ()

        Expect.equal (of.live, 0)
        Expect.equal (#of.links, 0)

        local seen = {}
        Expect.equal (reached (of, seen), "")
    end),

    --[[
        Registrations are reached in the order they were made. A caller writing two listeners on one
        thing has written which of them goes first, and a library reaching them in any other order
        would make that an accident of how the list happened to be laid out.
    ]]
    Harness.case ("listeners.order", function ()
        local of = list ()
        local seen: { string } = {}

        for _, name in { "first", "second", "third" } do
            Listeners.connect (of, noting (seen, name))
        end

        Expect.equal (of.live, 3)
        Expect.equal (reached (of, seen), "first second third")
    end),

    --[[
        The connection a registration hands back is the link itself, so what a caller reads and what
        the fan reads can never drift apart. A caller sees exactly the two names the surface
        promises and the fan sees the one nothing outside the module reads.
    ]]
    Harness.case ("listeners.connection-is-the-link", function ()
        local of = list ()
        local seen: { string } = {}
        local link = Listeners.connect (of, noting (seen, "one"))

        Expect.equal (link.connected, true)
        Expect.equal (typeof (link.disconnect), "function")
        Expect.equal (of.links[1], link)

        link:disconnect ()
        Expect.equal (link.connected, false)
        Expect.equal (of.live, 0)
        Expect.equal (reached (of, seen), "")
    end),

    --[[
        A connection let go twice is a connection let go once. A caller holding one through a
        teardown has no way to know whether the teardown already ran, and a count that went down
        twice would silence a listener that was never dropped.
    ]]
    Harness.case ("listeners.disconnect-twice", function ()
        local of = list ()
        local seen: { string } = {}

        local one = Listeners.connect (of, noting (seen, "one"))
        Listeners.connect (of, noting (seen, "two"))

        one:disconnect ()
        one:disconnect ()
        one:disconnect ()

        Expect.equal (of.live, 1)
        Expect.equal (reached (of, seen), "two")
    end),

    --[[
        A listener attached while a fan is walking does not reach that fan. The length is taken once
        at the start, so what a fan delivers to is fixed when it begins: a listener that registered
        because of something this fan carried would otherwise be handed the thing that made it.
    ]]
    Harness.case ("listeners.attached-during-a-fan", function ()
        local of = list ()
        local seen: { string } = {}

        local once = false
        Listeners.connect (of, function ()
            table.insert (seen, "first")
            if once then return end

            once = true
            Listeners.connect (of, noting (seen, "late"))
        end)
        Listeners.connect (of, noting (seen, "second"))

        Listeners.fan (of)
        Expect.equal (table.concat (seen, " "), "first second")

        -- And it is reached by the next one, since it was registered by then.
        Expect.equal (reached (of, seen), "first second late")
    end),

    --[[
        A listener that drops a sibling ahead of it drops it now. The connected flag is read at the
        link rather than taken with the length, so a teardown one listener performs is a teardown
        the rest of this fan respects.
    ]]
    Harness.case ("listeners.dropped-ahead-during-a-fan", function ()
        local of = list ()
        local seen: { string } = {}

        local later: Listeners.Link<...any>
        Listeners.connect (of, function ()
            table.insert (seen, "first")
            later:disconnect ()
        end)
        later = Listeners.connect (of, noting (seen, "later"))
        Listeners.connect (of, noting (seen, "last"))

        Listeners.fan (of)
        Expect.equal (table.concat (seen, " "), "first last")
        Expect.equal (of.live, 2)
    end),

    --[[
        One that drops a sibling already reached changes nothing about this fan, and the sibling
        is gone from the next. Both halves are asked, since a drop that took effect immediately
        would be indistinguishable here from one that never took effect at all.
    ]]
    Harness.case ("listeners.dropped-behind-during-a-fan", function ()
        local of = list ()
        local seen: { string } = {}

        local early = Listeners.connect (of, noting (seen, "early"))
        Listeners.connect (of, function ()
            table.insert (seen, "second")
            early:disconnect ()
        end)

        Listeners.fan (of)
        Expect.equal (table.concat (seen, " "), "early second")
        Expect.equal (reached (of, seen), "second")
    end),

    --[[
        A listener that lets itself go, which is what a caller writes for something they want once.
        It is reached this time because the flag was true when the fan got to it, and never again.
    ]]
    Harness.case ("listeners.drops-itself", function ()
        local of = list ()
        local seen: { string } = {}

        local once: Listeners.Link<...any>
        once = Listeners.connect (of, function ()
            table.insert (seen, "once")
            once:disconnect ()
        end)
        Listeners.connect (of, noting (seen, "always"))

        Listeners.fan (of)
        Expect.equal (table.concat (seen, " "), "once always")
        Expect.equal (reached (of, seen), "always")
    end),

    --[[
        Nothing is taken out of the array while a fan is walking it. A fan holding an array that
        shifted would skip a listener or run one twice, so the depth is counted and the compaction
        waits for it, which is what makes a listener dropping another safe at all.
    ]]
    Harness.case ("listeners.no-sweep-while-fanning", function ()
        local of = list ()
        local seen: { string } = {}
        local held = 0

        local later: Listeners.Link<...any>
        Listeners.connect (of, function ()
            table.insert (seen, "first")
            later:disconnect ()

            -- Read inside the fan, which is the one moment the array is allowed to hold a dead one.
            held = #of.links
        end)
        later = Listeners.connect (of, noting (seen, "later"))
        Listeners.connect (of, noting (seen, "last"))

        Listeners.fan (of)

        Expect.equal (held, 3)
        Expect.equal (#of.links, 2)
        Expect.equal (table.concat (seen, " "), "first last")
    end),

    --[[
        The survivors keep the order they were registered in. Swapping the last link into the hole
        is a quarter of the work and it puts a listener registered last ahead of ones registered
        before it, which is a delivery order that changes with the history of a list.
    ]]
    Harness.case ("listeners.sweep-keeps-order", function ()
        local of = list ()
        local seen: { string } = {}

        local links: { Listeners.Link<...any> } = {}
        for _, name in { "a", "b", "c", "d", "e" } do
            table.insert (links, Listeners.connect (of, noting (seen, name)))
        end

        links[2]:disconnect ()
        links[3]:disconnect ()

        Expect.equal (#of.links, 3)
        Expect.equal (reached (of, seen), "a d e")
    end),

    --[[
        A list under churn does not grow. Attaching and detaching in a loop leaves a dead link each
        time, and a list nobody ever compacts is a leak measured in frames, so the array is held to
        what is live rather than to what has ever been.
    ]]
    Harness.case ("listeners.sweep-under-churn", function ()
        local of = list ()
        local seen: { string } = {}
        Listeners.connect (of, noting (seen, "kept"))

        for _ = 1, CHURN do
            local held = Listeners.connect (of, noting (seen, "passing"))
            held:disconnect ()
        end

        Expect.equal (of.live, 1)
        Expect.equal (#of.links, 1)
        Expect.equal (reached (of, seen), "kept")
    end),

    --[[
        How a listener is reached is the list's rather than the fan's, because a list is made once
        and fanned forever. What a fan owes the runner is the function and whatever it was handed,
        in that order and unchanged.
    ]]
    Harness.case ("listeners.runner", function ()
        local through = 0
        local of: List = Listeners.list (function (fn: (...any) -> (), ...: any)
            through += 1
            fn (...)
        end)

        local held: { n: number, [number]: any } = { n = 0 }
        Listeners.connect (of, function (...) held = table.pack (...) end)
        Listeners.connect (of, function () end)

        Listeners.fan (of, CARRIED, ALSO)

        Expect.equal (through, 2)
        Expect.equal (held.n, 2)
        Expect.equal (held[1], CARRIED)
        Expect.equal (held[2], ALSO)
    end),

    --[[
        A listener that fans the same list, which is the depth counter's real subject. The inner fan
        walks what the outer one is walking, and neither of them compacts, so a link dropped
        anywhere in the pair is out of the array only once both have finished.
    ]]
    Harness.case ("listeners.nested-fan", function ()
        local of = list ()
        local seen: { string } = {}

        local later: Listeners.Link<...any>
        local again = false

        Listeners.connect (of, function ()
            table.insert (seen, "outer")
            if again then return end

            again = true
            later:disconnect ()
            Listeners.fan (of)

            Expect.equal (#of.links, 2)
        end)
        later = Listeners.connect (of, noting (seen, "later"))

        Listeners.fan (of)

        Expect.equal (table.concat (seen, " "), "outer outer")
        Expect.equal (#of.links, 1)
        Expect.equal (of.live, 1)
    end),
}
