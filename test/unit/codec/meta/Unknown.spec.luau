--!strict
--!optimize 2
-- Lync.unknown: bypass-serialization codec routed through ch.refs sidecar.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox
local Wire = Env.Wire

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.meta.Unknown", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("metadata", function(): ()
        it("flags _hasUnknown", function(): ()
            expect((Lync.unknown :: any)._hasUnknown):toBe(true)
        end)
        it("is frozen", function(): ()
            expect(Lync.unknown):toBeFrozen()
        end)
    end)

    describe("write stores ref and emits 2-byte index", function(): ()
        it("a string ref", function(): ()
            local r = Channel.encode(Lync.unknown, "anything")
            expect(r.refCount):toBe(1)
            expect(r.refs[1]):toBe("anything")
            expect(r.length):toBe(2)
        end)
        it("a table ref preserves identity", function(): ()
            local val = { nested = true, count = 42 }
            local r = Channel.encode(Lync.unknown, val)
            expect(r.refs[1]):toBe(val)
        end)
    end)

    describe("read", function(): ()
        it("requires refs argument", function(): ()
            local raw = Wire.bufferFromBytes({ 0x01, 0x00 })
            expect(function(): ()
                Lync.unknown.read(raw, 0, nil)
            end):toThrow("refs array is required")
        end)
        it("rejects out-of-bounds index", function(): ()
            local raw = Wire.bufferFromBytes({ 0x05, 0x00 })
            expect(function(): ()
                Lync.unknown.read(raw, 0, {} :: any)
            end):toThrow("out of bounds")
        end)
        it("returns the ref by identity", function(): ()
            local val = { nested = true }
            local r = Channel.encode(Lync.unknown, val)
            local v, c = Channel.decode(Lync.unknown, r)
            expect(v):toBe(val)
            expect(c):toBe(2)
        end)
    end)

    describe("_hasUnknown propagates through composites", function(): ()
        it("optional(unknown)", function(): ()
            expect((Lync.optional(Lync.unknown) :: any)._hasUnknown):toBe(true)
        end)
        it("tagged carries unknown via any variant", function(): ()
            local c = Lync.tagged("t", {
                ok = Lync.struct({ x = Lync.int(0, 255) }),
                anything = Lync.struct({ payload = Lync.unknown }),
            })
            expect((c :: any)._hasUnknown):toBe(true)
        end)
        it("array of unknown", function(): ()
            expect((Lync.array(Lync.unknown) :: any)._hasUnknown):toBe(true)
        end)
        it("map with unknown value", function(): ()
            local c = Lync.map(Lync.string, Lync.unknown)
            expect((c :: any)._hasUnknown):toBe(true)
        end)
        it("map with unknown key", function(): ()
            local c = Lync.map(Lync.unknown, Lync.int(0, 255))
            expect((c :: any)._hasUnknown):toBe(true)
        end)
        it("tuple containing unknown", function(): ()
            expect((Lync.tuple(Lync.int(0, 255), Lync.unknown) :: any)._hasUnknown):toBe(true)
        end)
        it("struct containing unknown field", function(): ()
            local c = Lync.struct({ a = Lync.int(0, 255), b = Lync.unknown })
            expect((c :: any)._hasUnknown):toBe(true)
        end)
        it("nested unknown propagates two levels", function(): ()
            local inner = Lync.struct({ payload = Lync.unknown })
            local outer = Lync.array(inner)
            expect((outer :: any)._hasUnknown):toBe(true)
        end)
    end)

    describe("various ref types", function(): ()
        it("Instance ref", function(): ()
            local f = Instance.new("Folder")
            local r = Channel.encode(Lync.unknown, f)
            expect(Channel.decode(Lync.unknown, r)):toBe(f)
            f:Destroy()
        end)
        it("number ref", function(): ()
            local r = Channel.encode(Lync.unknown, 42)
            expect(Channel.decode(Lync.unknown, r)):toBe(42)
        end)
        it("boolean ref", function(): ()
            local r = Channel.encode(Lync.unknown, true)
            expect(Channel.decode(Lync.unknown, r)):toBe(true)
        end)
        it("nil ref preserves identity slot", function(): ()
            local r = Channel.encode(Lync.unknown, nil)
            expect(r.refCount):toBe(1)
            expect(r.refs[1]):toBeNil()
        end)
        it("vector ref by value (vectors are value types)", function(): ()
            local v = Vector3.new(1, 2, 3)
            local r = Channel.encode(Lync.unknown, v)
            local decoded = Channel.decode(Lync.unknown, r)
            expect(decoded):toBe(v)
        end)
    end)

    describe("zero index rejection", function(): ()
        it("u16 index 0 is out of bounds (1-based)", function(): ()
            local raw = Wire.bufferFromBytes({ 0x00, 0x00 })
            expect(function(): ()
                Lync.unknown.read(raw, 0, { "x" :: any })
            end):toThrow("out of bounds")
        end)
    end)
end)

return nil
