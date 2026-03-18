--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("overflow: channel alloc", function(): ()
    it("throws when exceeding max size", function(): ()
        expect(function(): ()
            local ch = Channel.create()
            ch.cursor = 262140
            ch.size = 262144
            Channel.alloc(ch, 262144)
        end):toThrow("overflow")
    end)
end)

describe("overflow: unknown ref u16 max", function(): ()
    it("throws at 65536 refs", function(): ()
        expect(function(): ()
            local ch = Channel.create()
            local refs = ch.refs :: any
            for i = 1, 65535 do
                refs[i] = true
            end
            Lync.unknown.write(ch, "overflow")
        end):toThrow("overflow")
    end)
end)

describe("overflow: instance ref u16 max", function(): ()
    it("throws at 65536 refs", function(): ()
        expect(function(): ()
            local ch = Channel.create()
            local refs = ch.refs :: any
            for i = 1, 65535 do
                refs[i] = true
            end
            Lync.inst.write(ch, Instance.new("Part"))
        end):toThrow("overflow")
    end)
end)

return nil
