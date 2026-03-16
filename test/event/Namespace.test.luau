--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Middleware = require (script.Parent.Parent.Parent.core.Middleware)
local Namespace = require (script.Parent.Parent.Parent.event.Namespace)
local Registry = require (script.Parent.Parent.Parent.core.Registry)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe ("Namespace.define basics", function (): ()
    it ("creates with packets", function (): ()
        local ns = Namespace.define ("__ns_basic", {
            packets = {
                Ping = { value = Lync.bool },
            },
        })
        expect (ns).never:toBeNil ()
        expect (ns.Ping).never:toBeNil ()
    end)
    it ("creates with queries", function (): ()
        local ns = Namespace.define ("__ns_query", {
            packets = {},
            queries = {
                Ask = {
                    request = Lync.u8,
                    response = Lync.u8,
                },
            },
        })
        expect (ns).never:toBeNil ()
        expect (ns.Ask).never:toBeNil ()
    end)
    it ("creates empty", function (): ()
        expect (function (): ()
            Namespace.define ("__ns_empty", {})
        end).never:toThrow ()
    end)
    it ("prefixes packet names in registry", function (): ()
        Namespace.define ("__ns_prefix", {
            packets = {
                Hit = { value = Lync.u8 },
            },
        })
        expect (Registry.getByName ("__ns_prefix.Hit")).never:toBeNil ()
    end)
    it ("prefixes query names in registry", function (): ()
        Namespace.define ("__ns_qprefix", {
            queries = {
                Fetch = {
                    request = Lync.u8,
                    response = Lync.u16,
                },
            },
        })
        expect (Registry.getByName ("__ns_qprefix.Fetch:req")).never:toBeNil ()
        expect (Registry.getByName ("__ns_qprefix.Fetch:resp")).never:toBeNil ()
    end)
end)

describe ("Namespace.define validation", function (): ()
    it ("throws empty name", function (): ()
        expect (function (): ()
            Namespace.define ("", {})
        end):toThrow ("must not be empty")
    end)
    it ("throws duplicate", function (): ()
        Namespace.define ("__ns_dup", {})
        expect (function (): ()
            Namespace.define ("__ns_dup", {})
        end):toThrow ("Duplicate namespace")
    end)
end)

describe ("Namespace.packetNames / queryNames", function (): ()
    it ("returns sorted short names", function (): ()
        local ns = Namespace.define ("__ns_names", {
            packets = {
                Zulu = { value = Lync.bool },
                Alpha = { value = Lync.u8 },
            },
        })
        local names = ns:packetNames ()
        expect (names[1]):toBe ("Alpha")
        expect (names[2]):toBe ("Zulu")
    end)
    it ("query names returned", function (): ()
        local ns = Namespace.define ("__ns_qnames", {
            queries = {
                Beta = {
                    request = Lync.u8,
                    response = Lync.u8,
                },
            },
        })
        local names = ns:queryNames ()
        expect (names[1]):toBe ("Beta")
    end)
end)

describe ("Namespace.onSend scoped middleware", function (): ()
    it ("only fires for namespace packets", function (): ()
        local ns = Namespace.define ("__ns_mw_send", {
            packets = {
                Msg = { value = Lync.u8 },
            },
        })
        local fired = false
        local remover = ns:onSend (function (data: any, name: string): any?
            fired = true
            return data
        end)

        -- Packet outside namespace should not trigger
        Middleware.runSend (42, "OtherPacket", nil)
        expect (fired):toBe (false)

        -- Packet inside namespace should trigger
        Middleware.runSend (42, "__ns_mw_send.Msg", nil)
        expect (fired):toBe (true)

        remover ()
    end)
    it ("passthrough for non-matching", function (): ()
        local ns = Namespace.define ("__ns_mw_pass", {
            packets = {
                X = { value = Lync.u8 },
            },
        })
        local remover = ns:onSend (function (): any?
            return nil
        end)

        -- Non-matching packet should get its data back unchanged
        local result = Middleware.runSend (99, "SomeOther", nil)
        expect (result):toBe (99)

        remover ()
    end)
    it ("transforms matching packets", function (): ()
        local ns = Namespace.define ("__ns_mw_xform", {
            packets = {
                Val = { value = Lync.u8 },
            },
        })
        local remover = ns:onSend (function (data: any): any?
            return (data :: number) + 100
        end)

        local result = Middleware.runSend (5, "__ns_mw_xform.Val", nil)
        expect (result):toBe (105)

        remover ()
    end)
    it ("nil drops matching packets", function (): ()
        local ns = Namespace.define ("__ns_mw_drop", {
            packets = {
                Drop = { value = Lync.u8 },
            },
        })
        local remover = ns:onSend (function (): any?
            return nil
        end)

        local result = Middleware.runSend (42, "__ns_mw_drop.Drop", nil)
        expect (result):toBeNil ()

        remover ()
    end)
end)

describe ("Namespace.onReceive scoped middleware", function (): ()
    it ("only fires for namespace packets", function (): ()
        local ns = Namespace.define ("__ns_mw_recv", {
            packets = {
                In = { value = Lync.u8 },
            },
        })
        local count = 0
        local remover = ns:onReceive (function (data: any): any?
            count += 1
            return data
        end)

        Middleware.runReceive (1, "OtherPacket", nil)
        expect (count):toBe (0)

        Middleware.runReceive (1, "__ns_mw_recv.In", nil)
        expect (count):toBe (1)

        remover ()
    end)
end)

describe ("Namespace.disconnectAll", function (): ()
    it ("does not throw on empty", function (): ()
        local ns = Namespace.define ("__ns_dc_empty", {
            packets = {
                A = { value = Lync.bool },
            },
        })
        expect (function (): ()
            ns:disconnectAll ()
        end).never:toThrow ()
    end)
end)

describe ("Namespace.destroy", function (): ()
    it ("removes scoped middleware", function (): ()
        local ns = Namespace.define ("__ns_destroy", {
            packets = {
                Pkt = { value = Lync.u8 },
            },
        })
        local count = 0
        ns:onSend (function (data: any): any?
            count += 1
            return data
        end)

        Middleware.runSend (1, "__ns_destroy.Pkt", nil)
        expect (count):toBe (1)

        ns:destroy ()

        Middleware.runSend (1, "__ns_destroy.Pkt", nil)
        expect (count):toBe (1)
    end)
end)

describe ("Namespace multiple packets", function (): ()
    it ("creates 3 packets under one namespace", function (): ()
        local ns = Namespace.define ("__ns_multi", {
            packets = {
                A = { value = Lync.u8 },
                B = { value = Lync.u16 },
                C = { value = Lync.bool },
            },
        })
        expect (ns.A).never:toBeNil ()
        expect (ns.B).never:toBeNil ()
        expect (ns.C).never:toBeNil ()

        expect (Registry.getByName ("__ns_multi.A")).never:toBeNil ()
        expect (Registry.getByName ("__ns_multi.B")).never:toBeNil ()
        expect (Registry.getByName ("__ns_multi.C")).never:toBeNil ()
    end)
end)

describe ("Namespace isolation", function (): ()
    it ("two namespaces do not collide", function (): ()
        local nsA = Namespace.define ("__ns_isoA", {
            packets = { Hit = { value = Lync.u8 } },
        })
        local nsB = Namespace.define ("__ns_isoB", {
            packets = { Hit = { value = Lync.u16 } },
        })

        expect (nsA.Hit).never:toBe (nsB.Hit)
        expect (Registry.getByName ("__ns_isoA.Hit")).never:toBeNil ()
        expect (Registry.getByName ("__ns_isoB.Hit")).never:toBeNil ()
    end)
    it ("scoped middleware does not leak across namespaces", function (): ()
        local nsA = Namespace.define ("__ns_leakA", {
            packets = { Msg = { value = Lync.u8 } },
        })
        local nsB = Namespace.define ("__ns_leakB", {
            packets = { Msg = { value = Lync.u8 } },
        })

        local aCount = 0
        local removerA = nsA:onSend (function (data: any): any?
            aCount += 1
            return data
        end)

        Middleware.runSend (1, "__ns_leakB.Msg", nil)
        expect (aCount):toBe (0)

        Middleware.runSend (1, "__ns_leakA.Msg", nil)
        expect (aCount):toBe (1)

        removerA ()
    end)
end)

return nil
