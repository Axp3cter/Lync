--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Runner = require(script.Parent.Parent.Runner)
local Varint = require(script.Parent.Parent.Parent.codec.primitive.Varint)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("Varint encode/decode", function(): ()
    for _, n in { 0, 1, 127, 128, 255, 256, 16383, 16384, 65535, 100000, 2097151 } do
        it(`{n}`, function(): ()
            local ch = Channel.create()
            Varint.write(ch, n)
            local buf = buffer.create(ch.cursor)
            buffer.copy(buf, 0, ch.buff, 0, ch.cursor)
            local val, bytes = Varint.read(buf, 0)
            expect(val):toBe(n)
            expect(bytes):toBe(ch.cursor)
        end)
    end
end)

describe("Varint sizes", function(): ()
    it("1 byte for 0-127", function(): ()
        local ch = Channel.create()
        Varint.write(ch, 127)
        expect(ch.cursor):toBe(1)
    end)
    it("2 bytes for 128-16383", function(): ()
        local ch = Channel.create()
        Varint.write(ch, 128)
        expect(ch.cursor):toBe(2)
    end)
    it("3 bytes for 16384+", function(): ()
        local ch = Channel.create()
        Varint.write(ch, 16384)
        expect(ch.cursor):toBe(3)
    end)
end)

return nil
