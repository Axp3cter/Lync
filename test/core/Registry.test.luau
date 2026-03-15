--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Registry = require (script.Parent.Parent.Parent.core.Registry)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe ("Registry.register", function (): ()
    it ("incrementing IDs", function (): ()
        local s = { connect = function () end }
        local a = Registry.register ("__r_a", Lync.u8, false, s, nil, nil)
        local b = Registry.register ("__r_b", Lync.u8, false, s, nil, nil)
        expect (b.id > a.id):toBe (true)
    end)
    it ("stores name", function (): ()
        local s = { connect = function () end }
        expect (Registry.register ("__r_n", Lync.u16, false, s, nil, nil).name):toBe ("__r_n")
    end)
    it ("stores baseName", function (): ()
        local s = { connect = function () end }
        expect (Registry.register ("__r_bn", Lync.u8, false, s, nil, nil).baseName):toBe ("__r_bn")
    end)
    it ("stores isUnreliable", function (): ()
        local s = { connect = function () end }
        expect (Registry.register ("__r_ur", Lync.u8, true, s, nil, nil).isUnreliable):toBe (true)
    end)
    it ("stores KIND_PACKET", function (): ()
        local s = { connect = function () end }
        expect (Registry.register ("__r_kp", Lync.u8, false, s, nil, nil).kind):toBe (
            Registry.KIND_PACKET
        )
    end)
    it ("stores codec", function (): ()
        local s = { connect = function () end }
        expect (Registry.register ("__r_co", Lync.u8, false, s, nil, nil).codec):toBe (Lync.u8)
    end)
    it ("stores signal", function (): ()
        local s = { connect = function () end }
        expect (Registry.register ("__r_si", Lync.u8, false, s, nil, nil).signal):toBe (s)
    end)
    it ("stores rateLimit", function (): ()
        local s = { connect = function () end }
        local rl = { maxPerSecond = 10 }
        expect (Registry.register ("__r_rl", Lync.u8, false, s, rl, nil).rateLimit):toBe (rl)
    end)
    it ("stores validate", function (): ()
        local s = { connect = function () end }
        local v = function ()
            return true
        end
        expect (Registry.register ("__r_vl", Lync.u8, false, s, nil, v).validate):toBe (v)
    end)
end)

describe ("Registry KIND constants", function (): ()
    it ("PACKET = 0", function (): ()
        expect (Registry.KIND_PACKET):toBe (0)
    end)
    it ("REQUEST = 1", function (): ()
        expect (Registry.KIND_REQUEST):toBe (1)
    end)
    it ("RESPONSE = 2", function (): ()
        expect (Registry.KIND_RESPONSE):toBe (2)
    end)
end)

describe ("Registry.get / getByName", function (): ()
    it ("by ID", function (): ()
        local s = { connect = function () end }
        local r = Registry.register ("__r_gi", Lync.u8, false, s, nil, nil)
        expect ((Registry.get (r.id) :: any).name):toBe ("__r_gi")
    end)
    it ("by name", function (): ()
        local s = { connect = function () end }
        Registry.register ("__r_gn", Lync.u8, false, s, nil, nil)
        expect (Registry.getByName ("__r_gn")).never:toBeNil ()
    end)
    it ("nil for bad ID", function (): ()
        expect (Registry.get (99999)):toBeNil ()
    end)
    it ("nil for bad name", function (): ()
        expect (Registry.getByName ("__nope")):toBeNil ()
    end)
end)

describe ("Registry.registerQueryPair", function (): ()
    it ("linked kinds", function (): ()
        local sa, sb = { connect = function () end }, { connect = function () end }
        local req, resp = Registry.registerQueryPair ("__r_qp", Lync.u8, Lync.u16, sa, sb)
        expect (req.kind):toBe (Registry.KIND_REQUEST)
        expect (resp.kind):toBe (Registry.KIND_RESPONSE)
    end)
    it ("linked partners", function (): ()
        local sa, sb = { connect = function () end }, { connect = function () end }
        local req, resp = Registry.registerQueryPair ("__r_qp2", Lync.u8, Lync.u16, sa, sb)
        expect (req.partner):toBe (resp.id)
        expect (resp.partner):toBe (req.id)
    end)
    it ("names suffixed", function (): ()
        local sa, sb = { connect = function () end }, { connect = function () end }
        local req, resp = Registry.registerQueryPair ("__r_qp3", Lync.u8, Lync.u16, sa, sb)
        expect (req.name):toBe ("__r_qp3:req")
        expect (resp.name):toBe ("__r_qp3:resp")
    end)
    it ("baseName shared", function (): ()
        local sa, sb = { connect = function () end }, { connect = function () end }
        local req, resp = Registry.registerQueryPair ("__r_qp4", Lync.u8, Lync.u16, sa, sb)
        expect (req.baseName):toBe ("__r_qp4")
        expect (resp.baseName):toBe ("__r_qp4")
    end)
    it ("always reliable", function (): ()
        local sa, sb = { connect = function () end }, { connect = function () end }
        local req, resp = Registry.registerQueryPair ("__r_qp5", Lync.u8, Lync.u16, sa, sb)
        expect (req.isUnreliable):toBe (false)
        expect (resp.isUnreliable):toBe (false)
    end)
end)

describe ("Registry validation", function (): ()
    it ("throws duplicate", function (): ()
        local s = { connect = function () end }
        Registry.register ("__r_dup", Lync.u8, false, s, nil, nil)
        expect (function (): ()
            Registry.register ("__r_dup", Lync.u8, false, s, nil, nil)
        end):toThrow ("Duplicate registration")
    end)
    it ("throws bad maxPerSecond", function (): ()
        expect (function (): ()
            local s = { connect = function () end }
            Registry.register ("__r_br", Lync.u8, false, s, { maxPerSecond = 0 }, nil)
        end):toThrow ("maxPerSecond must be positive")
    end)
    it ("throws bad burstAllowance", function (): ()
        expect (function (): ()
            local s = { connect = function () end }
            Registry.register (
                "__r_bb",
                Lync.u8,
                false,
                s,
                { maxPerSecond = 10, burstAllowance = 0 },
                nil
            )
        end):toThrow ("burstAllowance must be positive")
    end)
    it ("throws negative maxPerSecond", function (): ()
        expect (function (): ()
            local s = { connect = function () end }
            Registry.register ("__r_br2", Lync.u8, false, s, { maxPerSecond = -1 }, nil)
        end):toThrow ("maxPerSecond must be positive")
    end)
    it ("IDs fit in u8 range", function (): ()
        local s = { connect = function () end }
        local reg = Registry.register ("__r_u8check", Lync.u8, false, s, nil, nil)
        expect (reg.id >= 1):toBe (true)
        expect (reg.id <= 255):toBe (true)
    end)
end)

return nil
