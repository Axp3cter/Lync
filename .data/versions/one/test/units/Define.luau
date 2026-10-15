--!strict
--!optimize 2
-- A namespace declared: the handles it names, what it refuses, and what a handle may reach.

local Define = require("@src/api/Define")
local Handles = require("@src/runtime/Handles")
local Lifecycle = require("@src/api/Lifecycle")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

-- A stand-in handle: the one field define reads off a packet, a query or a set.
local function handle(): any
    return { live = Handles.live() }
end

return {
    -- A namespace names every handle under it, hands the same table back frozen, keeps the order
    -- declared, and refuses a second declaration of the name, an empty name, a name the descriptor
    -- cannot spell, a value that is no handle, and a handle already named elsewhere.
    Harness.case("define.names", function()
        local jump, look = handle(), handle()
        local defs = { Jump = jump, Look = look }
        local got = Define.define("Arena", defs)
        Expect.holds(got == defs, "define handed back another table")
        Expect.equal(table.isfrozen(got), true)
        Expect.equal({ jump.live.space, jump.live.name }, { "Arena", "Jump" })
        Expect.equal({ look.live.space, look.live.name }, { "Arena", "Look" })
        Expect.equal(Define.spaces.Arena.names, { "Jump", "Look" })
        Expect.equal(Define.order[#Define.order], "Arena")

        local frozen: any = table.freeze({ Only = handle() })
        Expect.holds(Define.define("Lobby", frozen) == frozen, "a frozen table was replaced")

        Expect.throws(function()
            Define.define("Arena", { Again = handle() })
        end, "already been defined")
        Expect.throws(function()
            Define.define("", { Again = handle() })
        end, "no name")
        Expect.throws(function()
            Define.define("a;b", { Again = handle() })
        end, "a;b holds")
        Expect.throws(function()
            Define.define("Bad", { Again = 5 } :: any)
        end, "Bad.Again is not a packet")
        Expect.throws(function()
            Define.define("Twice", { Jump = jump })
        end, "already named in Arena")
    end),

    -- What a handle may reach: nothing before it is named or before its namespace starts, and
    -- once bound, nothing after close or from the other machine.
    Harness.case("define.reach", function()
        local of = handle()
        Expect.throws(function()
            Define.reach(of.live, "fire", true)
        end, "before it was named")
        Expect.equal(Define.naming(of.live, "fire"), "fire")
        Define.declaring(of.live, "validate")

        Define.define("Reach", { Fire = of })
        Expect.equal(Define.naming(of.live, "fire"), "Reach.Fire")
        Expect.throws(function()
            Define.reach(of.live, "fire", true)
        end, "before Reach was started")

        local session: any = { closed = false }
        Handles.opened(of.live, { id = 0 }, session, true)
        Expect.holds(Define.reach(of.live, "fire", true) == session, "the session was not reached")
        Expect.throws(function()
            Define.reach(of.live, "fire", false)
        end, "is a client's call, and this is the server")
        Expect.throws(function()
            Define.declaring(of.live, "validate")
        end, "after Reach started")
        session.closed = true
        Expect.throws(function()
            Define.reach(of.live, "fire", true)
        end, "after Reach was closed")
    end),

    -- Nothing is open before the place starts.
    Harness.case("define.lifecycle-before-start", function()
        Expect.throws(function()
            Lifecycle.flush()
        end, "flush before start")
        Expect.throws(function()
            Lifecycle.close()
        end, "close before start")
    end),
}
