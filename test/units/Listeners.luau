--!strict
--!optimize 2
-- What a fan reaches while it is walking, and what the list holds once it has finished.

local Listeners = require("@src/kernel/Listeners")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local CARRIED = 7
local ALSO = "beat"

-- Rounds a churn case attaches and drops over, far more than any list would hold at once.
local CHURN = 64

type List = Listeners.List<...any>

-- A list reached by a plain call.
local function list(): List
    return Listeners.list(function(fn: (...any) -> (), ...: any)
        fn(...)
    end)
end

-- A listener that writes its own name down when reached.
local function noting(into: { string }, name: string): (...any) -> ()
    return function()
        table.insert(into, name)
    end
end

-- Every listener a fan reached, in order.
local function reached(of: List, into: { string }): string
    table.clear(into)
    Listeners.fan(of)
    return table.concat(into, " ")
end

return {
    Harness.case("listeners.empty", function()
        local of = list()
        Expect.equal(of.live, 0)
        Expect.equal(#of.links, 0)
        Expect.equal(reached(of, {}), "")
    end),

    Harness.case("listeners.order", function()
        local of = list()
        local seen: { string } = {}
        for _, name in { "first", "second", "third" } do
            Listeners.connect(of, noting(seen, name))
        end
        Expect.equal(of.live, 3)
        Expect.equal(reached(of, seen), "first second third")
    end),

    -- The connection a registration hands back is the link itself.
    Harness.case("listeners.connection-is-the-link", function()
        local of = list()
        local seen: { string } = {}
        local link = Listeners.connect(of, noting(seen, "one"))

        Expect.equal(link.connected, true)
        Expect.equal(typeof(link.disconnect), "function")
        Expect.equal(of.links[1], link)

        link:disconnect()
        Expect.equal(link.connected, false)
        Expect.equal(of.live, 0)
        Expect.equal(reached(of, seen), "")
    end),

    Harness.case("listeners.disconnect-twice", function()
        local of = list()
        local seen: { string } = {}
        local one = Listeners.connect(of, noting(seen, "one"))
        Listeners.connect(of, noting(seen, "two"))

        one:disconnect()
        one:disconnect()
        one:disconnect()
        Expect.equal(of.live, 1)
        Expect.equal(reached(of, seen), "two")
    end),

    -- The length is taken once at the start, so what a fan delivers to is fixed when it begins.
    Harness.case("listeners.attached-during-a-fan", function()
        local of = list()
        local seen: { string } = {}
        local once = false
        Listeners.connect(of, function()
            table.insert(seen, "first")
            if once then return end
            once = true
            Listeners.connect(of, noting(seen, "late"))
        end)
        Listeners.connect(of, noting(seen, "second"))

        Listeners.fan(of)
        Expect.equal(table.concat(seen, " "), "first second")
        Expect.equal(reached(of, seen), "first second late")
    end),

    -- The connected flag is read at the link, so a drop one listener performs is respected now.
    Harness.case("listeners.dropped-ahead-during-a-fan", function()
        local of = list()
        local seen: { string } = {}
        local later: Listeners.Link<...any>
        Listeners.connect(of, function()
            table.insert(seen, "first")
            later:disconnect()
        end)
        later = Listeners.connect(of, noting(seen, "later"))
        Listeners.connect(of, noting(seen, "last"))

        Listeners.fan(of)
        Expect.equal(table.concat(seen, " "), "first last")
        Expect.equal(of.live, 2)
    end),

    Harness.case("listeners.dropped-behind-during-a-fan", function()
        local of = list()
        local seen: { string } = {}
        local early = Listeners.connect(of, noting(seen, "early"))
        Listeners.connect(of, function()
            table.insert(seen, "second")
            early:disconnect()
        end)

        Listeners.fan(of)
        Expect.equal(table.concat(seen, " "), "early second")
        Expect.equal(reached(of, seen), "second")
    end),

    Harness.case("listeners.drops-itself", function()
        local of = list()
        local seen: { string } = {}
        local once: Listeners.Link<...any>
        once = Listeners.connect(of, function()
            table.insert(seen, "once")
            once:disconnect()
        end)
        Listeners.connect(of, noting(seen, "always"))

        Listeners.fan(of)
        Expect.equal(table.concat(seen, " "), "once always")
        Expect.equal(reached(of, seen), "always")
    end),

    -- Nothing is taken out of the array while a fan is walking it.
    Harness.case("listeners.no-sweep-while-fanning", function()
        local of = list()
        local seen: { string } = {}
        local held = 0
        local later: Listeners.Link<...any>
        Listeners.connect(of, function()
            table.insert(seen, "first")
            later:disconnect()
            held = #of.links
        end)
        later = Listeners.connect(of, noting(seen, "later"))
        Listeners.connect(of, noting(seen, "last"))

        Listeners.fan(of)
        Expect.equal(held, 3)
        Expect.equal(#of.links, 2)
        Expect.equal(table.concat(seen, " "), "first last")
    end),

    -- Survivors keep registration order, so delivery order never depends on a list history.
    Harness.case("listeners.sweep-keeps-order", function()
        local of = list()
        local seen: { string } = {}
        local links: { Listeners.Link<...any> } = {}
        for _, name in { "a", "b", "c", "d", "e" } do
            table.insert(links, Listeners.connect(of, noting(seen, name)))
        end

        links[2]:disconnect()
        links[3]:disconnect()
        Expect.equal(#of.links, 3)
        Expect.equal(reached(of, seen), "a d e")
    end),

    Harness.case("listeners.sweep-under-churn", function()
        local of = list()
        local seen: { string } = {}
        Listeners.connect(of, noting(seen, "kept"))
        for _ = 1, CHURN do
            Listeners.connect(of, noting(seen, "passing")):disconnect()
        end
        Expect.equal(of.live, 1)
        Expect.equal(#of.links, 1)
        Expect.equal(reached(of, seen), "kept")
    end),

    -- What a fan owes the runner is the function and whatever it was handed, in that order.
    Harness.case("listeners.runner", function()
        local through = 0
        local of: List = Listeners.list(function(fn: (...any) -> (), ...: any)
            through += 1
            fn(...)
        end)

        local held: { n: number, [number]: any } = { n = 0 }
        Listeners.connect(of, function(...)
            held = table.pack(...)
        end)
        Listeners.connect(of, function() end)

        Listeners.fan(of, CARRIED, ALSO)
        Expect.equal(through, 2)
        Expect.equal(held.n, 2)
        Expect.equal(held[1], CARRIED)
        Expect.equal(held[2], ALSO)
    end),

    -- A batch reaches every live listener once, with the count and the batch's own arguments.
    Harness.case("listeners.batch", function()
        local calls: { { any } } = {}
        local of: List = Listeners.list(function(fn: (...any) -> (), ...: any)
            fn(...)
        end, function(fn: (...any) -> (), count: number, ...: any)
            table.insert(calls, { fn, count, ... })
        end)

        local a = Listeners.connect(of, function() end)
        Listeners.connect(of, function() end)
        a:disconnect()

        Listeners.fanBatch(of, 3, "values", ALSO)
        Expect.equal(#calls, 1)
        Expect.equal(calls[1][2], 3)
        Expect.equal(calls[1][3], "values")
        Expect.equal(calls[1][4], ALSO)

        Listeners.fanBatch(list(), 3, "values")
    end),

    -- A batch fan is a walk like any other: a link dropped from inside it stays in the array
    -- until the walk ends, and the walk leaves the depth where it found it, so the next drop
    -- compacts on the spot.
    Harness.case("listeners.batch-no-sweep-while-fanning", function()
        local of: List = Listeners.list(function(fn: (...any) -> (), ...: any)
            fn(...)
        end, function(fn: (...any) -> (), _count: number, ...: any)
            fn(...)
        end)
        local seen: { string } = {}
        local held = 0
        local later: Listeners.Link<...any>
        Listeners.connect(of, function()
            table.insert(seen, "first")
            later:disconnect()
            held = #of.links
        end)
        later = Listeners.connect(of, noting(seen, "later"))
        Listeners.connect(of, noting(seen, "last"))

        Listeners.fanBatch(of, 1, "values")
        Expect.equal(held, 3)
        Expect.equal(#of.links, 2)
        Expect.equal(of.depth, 0)
        Expect.equal(table.concat(seen, " "), "first last")

        Listeners.connect(of, noting(seen, "passing")):disconnect()
        Expect.equal(#of.links, 2)
    end),

    -- Whether anything listens follows the live count, so a list whose every link disconnected
    -- answers as an empty one does.
    Harness.case("listeners.any", function()
        local of = list()
        Expect.equal(Listeners.any(of), false)
        local only = Listeners.connect(of, function() end)
        Expect.equal(Listeners.any(of), true)
        only:disconnect()
        Expect.equal(Listeners.any(of), false)
        Expect.equal(#of.links, 0)
    end),

    -- A listener that fans the same list, which is the depth counter's real subject.
    Harness.case("listeners.nested-fan", function()
        local of = list()
        local seen: { string } = {}
        local later: Listeners.Link<...any>
        local again = false
        Listeners.connect(of, function()
            table.insert(seen, "outer")
            if again then return end
            again = true
            later:disconnect()
            Listeners.fan(of)
            Expect.equal(#of.links, 2)
        end)
        later = Listeners.connect(of, noting(seen, "later"))

        Listeners.fan(of)
        Expect.equal(table.concat(seen, " "), "outer outer")
        Expect.equal(#of.links, 1)
        Expect.equal(of.live, 1)
    end),
}
