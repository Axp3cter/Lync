--!strict
--!optimize 2
-- Base.define, Base.constant, Base.alloc, Base.setMaxSize.

local Env = require(script:FindFirstAncestor("test").Env)

local Base = Env.Internal.Base
local InternalChannel = Env.Internal.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.Base", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("define wraps direct primitives into a codec", function(): ()
        local function makeU8(): any
            return Base.define(1, function(b: buffer, off: number, value: number): ()
                buffer.writeu8(b, off, value)
            end, function(b: buffer, off: number): number
                return buffer.readu8(b, off)
            end, { _typeCheck = "number" })
        end

        it("exposes _size", function(): ()
            expect((makeU8() :: any)._size):toBe(1)
        end)
        it("exposes _directWrite and _directRead", function(): ()
            expect((makeU8() :: any)._directWrite):toBeType("function")
            expect((makeU8() :: any)._directRead):toBeType("function")
        end)
        it("merges metadata into the codec table", function(): ()
            expect((makeU8() :: any)._typeCheck):toBe("number")
        end)
        it("write advances cursor and stores byte", function(): ()
            local codec = makeU8()
            local ch = InternalChannel.create()
            codec.write(ch, 42)
            expect(ch.cursor):toBe(1)
            expect(buffer.readu8(ch.buff, 0)):toBe(42)
        end)
        it("read returns value plus consumed bytes", function(): ()
            local codec = makeU8()
            local b = buffer.create(1)
            buffer.writeu8(b, 0, 42)
            local v, c = codec.read(b, 0, nil)
            expect(v):toBe(42)
            expect(c):toBe(1)
        end)
        it("returns a frozen codec table", function(): ()
            expect(makeU8()):toBeFrozen()
        end)
    end)

    describe("constant codec", function(): ()
        it("_size = 0", function(): ()
            expect((Base.constant("anything") :: any)._size):toBe(0)
        end)
        it("write does not advance the cursor", function(): ()
            local c = Base.constant(42)
            local ch = InternalChannel.create()
            c.write(ch, 999)
            expect(ch.cursor):toBe(0)
        end)
        it("read always returns the constant value", function(): ()
            local c = Base.constant("baked")
            local b = buffer.create(0)
            local v, consumed = c.read(b, 0, nil)
            expect(v):toBe("baked")
            expect(consumed):toBe(0)
        end)
    end)

    describe("alloc grows the channel buffer", function(): ()
        it("doubles to next power-of-two when needed", function(): ()
            local ch = InternalChannel.create()
            ch.cursor = 1020
            Base.alloc(ch, 100)
            expect(ch.size):toBe(2048)
        end)
        it("preserves existing bytes after growth", function(): ()
            local ch = InternalChannel.create()
            buffer.writeu32(ch.buff, 0, 0xDEADBEEF)
            ch.cursor = 4
            Base.alloc(ch, 2000)
            expect(buffer.readu32(ch.buff, 0)):toBe(0xDEADBEEF)
        end)
        it("no-op when space is sufficient", function(): ()
            local ch = InternalChannel.create()
            local original = ch.buff
            Base.alloc(ch, 100)
            expect(ch.buff):toBe(original)
        end)
        it("zero bytes is a no-op even when cursor is large", function(): ()
            local ch = InternalChannel.create()
            ch.cursor = 500
            Base.alloc(ch, 0)
            expect(ch.cursor):toBe(500)
        end)
    end)

    describe("alloc throws on overflow", function(): ()
        it("growth past max throws with byte details", function(): ()
            Base.setMaxSize(2048)
            local ch = InternalChannel.create()
            ch.cursor = 2000
            expect(function(): ()
                Base.alloc(ch, 1000)
            end):toThrow("overflow")
        end)
        it("error message includes packet name when set", function(): ()
            Base.setMaxSize(1024)
            local ch = InternalChannel.create()
            ch.cursor = 1000
            ch.currentPacket = "RuntimePkt"
            expect(function(): ()
                Base.alloc(ch, 200)
            end):toThrow("RuntimePkt")
        end)
    end)

    describe("default cap matches Roblox's RemoteEvent ceiling", function(): ()
        -- 256KB silently broke users at >500 entities × 100 fires/frame; 1MB
        -- aligns the default with Roblox's actual per-fire payload limit.
        it("alloc to 600KB succeeds at default cap (formerly 256KB)", function(): ()
            local ch = InternalChannel.create()
            expect(function(): ()
                Base.alloc(ch, 600 * 1024)
            end).never:toThrow()
            expect(ch.size):toBeGreaterThanOrEqual(600 * 1024)
        end)
        it("alloc to 1MB succeeds at default cap", function(): ()
            local ch = InternalChannel.create()
            expect(function(): ()
                Base.alloc(ch, 1024 * 1024)
            end).never:toThrow()
        end)
        it("alloc past 1MB throws at default cap", function(): ()
            local ch = InternalChannel.create()
            ch.cursor = 1024 * 1024
            expect(function(): ()
                Base.alloc(ch, 1)
            end):toThrow("overflow")
        end)
    end)
end)

return nil
