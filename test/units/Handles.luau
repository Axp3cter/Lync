--!strict
--!optimize 2
-- A handle before and after its namespace opens: what it was asked to do waits, and a listener
-- attached early ends the same way as one attached late.

local Handles = require("@src/runtime/Handles")
local Types = require("@src/Types")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local DEF = table.freeze({ id = 3, name = "Jump" })
local SESSION = table.freeze({ label = "session" })

-- A connection that remembers whether it was ended.
local function connection(): (Types.Connection, { ended: boolean })
    local state = { ended = false }
    local held = {
        connected = true,
        disconnect = function(self: any)
            self.connected = false
            state.ended = true
        end,
    }
    return held :: any, state
end

return {
    -- Work asked for before the namespace opens runs when it does, in order, with the binding
    -- already written, and work asked for after runs at once.
    Harness.case("handles.waiting", function()
        local of = Handles.live()
        Expect.equal(of.session, nil)
        local ran: { any } = {}
        Handles.waiting(of, function(session: any)
            table.insert(ran, { session, of.id })
        end)
        Handles.waiting(of, function()
            table.insert(ran, "second")
        end)
        Expect.equal(#ran, 0)

        Handles.opened(of, DEF, SESSION, true)
        Expect.equal(ran, { { SESSION, 3 }, "second" })
        Expect.equal({ of.id, of.def, of.session, of.isServer }, { 3, DEF, SESSION, true })
        Expect.equal(#of.waiting, 0)

        Handles.waiting(of, function()
            table.insert(ran, "now")
        end)
        Expect.equal(ran[3], "now")
    end),

    -- A listener attached early binds when the namespace opens unless it was ended first, and
    -- ending it after binding ends the real connection.
    Harness.case("handles.later", function()
        local of = Handles.live()
        local bound = 0
        local real, state = connection()
        local function bind(session: any): Types.Connection
            Expect.equal(session, SESSION)
            bound += 1
            return real
        end

        local early = Handles.later(of, bind)
        local ended = Handles.later(of, bind)
        ended:disconnect()
        Expect.equal(early.connected, true)
        Expect.equal(bound, 0)

        Handles.opened(of, DEF, SESSION, false)
        Expect.equal(bound, 1)
        Expect.equal(state.ended, false)
        early:disconnect()
        Expect.equal(early.connected, false)
        Expect.equal(state.ended, true)

        local late = Handles.later(of, bind)
        Expect.equal(bound, 2)
        Expect.equal(late, real)

        -- A bind that attached nothing hands back a connection already over, and an early
        -- connection follows it once the namespace opens.
        local none = Handles.live()
        local unattached = Handles.later(none, function(): Types.Connection
            return { connected = false, disconnect = function() end } :: any
        end)
        Expect.equal(unattached.connected, true)
        Handles.opened(none, DEF, SESSION, false)
        Expect.equal(unattached.connected, false)
    end),
}
