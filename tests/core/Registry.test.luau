--!strict
--!optimize 2
-- Registry.test.luau — Registration, lookup, and query pair tests.

local Lync = require (script.Parent.Parent.Parent)
local Registry = require (script.Parent.Parent.Parent.core.Registry)
local Runner = require (script.Parent.Parent.Runner)

local describe = Runner.describe
local it = Runner.it
local expect = Runner.expect

-- Tests ------------------------------------------------------------------

describe ("Registry.register", function (): ()
    it ("assigns incrementing IDs", function (): ()
        local signal = { connect = function () end }
        local regA = Registry.register ("__test_regA", Lync.u8, "reliable", signal, nil, nil)
        local regB = Registry.register ("__test_regB", Lync.u8, "reliable", signal, nil, nil)
        expect (regB.id > regA.id):toBe (true)
    end)
    it ("stores name and baseName", function (): ()
        local signal = { connect = function () end }
        local reg = Registry.register ("__test_named", Lync.u16, "unreliable", signal, nil, nil)
        expect (reg.name):toBe ("__test_named")
        expect (reg.baseName):toBe ("__test_named")
        expect (reg.reliability):toBe ("unreliable")
        expect (reg.kind):toBe ("packet")
    end)
end)

describe ("Registry.get / getByName", function (): ()
    it ("retrieves by ID", function (): ()
        local signal = { connect = function () end }
        local reg = Registry.register ("__test_byId", Lync.u8, "reliable", signal, nil, nil)
        local found = Registry.get (reg.id)
        expect (found).never:toBeNil ()
        expect ((found :: any).name):toBe ("__test_byId")
    end)
    it ("retrieves by name", function (): ()
        local signal = { connect = function () end }
        Registry.register ("__test_byName", Lync.u8, "reliable", signal, nil, nil)
        local found = Registry.getByName ("__test_byName")
        expect (found).never:toBeNil ()
    end)
    it ("returns nil for unknown ID", function (): ()
        expect (Registry.get (99999)):toBeNil ()
    end)
    it ("returns nil for unknown name", function (): ()
        expect (Registry.getByName ("__nonexistent")):toBeNil ()
    end)
end)

describe ("Registry.registerQueryPair", function (): ()
    it ("creates linked request and response entries", function (): ()
        local sigReq = { connect = function () end }
        local sigResp = { connect = function () end }
        local req, resp =
            Registry.registerQueryPair ("__test_query", Lync.u8, Lync.u16, sigReq, sigResp)
        expect (req.kind):toBe ("request")
        expect (resp.kind):toBe ("response")
        expect (req.partner):toBe (resp.id)
        expect (resp.partner):toBe (req.id)
        expect (req.name):toBe ("__test_query:req")
        expect (resp.name):toBe ("__test_query:resp")
        expect (req.baseName):toBe ("__test_query")
    end)
end)

describe ("Registry validation", function (): ()
    it ("throws on duplicate name", function (): ()
        local signal = { connect = function () end }
        Registry.register ("__test_dup", Lync.u8, "reliable", signal, nil, nil)
        expect (function (): ()
            Registry.register ("__test_dup", Lync.u8, "reliable", signal, nil, nil)
        end):toThrow ("Already registered")
    end)
    it ("throws on invalid reliability", function (): ()
        expect (function (): ()
            local signal = { connect = function () end }
            Registry.register ("__test_badRel", Lync.u8, "maybe", signal, nil, nil)
        end):toThrow ("Invalid reliability")
    end)
    it ("throws on non-positive rateLimit.maxPerSecond", function (): ()
        expect (function (): ()
            local signal = { connect = function () end }
            Registry.register ("__test_badRate", Lync.u8, "reliable", signal, {
                maxPerSecond = 0,
            }, nil)
        end):toThrow ("maxPerSecond must be positive")
    end)
end)

return nil
