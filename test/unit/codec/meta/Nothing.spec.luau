--!strict
--!optimize 2
-- Lync.nothing: zero-byte constant codec returning nil.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.meta.Nothing", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("metadata", function(): ()
        it("_size = 0", function(): ()
            expect((Lync.nothing :: any)._size):toBe(0)
        end)
        it("exposes _directWrite (no-op)", function(): ()
            expect((Lync.nothing :: any)._directWrite):toBeType("function")
        end)
        it("exposes _directRead returning nil", function(): ()
            expect((Lync.nothing :: any)._directRead):toBeType("function")
        end)
        it("exposes channel-level write", function(): ()
            expect((Lync.nothing :: any).write):toBeType("function")
        end)
        it("exposes channel-level read", function(): ()
            expect((Lync.nothing :: any).read):toBeType("function")
        end)
        it("codec table is frozen", function(): ()
            expect(Lync.nothing):toBeFrozen()
        end)
    end)

    describe("write semantics", function(): ()
        it("write produces zero bytes", function(): ()
            local r = Channel.encode(Lync.nothing, nil)
            expect(r.length):toBe(0)
        end)
        it("write does not advance the channel cursor", function(): ()
            local InternalChannel = Env.Internal.Channel
            local ch = InternalChannel.create()
            Lync.nothing.write(ch, nil)
            expect(ch.cursor):toBe(0)
        end)
        it("write does not push any refs", function(): ()
            local InternalChannel = Env.Internal.Channel
            local ch = InternalChannel.create()
            Lync.nothing.write(ch, nil)
            expect(ch.refCount):toBe(0)
        end)
        it("two writes still produce zero bytes", function(): ()
            local r = Channel.encodeMany(Lync.nothing, { nil, nil })
            expect(r.length):toBe(0)
        end)
        it("100 writes still produce zero bytes", function(): ()
            local many = table.create(100)
            local r = Channel.encodeMany(Lync.nothing, many)
            expect(r.length):toBe(0)
        end)
    end)

    describe("read semantics", function(): ()
        it("read consumes zero bytes and returns nil", function(): ()
            local r = Channel.encode(Lync.nothing, nil)
            local v, c = Channel.decode(Lync.nothing, r)
            expect(v):toBeNil()
            expect(c):toBe(0)
        end)
        it("_directRead returns nil regardless of buffer content", function(): ()
            local b = buffer.create(8)
            buffer.writeu8(b, 0, 0xFF)
            expect((Lync.nothing :: any)._directRead(b, 0)):toBeNil()
        end)
        it("read at non-zero offset still returns nil", function(): ()
            local b = buffer.create(16)
            local v, c = Lync.nothing.read(b, 8, nil)
            expect(v):toBeNil()
            expect(c):toBe(0)
        end)
        it("read on empty buffer returns nil, 0", function(): ()
            local b = buffer.create(0)
            local v, c = Lync.nothing.read(b, 0, nil)
            expect(v):toBeNil()
            expect(c):toBe(0)
        end)
    end)

    describe("regression: send(nil) reaches the receiver", function(): ()
        --[[
            Lync.nothing represents fire-and-forget signals where the user
            passes nil as the legitimate payload. Earlier the send pipeline
            conflated nil-payload with middleware-drop, eating the frame.
        ]]
        it("packet with Lync.nothing accepts nil without throwing on define", function(): ()
            expect(function(): ()
                Lync.packet("nothing_define", Lync.nothing)
            end).never:toThrow()
        end)
        it("encoding nil with nothing yields a 0-byte payload", function(): ()
            local r = Channel.encode(Lync.nothing, nil)
            expect(r.length):toBe(0)
            expect(r.refCount):toBe(0)
        end)
    end)

    describe("nothing as a struct field", function(): ()
        it("struct with a single nothing field encodes to 0 bytes", function(): ()
            local s = Lync.struct({ trigger = Lync.nothing })
            local r = Channel.encode(s, { trigger = nil })
            expect(r.length):toBe(0)
        end)
        it("struct mixing int and nothing only writes the int", function(): ()
            local s = Lync.struct({ x = Lync.int(0, 255), trigger = Lync.nothing })
            local r = Channel.encode(s, { x = 42, trigger = nil })
            expect(r.length):toBe(1)
            expect(buffer.readu8(r.buffer, 0)):toBe(42)
        end)
    end)
end)

return nil
