--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("truncated string", function(): ()
    it("length exceeds buffer", function(): ()
        expect(function(): ()
            local buf = buffer.create(5); buffer.writeu8(buf, 0, 100)
            Lync.string.read(buf, 0, nil)
        end):toThrow("exceeds")
    end)
    it("varint length but no string data", function(): ()
        expect(function(): ()
            local buf = buffer.create(2); buffer.writeu8(buf, 0, 50)
            Lync.string.read(buf, 0, nil)
        end):toThrow("exceeds")
    end)
end)

describe("truncated buffer", function(): ()
    it("length exceeds remaining", function(): ()
        expect(function(): ()
            local buf = buffer.create(3); buffer.writeu8(buf, 0, 50)
            Lync.buff.read(buf, 0, nil)
        end):toThrow("exceeds")
    end)
end)

describe("truncated varint", function(): ()
    it("2-byte varint at EOF", function(): ()
        expect(function(): ()
            local buf = buffer.create(1); buffer.writeu8(buf, 0, 0xC0)
            local Varint = require(script.Parent.Parent.Parent.codec.primitive.Varint)
            Varint.read(buf, 0)
        end):toThrow()
    end)
end)

return nil
