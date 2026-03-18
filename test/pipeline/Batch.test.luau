--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Lync = require(script.Parent.Parent.Parent)
local Reader = require(script.Parent.Parent.Parent.transport.Reader)
local Registry = require(script.Parent.Parent.Parent.internal.Registry)
local Runner = require(script.Parent.Parent.Runner)
local Signal = require(script.Parent.Parent.Parent.api.Signal)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("batch: 100 values same packet", function(): ()
    local sig = Signal.create()
    local reg = Registry.register("__batch100", Lync.u16, false, sig, nil, nil)

    it("all 100 arrive in order", function(): ()
        local ch = Channel.create()
        for i = 1, 100 do
            Channel.writeBatch(ch, reg, i)
        end
        local raw, refs = Channel.sealAndDump(ch)

        local values = {} :: { number }
        local conn = sig:connect(function(v: any): ()
            table.insert(values, v)
        end)
        Reader.process(raw, refs, nil, 0)
        expect(#values):toBe(100)
        expect(values[1]):toBe(1)
        expect(values[50]):toBe(50)
        expect(values[100]):toBe(100)
        conn:disconnect()
    end)
end)

describe("batch: interleaved packets", function(): ()
    local sigA = Signal.create()
    local sigB = Signal.create()
    local regA = Registry.register("__batchA", Lync.u8, false, sigA, nil, nil)
    local regB = Registry.register("__batchB", Lync.string, false, sigB, nil, nil)

    it("values arrive to correct signals", function(): ()
        local ch = Channel.create()
        Channel.writeBatch(ch, regA, 1)
        Channel.writeBatch(ch, regA, 2)
        Channel.writeBatch(ch, regB, "hello")
        Channel.writeBatch(ch, regA, 3)
        local raw, refs = Channel.sealAndDump(ch)

        local numsA = {} :: { number }
        local strsB = {} :: { string }
        local connA = sigA:connect(function(v: any): ()
            table.insert(numsA, v)
        end)
        local connB = sigB:connect(function(v: any): ()
            table.insert(strsB, v)
        end)
        Reader.process(raw, refs, nil, 0)
        expect(#numsA):toBe(3)
        expect(#strsB):toBe(1)
        expect(numsA[1]):toBe(1)
        expect(numsA[3]):toBe(3)
        expect(strsB[1]):toBe("hello")
        connA:disconnect()
        connB:disconnect()
    end)
end)

return nil
