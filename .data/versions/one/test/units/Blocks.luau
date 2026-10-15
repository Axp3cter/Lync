--!strict
--!optimize 2
-- One block of a frame: sealed as a copy, held by count, and pooled once nobody holds it.

local Blocks = require("@src/channel/Blocks")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local function scratch(text: string): buffer
    local b = buffer.create(32)
    buffer.writestring(b, 0, text)
    return b
end

return {
    -- A block is exactly the bytes written, copied out of the scratch, with its refs copied too.
    Harness.case("blocks.sealed-copies", function()
        local into = scratch("hello world")
        local refs: { Instance } = { Instance.new("Folder") }
        local block = Blocks.sealed(into, 5, Blocks.PACKET, 7, refs)
        Expect.equal(buffer.len(block.buf), 5)
        Expect.equal(buffer.tostring(block.buf), "hello")
        Expect.equal(block.len, 5)
        Expect.equal(block.class, Blocks.PACKET)
        Expect.equal(block.seq, 7)
        Expect.equal(block.rc, 1)
        Expect.equal(block.refs, refs)
        Expect.holds(block.refs ~= refs, "the refs were held rather than copied")

        buffer.writestring(into, 0, "HELLO")
        Expect.equal(buffer.tostring(block.buf), "hello")
        Expect.equal(Blocks.sealed(into, 3, Blocks.LOOSE, 0, nil).refs, nil)
    end),

    -- A hold taken past the call keeps the block, and the last release pools it for the next seal,
    -- pinning no bytes in between.
    Harness.case("blocks.holds-and-pool", function()
        local block = Blocks.sealed(scratch("abc"), 3, Blocks.DELTA, 1, nil)
        Blocks.retain(block)
        Blocks.release(block)
        Expect.equal(block.rc, 1)
        Expect.equal(buffer.len(block.buf), 3)

        Blocks.release(block)
        Expect.equal(block.rc, 0)
        Expect.equal(buffer.len(block.buf), 0)
        Expect.equal(block.len, 0)

        local again = Blocks.sealed(scratch("xy"), 2, Blocks.REQUEST, 9, nil)
        Expect.holds(again == block, "a released block was not reused")
        Expect.equal(buffer.tostring(again.buf), "xy")
        Expect.equal(again.class, Blocks.REQUEST)
        Expect.equal(again.rc, 1)
    end),

    -- A drained list releases every block and comes back empty. The classes drain in order.
    Harness.case("blocks.drain-and-classes", function()
        local held = {
            Blocks.sealed(scratch("a"), 1, Blocks.PACKET, 0, nil),
            Blocks.sealed(scratch("b"), 1, Blocks.PACKET, 1, nil),
        }
        local kept = held[2]
        Blocks.retain(kept)
        Blocks.drain(held)
        Expect.equal(#held, 0)
        Expect.equal(kept.rc, 1)
        Expect.equal(buffer.tostring(kept.buf), "b")

        Expect.equal(
            { Blocks.RESPONSE, Blocks.REQUEST, Blocks.PACKET, Blocks.ESTABLISH, Blocks.DELTA },
            { 1, 2, 3, 4, 5 }
        )
        Expect.equal(Blocks.CLASSES, 5)
        Expect.equal(Blocks.LOOSE, 0)
    end),
}
