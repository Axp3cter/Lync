--!strict
--!optimize 2
-- The block headers alone: every form laid down and taken back up, and the bytes each spends.

local Bits = require("@src/kernel/Bits")
local Frames = require("@src/shape/Frames")
local Protocol = require("@src/wire/Protocol")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

-- Where a header is laid, never the front, so an offset assumed to be zero shows.
local AT = 3
local ROOM = 32

-- Definition counts around the byte edges of the id width, and one namespace of one definition.
local COUNTS = table.freeze({ 1, 2, 3, 16, 17, 255, 256, 257, 4096 })

local SEQ_TOP = Protocol.NEWEST_WINDOW * 2 - 1
local STAMP_TOP = 2 ^ Protocol.STAMP_BITS - 1
local ASK_TOP = Protocol.QUERY_CAP * 2 - 1

-- A header written from AT and read back into a table that starts dirty.
local function circles(head: Frames.Head, fields: { number }): { number }
    local b = buffer.create(ROOM)
    buffer.fill(b, 0, 0xFF)
    head.write(b, AT, fields)
    local into = table.create(head.fields, 12345)
    head.read(b, AT, into)
    return into
end

-- Every field at its top and its bottom, which is where a width one bit short shows.
local function corners(head: Frames.Head, tops: { number })
    Expect.equal(head.fields, #tops)
    local low = table.create(#tops, 0)
    Expect.equal(circles(head, low), low)
    Expect.equal(circles(head, tops), tops)
    for index, top in tops do
        local one = table.create(#tops, 0)
        one[index] = top
        Expect.equal(circles(head, one), one)
    end
end

return {
    -- The defId alone spends the bytes its width rounds to, and reads back at every count.
    Harness.case("frames.naming", function()
        for _, count in COUNTS do
            local head = Frames.naming(count)
            Expect.equal(head.bytes, math.ceil(Bits.width(count - 1) / 8))
            Expect.equal(head.runs, nil)
            corners(head, { count - 1 })
        end
        Expect.equal(Frames.naming(1).bytes, 0)
    end),

    -- A running block spends the spare bits of the id's byte on its count, so it costs the same
    -- bytes as the id alone, and the count reaches the whole spare width.
    Harness.case("frames.running", function()
        for _, count in COUNTS do
            local id = Bits.width(count - 1)
            local head = Frames.running(count)
            local spare = 8 - id % 8
            Expect.equal(head.runs, 2 ^ spare)
            Expect.equal(head.bytes, math.ceil((id + spare) / 8))
            corners(head, { count - 1, 2 ^ spare - 1 })
        end
    end),

    Harness.case("frames.stamped-and-newest", function()
        for _, count in { 1, 17, 4096 } do
            corners(Frames.stamped(count), { count - 1, STAMP_TOP })
            corners(Frames.newest(count, false), { count - 1, SEQ_TOP })
            corners(Frames.newest(count, true), { count - 1, STAMP_TOP, SEQ_TOP })
        end
        Expect.equal(Frames.newest(4096, true).bytes, math.ceil((12 + 24 + 16) / 8))

        -- The sequence is sixteen bits exactly: with an eight bit name it fills three bytes, and
        -- with a stamp beside it six, so one bit more in either field costs a byte here.
        Expect.equal(Frames.newest(256, false).bytes, 3)
        Expect.equal(Frames.newest(256, true).bytes, 6)
        Expect.equal(Frames.stamped(256).bytes, 4)
    end),

    Harness.case("frames.asking-and-answering", function()
        corners(Frames.asking(), { ASK_TOP })
        corners(Frames.answering(), { ASK_TOP, 1 })
        Expect.equal(Frames.asking().bytes, 2)
        Expect.equal(Frames.answering().bytes, 3)
    end),

    Harness.case("frames.section-stream-follow", function()
        for _, count in { 1, 17 } do
            corners(Frames.section(count), { count - 1, Protocol.SECTION_CLEAR })
            for _, fields in { 1, 2, 9, Protocol.MAX_FIELDS } do
                corners(
                    Frames.stream(count, fields),
                    { count - 1, fields - 1, fields - 1, SEQ_TOP }
                )
                corners(Frames.follow(fields), { fields - 1, SEQ_TOP })
            end
        end
    end),

    -- A read clears every field first, and a block is the header plus its payload.
    Harness.case("frames.read-clears-and-block-sums", function()
        local head = Frames.stream(17, 9)
        local b = buffer.create(ROOM)
        head.write(b, AT, { 0, 0, 0, 0 })
        local into = { 9, 9, 9, 9, 9 }
        head.read(b, AT, into)
        Expect.equal(into, { 0, 0, 0, 0, 9 })
        Expect.equal(Frames.block(head, 100), head.bytes + 100)
    end),

    -- Every head, every field drawn across its width, out and back.
    Harness.property("frames.round-trips", "leaves", function(rng: Rng.Rng)
        local count = rng:int(1, 4096)
        local fields = rng:int(1, Protocol.MAX_FIELDS)
        local stamped = rng:bool()
        local running = Frames.running(count)
        local heads: { { head: Frames.Head, tops: { number } } } = {
            { head = Frames.naming(count), tops = { count - 1 } },
            { head = running, tops = { count - 1, running.runs :: number - 1 } },
            { head = Frames.stamped(count), tops = { count - 1, STAMP_TOP } },
            {
                head = Frames.newest(count, stamped),
                tops = if stamped
                    then { count - 1, STAMP_TOP, SEQ_TOP }
                    else { count - 1, SEQ_TOP },
            },
            { head = Frames.asking(), tops = { ASK_TOP } },
            { head = Frames.answering(), tops = { ASK_TOP, 1 } },
            { head = Frames.section(count), tops = { count - 1, Protocol.SECTION_CLEAR } },
            {
                head = Frames.stream(count, fields),
                tops = { count - 1, fields - 1, fields - 1, SEQ_TOP },
            },
            { head = Frames.follow(fields), tops = { fields - 1, SEQ_TOP } },
        }
        for _, one in heads do
            local drawn: { number } = table.create(#one.tops, 0)
            for index, top in one.tops do
                drawn[index] = rng:int(0, top)
            end
            Expect.equal(circles(one.head, drawn), drawn)
        end
    end),
}
