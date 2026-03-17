--!strict
--!optimize 2
local Middleware = require (script.Parent.Parent.Parent.internal.Middleware)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe ("Middleware passthrough", function (): ()
    it ("send unchanged", function (): ()
        expect (Middleware.runSend (42, "t", nil)):toBe (42)
    end)
    it ("receive unchanged", function (): ()
        expect (Middleware.runReceive ("hi", "t", nil)):toBe ("hi")
    end)
end)

describe ("Middleware send chain", function (): ()
    it ("transforms in order", function (): ()
        local r1 = Middleware.addSend (function (d: any): any
            return d * 2
        end)
        local r2 = Middleware.addSend (function (d: any): any
            return d + 1
        end)
        expect (Middleware.runSend (5, "t", nil)):toBe (11)
        r1 ()
        r2 ()
    end)
    it ("nil short-circuits", function (): ()
        local r1 = Middleware.addSend (function (): any
            return nil
        end)
        local r2 = Middleware.addSend (function (d: any): any
            return d * 100
        end)
        expect (Middleware.runSend (5, "t", nil)):toBeNil ()
        r1 ()
        r2 ()
    end)
end)

describe ("Middleware removal", function (): ()
    it ("disconnects", function (): ()
        local rm = Middleware.addSend (function (d: any): any
            return d * 10
        end)
        expect (Middleware.runSend (5, "t", nil)):toBe (50)
        rm ()
        expect (Middleware.runSend (5, "t", nil)):toBe (5)
    end)
    it ("double remove safe", function (): ()
        local rm = Middleware.addSend (function (d: any): any
            return d
        end)
        rm ()
        rm ()
    end)
end)

describe ("Middleware flags", function (): ()
    it ("hasSend true after add", function (): ()
        local r = Middleware.addSend (function (d: any): any
            return d
        end)
        expect (Middleware.hasSend):toBe (true)
        r ()
    end)
    it ("hasSend false after remove", function (): ()
        local r = Middleware.addSend (function (d: any): any
            return d
        end)
        r ()
        expect (Middleware.hasSend):toBe (false)
    end)
    it ("hasReceive true after add", function (): ()
        local r = Middleware.addReceive (function (d: any): any
            return d
        end)
        expect (Middleware.hasReceive):toBe (true)
        r ()
    end)
end)

return nil
