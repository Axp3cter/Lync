--!strict
--!optimize 2
-- Channel.test.luau — Lifecycle tests for buffer allocation, dump, reset, shrink.

local Runner  = require(script.Parent.Parent.Runner)
local Channel = require(script.Parent.Parent.Parent.core.Channel)

local describe = Runner.describe
local it       = Runner.it
local expect   = Runner.expect

-- Tests ------------------------------------------------------------------

describe("Channel.create", function(): ()
    it("returns a channel with initial size 256", function(): ()
        local ch = Channel.create()
        expect(ch.size):toBe(256)
        expect(ch.cursor):toBe(0)
        expect(#ch.refs):toBe(0)
        expect(ch.lowFrames):toBe(0)
    end)
end)

describe("Channel.alloc", function(): ()
    it("does nothing when space is available", function(): ()
        local ch = Channel.create()
        Channel.alloc(ch, 100)
        expect(ch.size):toBe(256)
    end)
    it("grows when needed", function(): ()
        local ch = Channel.create()
        Channel.alloc(ch, 300)
        expect(ch.size >= 300):toBe(true)
    end)
    it("preserves existing data on grow", function(): ()
        local ch = Channel.create()
        buffer.writeu8(ch.buff, 0, 0xAB)
        ch.cursor = 1
        Channel.alloc(ch, 300)
        expect(buffer.readu8(ch.buff, 0)):toBe(0xAB)
    end)
    it("throws on exceeding max size", function(): ()
        expect(function(): ()
            local ch = Channel.create()
            Channel.alloc(ch, 65537)
        end):toThrow("Buffer overflow")
    end)
end)

describe("Channel.dump", function(): ()
    it("returns exact copy of written data", function(): ()
        local ch = Channel.create()
        buffer.writeu32(ch.buff, 0, 0xDEADBEEF)
        ch.cursor = 4

        local buf, refs = Channel.dump(ch)
        expect(buffer.len(buf)):toBe(4)
        expect(buffer.readu32(buf, 0)):toBe(0xDEADBEEF)
        expect(refs):toBeNil()
    end)
    it("returns cloned refs when refs are present", function(): ()
        local ch   = Channel.create()
        local part = Instance.new("Part")
        table.insert(ch.refs, part)
        ch.cursor = 1

        local _, refs = Channel.dump(ch)
        expect(refs).never:toBeNil()
        expect((refs :: any)[1]):toBe(part)
        part:Destroy()
    end)
end)

describe("Channel.reset", function(): ()
    it("zeroes cursor and clears refs", function(): ()
        local ch = Channel.create()
        ch.cursor = 100
        table.insert(ch.refs, Instance.new("Part"))
        Channel.reset(ch)
        expect(ch.cursor):toBe(0)
        expect(#ch.refs):toBe(0)
    end)
    it("shrinks buffer after sustained low usage", function(): ()
        local ch = Channel.create()
        Channel.alloc(ch, 300)
        local grownSize = ch.size

        for _ = 1, 61 do
            ch.cursor = 1
            Channel.reset(ch)
        end

        expect(ch.size < grownSize):toBe(true)
    end)
    it("does not shrink below initial size", function(): ()
        local ch = Channel.create()
        for _ = 1, 100 do
            ch.cursor = 0
            Channel.reset(ch)
        end
        expect(ch.size):toBe(256)
    end)
end)

return nil
