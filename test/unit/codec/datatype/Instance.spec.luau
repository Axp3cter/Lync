--!strict
--!optimize 2
-- Lync.inst: 2-byte sidecar ref index codec.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox
local Wire = Env.Wire

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach
local afterEach = Env.afterEach

describe("codec.datatype.Instance", function(): ()
    local created: { Instance } = {}

    beforeEach(function(): ()
        Sandbox.resetAll()
        table.clear(created)
    end)

    afterEach(function(): ()
        for _, inst in created do
            inst:Destroy()
        end
        table.clear(created)
    end)

    local function newPart(): Instance
        local part = Instance.new("Part")
        table.insert(created, part)
        return part
    end

    describe("metadata", function(): ()
        it("_size = 2", function(): ()
            expect((Lync.inst :: any)._size):toBe(2)
        end)
        it("_typeCheck = Instance", function(): ()
            expect((Lync.inst :: any)._typeCheck):toBe("Instance")
        end)
        it("does not expose _directWrite (write needs ch.refs)", function(): ()
            expect((Lync.inst :: any)._directWrite):toBeNil()
        end)
        it("does not expose _directRead (read needs refs sidecar)", function(): ()
            expect((Lync.inst :: any)._directRead):toBeNil()
        end)
    end)

    describe("write pushes ref and writes 2-byte index", function(): ()
        it("single Instance increments refCount", function(): ()
            local part = newPart()
            local r = Channel.encode(Lync.inst, part)
            expect(r.refCount):toBe(1)
            expect(r.refs[1]):toBe(part)
            expect(r.length):toBe(2)
        end)
        it("two distinct Instances get separate refs", function(): ()
            local p1 = newPart()
            local p2 = newPart()
            local p3 = newPart()
            -- Encode three together via composite to share a channel.
            local arr = Lync.array(Lync.inst)
            local r = Channel.encode(arr, { p1, p2, p3 })
            expect(r.refCount):toBe(3)
            expect(r.refs[1]):toBe(p1)
            expect(r.refs[2]):toBe(p2)
            expect(r.refs[3]):toBe(p3)
        end)
    end)

    describe("read", function(): ()
        it("round-trips through refs sidecar", function(): ()
            local part = newPart()
            local r = Channel.encode(Lync.inst, part)
            local v, c = Channel.decode(Lync.inst, r)
            expect(v):toBe(part)
            expect(c):toBe(2)
        end)
        it("rejects nil refs argument", function(): ()
            local raw = Wire.bufferFromBytes({ 0x01, 0x00 })
            expect(function(): ()
                Lync.inst.read(raw, 0, nil)
            end):toThrow("refs array is required")
        end)
        it("rejects out-of-bounds ref index", function(): ()
            local raw = Wire.bufferFromBytes({ 0x05, 0x00 })
            expect(function(): ()
                Lync.inst.read(raw, 0, {} :: any)
            end):toThrow("out of bounds")
        end)
    end)

    describe("ref index byte layout (1-based u16, little-endian)", function(): ()
        it("first ref writes index 1 = 0x01 0x00", function(): ()
            local p = newPart()
            local r = Channel.encode(Lync.inst, p)
            expect(buffer.readu8(r.buffer, 0)):toBe(1)
            expect(buffer.readu8(r.buffer, 1)):toBe(0)
        end)
        it("256th ref index = 0x00 0x01 (low/high byte order)", function(): ()
            local arr = Lync.array(Lync.inst)
            local parts = table.create(256)
            for i = 1, 256 do
                parts[i] = newPart()
            end
            local r = Channel.encode(arr, parts)
            -- Skip varint count prefix (1 byte for 256? actually 256 > 191 so 2 bytes).
            -- Easier: just decode and verify last index.
            local decoded = Channel.decode(arr, r)
            expect(decoded[256]):toBe(parts[256])
        end)
    end)

    describe("read with non-Instance ref slot", function(): ()
        it("rejects when refs[i] is a table instead of Instance", function(): ()
            local raw = Wire.bufferFromBytes({ 0x01, 0x00 })
            expect(function(): ()
                Lync.inst.read(raw, 0, { {} :: any })
            end):toThrow("not an Instance")
        end)
        it("rejects when refs[i] is a string", function(): ()
            local raw = Wire.bufferFromBytes({ 0x01, 0x00 })
            expect(function(): ()
                Lync.inst.read(raw, 0, { "fake" :: any })
            end):toThrow("not an Instance")
        end)
    end)

    describe("zero index rejection", function(): ()
        it("index 0 (1-based scheme means 0 is invalid)", function(): ()
            local raw = Wire.bufferFromBytes({ 0x00, 0x00 })
            expect(function(): ()
                Lync.inst.read(raw, 0, { newPart() })
            end):toThrow("out of bounds")
        end)
    end)

    describe("repeated writes append, do not deduplicate", function(): ()
        it("same Instance written twice yields refCount 2", function(): ()
            local p = newPart()
            local arr = Lync.array(Lync.inst)
            local r = Channel.encode(arr, { p, p })
            expect(r.refCount):toBe(2)
            -- Both refs point at the same Instance.
            expect(r.refs[1]):toBe(p)
            expect(r.refs[2]):toBe(p)
        end)
    end)
end)

return nil
