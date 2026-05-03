--!strict
--!optimize 2
-- Lync.enum: u8 index into a fixed string list with _enumValues map.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.meta.Enum", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("metadata", function(): ()
        it("_size = 1", function(): ()
            expect((Lync.enum("a", "b") :: any)._size):toBe(1)
        end)
        it("_typeCheck = string", function(): ()
            expect((Lync.enum("a") :: any)._typeCheck):toBe("string")
        end)
        it("_isEnum flag set", function(): ()
            expect((Lync.enum("a") :: any)._isEnum):toBe(true)
        end)
        it("_enumValues maps each variant to a 0-based index", function(): ()
            local c = Lync.enum("idle", "moving", "attacking") :: any
            expect(c._enumValues.idle):toBe(0)
            expect(c._enumValues.moving):toBe(1)
            expect(c._enumValues.attacking):toBe(2)
        end)
    end)

    describe("round-trip", function(): ()
        it("each variant survives", function(): ()
            local c = Lync.enum("idle", "moving", "attacking", "dead")
            expect(Channel.roundTripStrict(c, "idle")):toBe("idle")
            expect(Channel.roundTripStrict(c, "moving")):toBe("moving")
            expect(Channel.roundTripStrict(c, "attacking")):toBe("attacking")
            expect(Channel.roundTripStrict(c, "dead")):toBe("dead")
        end)
        it("single variant", function(): ()
            expect(Channel.roundTripStrict(Lync.enum("only"), "only")):toBe("only")
        end)
        it("preserves user input order", function(): ()
            local c = Lync.enum("z", "a", "m")
            expect(Channel.roundTripStrict(c, "z")):toBe("z")
            expect(Channel.roundTripStrict(c, "a")):toBe("a")
            expect(Channel.roundTripStrict(c, "m")):toBe("m")
        end)
    end)

    describe("write rejects unknown variant", function(): ()
        it("unknown string throws", function(): ()
            expect(function(): ()
                Channel.encode(Lync.enum("a", "b"), "c")
            end):toThrow("invalid value")
        end)
    end)

    describe("define-time errors", function(): ()
        it("duplicate variants throw", function(): ()
            expect(function(): ()
                Lync.enum("a", "b", "a")
            end):toThrow("duplicate")
        end)
        it("empty list throws", function(): ()
            expect(function(): ()
                Lync.enum()
            end):toThrow("at least one")
        end)
        it("257 variants throws (exceeds 256)", function(): ()
            local args = table.create(257)
            for i = 1, 257 do
                args[i] = `v_{i}`
            end
            expect(function(): ()
                Lync.enum(table.unpack(args))
            end):toThrow()
        end)
        it("256 variants accepted", function(): ()
            local args = table.create(256)
            for i = 1, 256 do
                args[i] = `v_{i}`
            end
            expect(function(): ()
                Lync.enum(table.unpack(args))
            end).never:toThrow()
        end)
    end)

    describe("read-side validation", function(): ()
        it("invalid index throws", function(): ()
            local c = Lync.enum("a", "b")
            local b = buffer.create(1)
            buffer.writeu8(b, 0, 5) -- only indices 0,1 valid
            expect(function(): ()
                c.read(b, 0, nil)
            end):toThrow("invalid index")
        end)
        it("highest valid index decodes correctly", function(): ()
            local c = Lync.enum("first", "second", "third", "fourth")
            local b = buffer.create(1)
            buffer.writeu8(b, 0, 3)
            local v = c.read(b, 0, nil)
            expect(v):toBe("fourth")
        end)
    end)

    describe("wire byte = u8 index", function(): ()
        it("first variant writes byte 0", function(): ()
            local r = Channel.encode(Lync.enum("a", "b"), "a")
            expect(buffer.readu8(r.buffer, 0)):toBe(0)
        end)
        it("second variant writes byte 1", function(): ()
            local r = Channel.encode(Lync.enum("a", "b"), "b")
            expect(buffer.readu8(r.buffer, 0)):toBe(1)
        end)
        it("256th variant writes byte 255 (u8 max)", function(): ()
            local args = table.create(256)
            for i = 1, 256 do
                args[i] = `v_{i}`
            end
            local c = Lync.enum(table.unpack(args))
            local r = Channel.encode(c, "v_256")
            expect(buffer.readu8(r.buffer, 0)):toBe(255)
        end)
    end)

    describe("_enumValues map shape", function(): ()
        it("is a map of variant -> 0-based index", function(): ()
            local c = Lync.enum("x", "y", "z") :: any
            expect(c._enumValues.x):toBe(0)
            expect(c._enumValues.y):toBe(1)
            expect(c._enumValues.z):toBe(2)
            expect(c._enumValues.unknown):toBeNil()
        end)
        it("is frozen", function(): ()
            expect((Lync.enum("a") :: any)._enumValues):toBeFrozen()
        end)
    end)
end)

return nil
