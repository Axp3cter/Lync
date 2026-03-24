--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("Channel: create defaults", function(): ()
    it("cursor = 0", function(): () expect(Channel.create().cursor):toBe(0) end)
    it("size = 1024", function(): () expect(Channel.create().size):toBe(1024) end)
    it("refCount = 0", function(): () expect(Channel.create().refCount):toBe(0) end)
    it("lastId = -1", function(): () expect(Channel.create().lastId):toBe(-1) end)
    it("singleMode = false", function(): () expect(Channel.create().singleMode):toBe(false) end)
    it("refs is empty table", function(): () expect(#Channel.create().refs):toBe(0) end)
    it("deltas is empty table", function(): () local ch = Channel.create(); local count = 0; for _ in ch.deltas do count += 1 end; expect(count):toBe(0) end)
end)

describe("Channel: alloc grows to next power-of-two", function(): ()
    it("1024 → 2048", function(): ()
        local ch = Channel.create(); ch.cursor = 1020
        Channel.alloc(ch, 100); expect(ch.size):toBe(2048)
    end)
    it("2048 → 4096", function(): ()
        local ch = Channel.create(); ch.cursor = 1020
        Channel.alloc(ch, 100) -- now 2048
        ch.cursor = 2000; Channel.alloc(ch, 200); expect(ch.size):toBe(4096)
    end)
    it("preserves existing data", function(): ()
        local ch = Channel.create()
        buffer.writeu32(ch.buff, 0, 0xDEADBEEF); ch.cursor = 4
        Channel.alloc(ch, 2000)
        expect(buffer.readu32(ch.buff, 0)):toBe(0xDEADBEEF)
    end)
    it("no-op when space sufficient", function(): ()
        local ch = Channel.create(); local orig = ch.buff
        Channel.alloc(ch, 100); expect(ch.buff):toBe(orig)
    end)
    it("preserves cursor position", function(): ()
        local ch = Channel.create(); ch.cursor = 500
        Channel.alloc(ch, 2000); expect(ch.cursor):toBe(500)
    end)
end)

describe("Channel: reset", function(): ()
    it("zeros cursor", function(): ()
        local ch = Channel.create(); ch.cursor = 500; Channel.reset(ch); expect(ch.cursor):toBe(0)
    end)
    it("resets lastId to -1", function(): ()
        local ch = Channel.create(); ch.lastId = 5; Channel.reset(ch); expect(ch.lastId):toBe(-1)
    end)
    it("resets itemCount to 0", function(): ()
        local ch = Channel.create(); ch.itemCount = 10; Channel.reset(ch); expect(ch.itemCount):toBe(0)
    end)
    it("resets singleMode to false", function(): ()
        local ch = Channel.create(); ch.singleMode = true; Channel.reset(ch); expect(ch.singleMode):toBe(false)
    end)
    it("clears refs when refCount > 0", function(): ()
        local ch = Channel.create(); ch.refCount = 2; ch.refs[1] = {} :: any; ch.refs[2] = {} :: any
        Channel.reset(ch); expect(ch.refCount):toBe(0)
    end)
    it("keeps buffer allocation", function(): ()
        local ch = Channel.create(); ch.cursor = 500; local s = ch.size
        Channel.reset(ch); expect(ch.size):toBe(s)
    end)
end)

describe("Channel: sealAndDump", function(): ()
    it("returns snapshot copy", function(): ()
        local ch = Channel.create(); buffer.writeu32(ch.buff, 0, 0xCAFE); ch.cursor = 4
        local snap, _, byteLen, _ = Channel.sealAndDump(ch)
        expect(byteLen):toBe(4); expect(buffer.readu32(snap, 0)):toBe(0xCAFE)
    end)
    it("snapshot is isolated from channel", function(): ()
        local ch = Channel.create(); buffer.writeu32(ch.buff, 0, 0xCAFE); ch.cursor = 4
        local snap, _, _, _ = Channel.sealAndDump(ch)
        buffer.writeu32(snap, 0, 0); expect(buffer.readu32(ch.buff, 0)):toBe(0xCAFE)
    end)
    it("clones refs when present", function(): ()
        local ch = Channel.create(); ch.cursor = 2; ch.refCount = 1
        local inst = {} :: any; ch.refs[1] = inst
        local _, refs, _, rc = Channel.sealAndDump(ch)
        expect(rc):toBe(1); expect(refs[1]):toBe(inst)
        refs[1] = nil :: any; expect(ch.refs[1]):toBe(inst)
    end)
    it("returns frozen empty refs when none", function(): ()
        local ch = Channel.create(); ch.cursor = 1
        local _, refs, _, rc = Channel.sealAndDump(ch)
        expect(rc):toBe(0)
        expect(function(): () (refs :: any)[1] = "bad" end):toThrow()
    end)
    it("byteLen matches cursor", function(): ()
        local ch = Channel.create(); ch.cursor = 42
        local _, _, byteLen, _ = Channel.sealAndDump(ch)
        expect(byteLen):toBe(42)
    end)
end)

describe("Channel: timestamp constants", function(): ()
    it("TS_NONE = 0", function(): () expect(Channel.TS_NONE):toBe(0) end)
    it("TS_FRAME = 1", function(): () expect(Channel.TS_FRAME):toBe(1) end)
    it("TS_OFFSET = 2", function(): () expect(Channel.TS_OFFSET):toBe(2) end)
    it("TS_FULL = 3", function(): () expect(Channel.TS_FULL):toBe(3) end)
end)

return nil
