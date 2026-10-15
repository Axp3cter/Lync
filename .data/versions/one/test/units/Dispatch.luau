--!strict
--!optimize 2
-- Where a decoded definition goes: every listener in order, one responder, and the warning for a
-- packet nobody listens for.

local Dispatch = require("@src/runtime/Dispatch")
local Log = require("@src/kernel/Log")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local ID = 4
local NAME = "Jump"

local function warnings(call: () -> (), kind: string?): { string }
    local said: { string } = {}
    local link = Log.onLog(function(heard, message)
        if heard == (kind or "warn") then table.insert(said, message) end
    end)
    call()
    link:disconnect()
    return said
end

return {
    -- Listeners hear a packet in the order attached, a disconnected one hears nothing more, and a
    -- batch reaches each listener one payload at a time.
    Harness.case("dispatch.listens", function()
        local of = Dispatch.wiring()
        local heard: { string } = {}
        local first = Dispatch.listen(of, ID, function(value: any, who: any)
            table.insert(heard, `first {value} {who}`)
        end)
        Dispatch.listen(of, ID, function(value: any)
            table.insert(heard, `second {value}`)
        end)
        Dispatch.packet(of, ID, NAME, 1, "alice")
        Expect.equal(heard, { "first 1 alice", "second 1" })

        first:disconnect()
        table.clear(heard)
        Dispatch.packets(of, ID, NAME, 2, { 7, 8 }, "bob")
        Expect.equal(heard, { "second 7", "second 8" })
    end),

    -- A packet nobody listens for is a warning naming the definition, and a listener that raises
    -- neither stops the others nor the caller.
    Harness.case("dispatch.unheard-and-faults", function()
        local of = Dispatch.wiring()
        local said = warnings(function()
            Dispatch.packet(of, ID, NAME, 1)
        end)
        Expect.equal(#said, 1)
        Expect.holds(string.find(said[1], NAME, 1, true) ~= nil, `it said {said[1]}`)

        local heard = 0
        Dispatch.listen(of, ID, function()
            error("a listener's own mistake")
        end)
        Dispatch.listen(of, ID, function()
            heard += 1
        end)
        local raised = warnings(function()
            Dispatch.packet(of, ID, NAME, 1)
        end, "error")
        Expect.equal(heard, 1)
        Expect.holds(#raised >= 1, "a listener's raise was not reported")
    end),

    -- A query gets one responder, a second is refused, and a request without one answers nothing.
    -- Every answer comes through the callback, at once for a responder that does not yield.
    Harness.case("dispatch.responds", function()
        local of = Dispatch.wiring()
        local came: { any } = {}
        local function done(ok: boolean, value: any)
            table.insert(came, { ok, value })
        end
        Dispatch.request(of, ID, done, 5)
        Expect.equal(came, { { false, nil } })
        Dispatch.respond(of, ID, NAME, function(value: number, who: any)
            return value * 2, who
        end)
        Dispatch.request(of, ID, done, 5, "alice")
        Expect.equal(came[2], { true, 10 })
        Expect.throws(function()
            Dispatch.respond(of, ID, NAME, function(): any
                return nil
            end)
        end, "already has a responder")

        Dispatch.respond(of, ID + 1, "Ask", function(): any
            return error("a responder's own mistake")
        end)
        Dispatch.request(of, ID + 1, done)
        Expect.equal(came[3], { false, nil })
    end),

    -- A responder that yields answers when it returns, and a request read after it is not held
    -- behind it.
    Harness.case("dispatch.responder-yields", function()
        local of = Dispatch.wiring()
        local order: { string } = {}
        Dispatch.respond(of, ID, NAME, function(value: number)
            task.wait(0.02)
            return value * 2
        end)
        Dispatch.respond(of, ID + 1, "Quick", function(value: number)
            return value + 1
        end)
        Dispatch.request(of, ID, function(ok: boolean, value: any)
            table.insert(order, `slow {tostring(ok)} {tostring(value)}`)
        end, 5)
        Dispatch.request(of, ID + 1, function(ok: boolean, value: any)
            table.insert(order, `quick {tostring(ok)} {tostring(value)}`)
        end, 5)
        Expect.equal(order, { "quick true 6" })
        task.wait(0.05)
        Expect.equal(order, { "quick true 6", "slow true 10" })
    end),
}
