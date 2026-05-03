--!strict
--!optimize 2
-- internal.Registry: sequential 7-bit ID assignment with KIND constants.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Internal.Channel
local Registry = Env.Internal.Registry
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

local function packetOpts(name: string, kind: number?): any
    return {
        name = name,
        kind = kind or Registry.KIND_PACKET,
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

describe("internal.Registry", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("KIND constants", function(): ()
        it("KIND_PACKET = 0", function(): ()
            expect(Registry.KIND_PACKET):toBe(0)
        end)
        it("KIND_REQUEST = 1", function(): ()
            expect(Registry.KIND_REQUEST):toBe(1)
        end)
        it("KIND_RESPONSE = 2", function(): ()
            expect(Registry.KIND_RESPONSE):toBe(2)
        end)
        it("MAX_ID = 127 (7-bit)", function(): ()
            expect(Registry.MAX_ID):toBe(127)
        end)
    end)

    describe("sequential ID assignment", function(): ()
        it("first registration starts at 1", function(): ()
            local r = Registry.register(packetOpts("first"))
            expect(r.id):toBe(1)
        end)
        it("count increments per registration", function(): ()
            Registry.register(packetOpts("a"))
            Registry.register(packetOpts("b"))
            expect(Registry.count()):toBe(2)
        end)
        it("IDs are sequential", function(): ()
            local a = Registry.register(packetOpts("first"))
            local b = Registry.register(packetOpts("second"))
            local c = Registry.register(packetOpts("third"))
            expect(b.id):toBe(a.id + 1)
            expect(c.id):toBe(b.id + 1)
        end)
    end)

    describe("lookup", function(): ()
        it("get by ID returns Registration", function(): ()
            local r = Registry.register(packetOpts("getid"))
            local found = Registry.get(r.id)
            expect(found):toBeType("table")
            expect((found :: any).name):toBe("getid")
        end)
        it("getByName returns the same Registration", function(): ()
            Registry.register(packetOpts("byname"))
            local found = Registry.getByName("byname")
            expect(found):toBeType("table")
        end)
        it("get unknown ID = nil", function(): ()
            expect(Registry.get(9999)):toBeNil()
        end)
        it("getByName unknown = nil", function(): ()
            expect(Registry.getByName("__nope")):toBeNil()
        end)
    end)

    describe("duplicate name on KIND_PACKET throws", function(): ()
        it("second register throws", function(): ()
            Registry.register(packetOpts("dup"))
            expect(function(): ()
                Registry.register(packetOpts("dup"))
            end):toThrow("duplicate")
        end)
    end)

    describe("KIND_RESPONSE skips byName check", function(): ()
        it("response with same string name does not collide with packet", function(): ()
            Registry.register(packetOpts("query"))
            -- Response intentionally shares the user-facing name; allowed.
            Registry.register(packetOpts("query", Registry.KIND_RESPONSE))
            -- Both stored, second one not in byName.
            expect(Registry.count()):toBe(2)
            expect((Registry.getByName("query") :: any).kind):toBe(Registry.KIND_PACKET)
        end)
    end)

    describe("ID overflow at MAX_ID", function(): ()
        it("registering 128 packets throws on the 128th", function(): ()
            for i = 1, 127 do
                Registry.register(packetOpts(`p_{i}`))
            end
            expect(function(): ()
                Registry.register(packetOpts("p_128"))
            end):toThrow("ID limit")
        end)
    end)

    describe("all() returns every registration", function(): ()
        it("returns array of registered packets", function(): ()
            Registry.register(packetOpts("alpha"))
            Registry.register(packetOpts("beta"))
            local list = Registry.all()
            expect(#list):toBe(2)
        end)
    end)

    describe("Registration carries fields verbatim", function(): ()
        it("name, kind, codec preserved", function(): ()
            local opts = packetOpts("preserve")
            local reg = Registry.register(opts)
            expect(reg.name):toBe("preserve")
            expect(reg.kind):toBe(Registry.KIND_PACKET)
            expect(reg.codec):toBe(opts.codec)
        end)
        it("counter fields initialized to 0", function(): ()
            local reg = Registry.register(packetOpts("counters"))
            expect(reg.bytesSent):toBe(0)
            expect(reg.bytesReceived):toBe(0)
            expect(reg.fires):toBe(0)
            expect(reg.recvFires):toBe(0)
            expect(reg.drops):toBe(0)
        end)
        it("signal is created", function(): ()
            local reg = Registry.register(packetOpts("signal"))
            expect(reg.signal):toBeType("table")
            expect(reg.signal.connect):toBeType("function")
        end)
    end)
end)

return nil
