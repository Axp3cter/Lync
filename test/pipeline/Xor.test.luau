--!strict
--!optimize 2
local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe ("XOR multi-frame", function (): ()
    it ("three consecutive frames recover all data", function (): ()
        local f1 = buffer.create (4)
        buffer.writeu32 (f1, 0, 0xAAAAAAAA)
        local f2 = buffer.create (4)
        buffer.writeu32 (f2, 0, 0xBBBBBBBB)
        local f3 = buffer.create (4)
        buffer.writeu32 (f3, 0, 0xCCCCCCCC)

        local x1 = Channel.xorApply (f1, nil)
        local x2 = Channel.xorApply (f2, f1)
        local x3 = Channel.xorApply (f3, f2)

        local r1 = Channel.xorApply (x1, nil)
        local r2 = Channel.xorApply (x2, f1)
        local r3 = Channel.xorApply (x3, f2)

        expect (buffer.readu32 (r1, 0)):toBe (0xAAAAAAAA)
        expect (buffer.readu32 (r2, 0)):toBe (0xBBBBBBBB)
        expect (buffer.readu32 (r3, 0)):toBe (0xCCCCCCCC)
    end)
    it ("growing buffer sizes", function (): ()
        local f1 = buffer.create (4)
        buffer.writeu32 (f1, 0, 0x11)
        local f2 = buffer.create (8)
        buffer.writeu32 (f2, 0, 0x22)
        buffer.writeu32 (f2, 4, 0x33)

        local x2 = Channel.xorApply (f2, f1)
        local r2 = Channel.xorApply (x2, f1)
        expect (buffer.readu32 (r2, 0)):toBe (0x22)
        expect (buffer.readu32 (r2, 4)):toBe (0x33)
    end)
    it ("shrinking buffer sizes", function (): ()
        local f1 = buffer.create (8)
        buffer.writeu32 (f1, 0, 0xAA)
        buffer.writeu32 (f1, 4, 0xBB)
        local f2 = buffer.create (4)
        buffer.writeu32 (f2, 0, 0xCC)

        local x2 = Channel.xorApply (f2, f1)
        local r2 = Channel.xorApply (x2, f1)
        expect (buffer.readu32 (r2, 0)):toBe (0xCC)
    end)
end)

return nil
