--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe ("Packet.define validation", function (): ()
    it ("throws empty name", function (): ()
        expect (function (): ()
            Lync.definePacket ("", { value = Lync.u8 })
        end):toThrow ()
    end)
    it ("throws missing value codec", function (): ()
        expect (function (): ()
            Lync.definePacket ("__pkt_nocodec", {} :: any)
        end):toThrow ("requires a value")
    end)
    it ("throws delta + unreliable", function (): ()
        expect (function (): ()
            Lync.definePacket ("__pkt_deltaunrel", {
                value = Lync.deltaStruct ({ hp = Lync.u8 }),
                unreliable = true,
            })
        end):toThrow ("delta")
    end)
    it ("throws duplicate name", function (): ()
        Lync.definePacket ("__pkt_dup", { value = Lync.u8 })
        expect (function (): ()
            Lync.definePacket ("__pkt_dup", { value = Lync.u8 })
        end):toThrow ("Duplicate")
    end)
end)

describe ("Packet.define returns object", function (): ()
    local pkt = Lync.definePacket ("__pkt_obj", { value = Lync.u8 })

    it ("has listen", function (): ()
        expect (typeof ((pkt :: any).listen)):toBe ("function")
    end)
    it ("has once", function (): ()
        expect (typeof ((pkt :: any).once)):toBe ("function")
    end)
    it ("has wait", function (): ()
        expect (typeof ((pkt :: any).wait)):toBe ("function")
    end)
    it ("has disconnectAll", function (): ()
        expect (typeof ((pkt :: any).disconnectAll)):toBe ("function")
    end)
end)

describe ("Packet server methods", function (): ()
    local RunService = game:GetService ("RunService")
    if not RunService:IsServer () then
        return
    end

    local pkt = Lync.definePacket ("__pkt_srv", { value = Lync.u8 })

    it ("has sendTo", function (): ()
        expect (typeof ((pkt :: any).sendTo)):toBe ("function")
    end)
    it ("has sendToAll", function (): ()
        expect (typeof ((pkt :: any).sendToAll)):toBe ("function")
    end)
    it ("has sendToList", function (): ()
        expect (typeof ((pkt :: any).sendToList)):toBe ("function")
    end)
    it ("has sendToAllExcept", function (): ()
        expect (typeof ((pkt :: any).sendToAllExcept)):toBe ("function")
    end)
    it ("has sendToGroup", function (): ()
        expect (typeof ((pkt :: any).sendToGroup)):toBe ("function")
    end)
end)

describe ("Packet with config options", function (): ()
    it ("unreliable = true", function (): ()
        local pkt = Lync.definePacket ("__pkt_unrel", { value = Lync.u8, unreliable = true })
        expect (pkt):toBeTruthy ()
    end)
    it ("rateLimit", function (): ()
        local pkt = Lync.definePacket ("__pkt_rate", {
            value = Lync.u8,
            rateLimit = { maxPerSecond = 60 },
        })
        expect (pkt):toBeTruthy ()
    end)
    it ("validate", function (): ()
        local pkt = Lync.definePacket ("__pkt_val", {
            value = Lync.u8,
            validate = function (data: any, player: Player): (boolean, string?)
                return data < 100, "too high"
            end,
        })
        expect (pkt):toBeTruthy ()
    end)
    it ("maxPayloadBytes", function (): ()
        local pkt = Lync.definePacket ("__pkt_maxpay", {
            value = Lync.string,
            maxPayloadBytes = 1024,
        })
        expect (pkt):toBeTruthy ()
    end)
end)

return nil
