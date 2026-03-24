--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("unknown codec", function(): ()
    it("_hasUnknown = true", function(): () expect((Lync.unknown :: any)._hasUnknown):toBe(true) end)
    it("write stores value in refs", function(): ()
        local ch = Channel.create()
        Lync.unknown.write(ch, "anything")
        expect(ch.refCount):toBe(1); expect((ch.refs :: any)[1]):toBe("anything")
    end)
    it("read requires refs", function(): ()
        local buf = buffer.create(2); buffer.writeu16(buf, 0, 1)
        expect(function(): () Lync.unknown.read(buf, 0, nil) end):toThrow("requires refs")
    end)
    it("round-trip any value type", function(): ()
        local ch = Channel.create()
        local val = { nested = true, count = 42 }
        Lync.unknown.write(ch, val)
        local buf = buffer.create(ch.cursor); buffer.copy(buf, 0, ch.buff, 0, ch.cursor)
        local r, c = Lync.unknown.read(buf, 0, ch.refs :: any)
        expect(r):toBe(val); expect(c):toBe(2)
    end)
end)

return nil
