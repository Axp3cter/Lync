--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe ("Query.define validation", function (): ()
    it ("throws missing request codec", function (): ()
        expect (function (): ()
            Lync.defineQuery ("__q_noreq", { response = Lync.u8 } :: any)
        end):toThrow ("requires a request")
    end)
    it ("throws missing response codec", function (): ()
        expect (function (): ()
            Lync.defineQuery ("__q_noresp", { request = Lync.u8 } :: any)
        end):toThrow ("requires a response")
    end)
    it ("throws duplicate name", function (): ()
        Lync.defineQuery ("__q_dup", { request = Lync.u8, response = Lync.u8 })
        expect (function (): ()
            Lync.defineQuery ("__q_dup", { request = Lync.u8, response = Lync.u8 })
        end):toThrow ("Duplicate")
    end)
end)

describe ("Query.define returns object", function (): ()
    local q = Lync.defineQuery ("__q_obj", { request = Lync.u8, response = Lync.string })

    it ("has listen", function (): ()
        expect (typeof ((q :: any).listen)):toBe ("function")
    end)
    it ("has request", function (): ()
        expect (typeof ((q :: any).request)):toBe ("function")
    end)
    it ("has requestFrom", function (): ()
        expect (typeof ((q :: any).requestFrom)):toBe ("function")
    end)
    it ("has requestAll", function (): ()
        expect (typeof ((q :: any).requestAll)):toBe ("function")
    end)
    it ("has requestList", function (): ()
        expect (typeof ((q :: any).requestList)):toBe ("function")
    end)
    it ("has requestGroup", function (): ()
        expect (typeof ((q :: any).requestGroup)):toBe ("function")
    end)
end)

describe ("Query.define with options", function (): ()
    it ("timeout", function (): ()
        local q = Lync.defineQuery ("__q_timeout", {
            request = Lync.u8,
            response = Lync.u8,
            timeout = 5,
        })
        expect (q):toBeTruthy ()
    end)
    it ("rateLimit", function (): ()
        local q = Lync.defineQuery ("__q_rate", {
            request = Lync.u8,
            response = Lync.u8,
            rateLimit = { maxPerSecond = 10 },
        })
        expect (q):toBeTruthy ()
    end)
end)

describe ("queryPendingCount", function (): ()
    it ("zero initially", function (): ()
        expect (Lync.queryPendingCount ()):toBe (0)
    end)
end)

return nil
