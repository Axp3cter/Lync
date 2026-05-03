--!strict
--!optimize 2
-- Lync.tuple: positional ordered codec with all-direct fast path.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.composite.Tuple", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("metadata", function(): ()
        it("flags _isTuple", function(): ()
            expect((Lync.tuple(Lync.int(0, 255)) :: any)._isTuple):toBe(true)
        end)
        it("records _elements list", function(): ()
            local elements = (Lync.tuple(Lync.int(0, 255), Lync.string) :: any)._elements
            expect(#elements):toBe(2)
        end)
        it("all-direct exposes _size = sum of inner sizes", function(): ()
            local c = Lync.tuple(Lync.int(0, 255), Lync.int(0, 65535))
            expect((c :: any)._size):toBe(3)
        end)
        it("mixed has no _size", function(): ()
            local c = Lync.tuple(Lync.int(0, 255), Lync.string)
            expect((c :: any)._size):toBeNil()
        end)
        it("all-direct has _directWrite", function(): ()
            local c = Lync.tuple(Lync.int(0, 255))
            expect((c :: any)._directWrite):toBeType("function")
        end)
    end)

    describe("round-trip", function(): ()
        it("single element", function(): ()
            local r = Channel.roundTripStrict(Lync.tuple(Lync.int(0, 255)), { 42 })
            expect(r[1]):toBe(42)
        end)
        it("two mixed elements", function(): ()
            local r =
                Channel.roundTripStrict(Lync.tuple(Lync.int(0, 255), Lync.string), { 42, "hello" })
            expect(r[1]):toBe(42)
            expect(r[2]):toBe("hello")
        end)
        it("five u8 elements", function(): ()
            local c = Lync.tuple(
                Lync.int(0, 255),
                Lync.int(0, 255),
                Lync.int(0, 255),
                Lync.int(0, 255),
                Lync.int(0, 255)
            )
            local r = Channel.roundTripStrict(c, { 1, 2, 3, 4, 5 })
            expect(r[1]):toBe(1)
            expect(r[5]):toBe(5)
        end)
        it("nested tuple round-trips", function(): ()
            local inner = Lync.tuple(Lync.int(0, 255), Lync.int(0, 255))
            local outer = Lync.tuple(inner, Lync.string)
            local r = Channel.roundTripStrict(outer, { { 1, 2 }, "hi" })
            expect(r[1][1]):toBe(1)
            expect(r[1][2]):toBe(2)
            expect(r[2]):toBe("hi")
        end)
    end)

    describe("define-time errors", function(): ()
        it("empty tuple throws", function(): ()
            expect(function(): ()
                Lync.tuple()
            end):toThrow("at least one")
        end)
    end)

    describe("all-direct fast path metadata", function(): ()
        it("all-fixed tuple sums element sizes", function(): ()
            local c = Lync.tuple(Lync.f32, Lync.f64, Lync.bool)
            expect((c :: any)._size):toBe(4 + 8 + 1)
        end)
        it("all-fixed tuple exposes _directRead", function(): ()
            local c = Lync.tuple(Lync.f32, Lync.f64)
            expect((c :: any)._directRead):toBeType("function")
        end)
        it("variable-size element disables direct path", function(): ()
            local c = Lync.tuple(Lync.f32, Lync.string)
            expect((c :: any)._directWrite):toBeNil()
            expect((c :: any)._size):toBeNil()
        end)
        it("Instance element disables direct path (write needs ch.refs)", function(): ()
            local c = Lync.tuple(Lync.f32, Lync.inst)
            expect((c :: any)._directWrite):toBeNil()
        end)
    end)

    describe("element offset arithmetic (all-direct)", function(): ()
        it("byte offsets respect declared order", function(): ()
            local c = Lync.tuple(Lync.f32, Lync.f64)
            local r = Channel.encode(c, { 1.5, 2.5 })
            -- f32 of 1.5 at offset 0; f64 of 2.5 at offset 4.
            expect(buffer.readf32(r.buffer, 0)):toBeCloseTo(1.5)
            expect(buffer.readf64(r.buffer, 4)):toBeCloseTo(2.5)
        end)
    end)

    describe("_hasUnknown propagation", function(): ()
        it("propagates from any element", function(): ()
            local c = Lync.tuple(Lync.int(0, 255), Lync.unknown)
            expect((c :: any)._hasUnknown):toBe(true)
        end)
        it("nil when no element carries unknown", function(): ()
            local c = Lync.tuple(Lync.int(0, 255), Lync.string)
            expect((c :: any)._hasUnknown):toBeNil()
        end)
    end)

    describe("read truncation guards", function(): ()
        it("element codec consuming 0 bytes throws", function(): ()
            -- Construct a custom codec that reports 0 consumed to verify guard.
            local zeroCodec = {
                _typeCheck = "string",
                write = function(_ch: any, _v: any): () end,
                read = function(_b: buffer, _pos: number, _refs: any?)
                    return nil, 0
                end,
            }
            local c = Lync.tuple(zeroCodec :: any)
            local b = buffer.create(0)
            expect(function(): ()
                c.read(b, 0, nil)
            end):toThrow("0 bytes")
        end)
    end)
end)

return nil
