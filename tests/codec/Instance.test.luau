--!strict
--!optimize 2
-- Instance.test.luau — Round-trip tests for Instance sidecar reference codec.

local Channel = require (script.Parent.Parent.Parent.core.Channel)
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)

local describe = Runner.describe
local it = Runner.it
local expect = Runner.expect

-- Tests ------------------------------------------------------------------

describe ("Instance", function (): ()
    it ("round-trips a Part reference", function (): ()
        local part = Instance.new ("Part")
        local ch = Channel.create ()

        Lync.inst.write (ch, part)

        local buf = buffer.create (ch.cursor)
        buffer.copy (buf, 0, ch.buff, 0, ch.cursor)

        local result, consumed = Lync.inst.read (buf, 0, ch.refs)
        expect (consumed):toBe (2)
        expect (result):toBe (part)

        part:Destroy ()
    end)
    it ("round-trips multiple instances in order", function (): ()
        local partA = Instance.new ("Part")
        local partB = Instance.new ("Part")
        local ch = Channel.create ()

        Lync.inst.write (ch, partA)
        Lync.inst.write (ch, partB)

        local buf = buffer.create (ch.cursor)
        buffer.copy (buf, 0, ch.buff, 0, ch.cursor)

        local resultA, consumedA = Lync.inst.read (buf, 0, ch.refs)
        local resultB, _ = Lync.inst.read (buf, consumedA, ch.refs)
        expect (resultA):toBe (partA)
        expect (resultB):toBe (partB)

        partA:Destroy ()
        partB:Destroy ()
    end)
    it ("throws on nil refs array", function (): ()
        local buf = buffer.create (2)
        buffer.writeu16 (buf, 0, 1)

        expect (function (): ()
            Lync.inst.read (buf, 0, nil)
        end):toThrow ("refs array is nil")
    end)
end)

return nil
