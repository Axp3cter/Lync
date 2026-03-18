--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("inst", function(): ()
    it("round-trips via refs sidecar", function(): ()
        local part = Instance.new("Part")
        local ch = Channel.create()
        Lync.inst.write(ch, part)
        local buf = buffer.create(ch.cursor)
        buffer.copy(buf, 0, ch.buff, 0, ch.cursor)
        local val, consumed = Lync.inst.read(buf, 0, ch.refs)
        expect(val):toBe(part)
        expect(consumed):toBe(ch.cursor)
        part:Destroy()
    end)
    it("throws without refs", function(): ()
        local ch = Channel.create()
        Lync.inst.write(ch, Instance.new("Part"))
        local buf = buffer.create(ch.cursor)
        buffer.copy(buf, 0, ch.buff, 0, ch.cursor)
        expect(function(): ()
            Lync.inst.read(buf, 0, nil)
        end):toThrow("requires refs")
    end)
end)

return nil
