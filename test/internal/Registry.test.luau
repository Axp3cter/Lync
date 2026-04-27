--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Lync = require(script.Parent.Parent.Parent)
local Registry = require(script.Parent.Parent.Parent.internal.Registry)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

-- Private ----------------------------------------------------------------

--[[
    Build a RegisterOptions table for a u8 packet. Caller supplies a
    unique name; everything else gets reasonable defaults so each test
    can call Registry.register(makeOpts("...")).
]]
local function makeOpts(name: string): any
    return {
        name = name,
        kind = Registry.KIND_PACKET,
        codec = Lync.int(0, 255),
        isUnreliable = false,
        partner = nil,
        needsGate = false,
        headerSize = 1,
        timestampMode = Channel.TS_NONE,
        openFn = Channel.resolveOpenFn(Channel.TS_NONE, name),
        rateLimit = nil,
        validate = nil,
        maxPayloadBytes = nil,
    }
end

-- Tests ------------------------------------------------------------------

describe("Registry: sequential IDs", function(): ()
    it("first ID > 0", function(): ()
        local reg = Registry.register(makeOpts("__rseq1"))
        expect(reg.id):toBeGreaterThan(0)
    end)
    it("count increments", function(): ()
        local before = Registry.count()
        Registry.register(makeOpts("__rseq2"))
        expect(Registry.count()):toBe(before + 1)
    end)
    it("IDs are sequential", function(): ()
        local a = Registry.register(makeOpts("__rseq3a"))
        local b = Registry.register(makeOpts("__rseq3b"))
        expect(b.id):toBe(a.id + 1)
    end)
end)

describe("Registry: lookup", function(): ()
    it("get by ID", function(): ()
        local reg = Registry.register(makeOpts("__rget"))
        expect(Registry.get(reg.id)):toBeTruthy()
        expect((Registry.get(reg.id) :: any).name):toBe("__rget")
    end)
    it("getByName", function(): ()
        Registry.register(makeOpts("__rname"))
        expect(Registry.getByName("__rname")):toBeTruthy()
    end)
    it("get unknown ID = nil", function(): ()
        expect(Registry.get(9999)):toBeNil()
    end)
    it("getByName unknown = nil", function(): ()
        expect(Registry.getByName("__nope")):toBeNil()
    end)
end)

describe("Registry: duplicate name errors", function(): ()
    it("throws", function(): ()
        Registry.register(makeOpts("__rdup"))
        expect(function(): ()
            Registry.register(makeOpts("__rdup"))
        end):toThrow("duplicate")
    end)
end)

describe("Registry: all()", function(): ()
    it("returns non-empty list", function(): ()
        expect(#Registry.all()):toBeGreaterThan(0)
    end)
end)

describe("Registry: kind constants", function(): ()
    it("KIND_PACKET = 0", function(): ()
        expect(Registry.KIND_PACKET):toBe(0)
    end)
    it("KIND_REQUEST = 1", function(): ()
        expect(Registry.KIND_REQUEST):toBe(1)
    end)
    it("KIND_RESPONSE = 2", function(): ()
        expect(Registry.KIND_RESPONSE):toBe(2)
    end)
end)

return nil
