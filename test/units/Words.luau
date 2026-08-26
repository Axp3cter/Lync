--!strict
--!optimize 2
--[[
    The word planner alone: the windows a run of bit fields is cut into, and where each field sits.
]]

local Protocol = require ("@src/wire/Protocol")
local Words = require ("@src/shape/Words")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

-- The widest field the bit region carries, which is what bounds a drawn one.
const CEILING = Protocol.BIT_CEILING

-- The presence bits a record at the surface's cap opens with.
const PRESENCE = Protocol.MAX_FIELDS

-- How far the run sweep counts, which is three whole words and a tail.
const REACH = 200

-- Fields a drawn run holds.
const MOST = 12

--[[
    Widths that land a field on or beside a window edge, drawn as often as anywhere between. A width
    drawn uniformly from a range of twenty-four straddles often enough, but the edges are where the
    split is decided.
]]
const NOTABLE = table.freeze ({ 1, 2, 7, 8, 9, 15, 16, 17, CEILING })

--[[
    The windows one field can reach across. A window is at least a byte and a field is at most three
    bytes, so a field can start inside one window, cover a whole one, and end inside a third, and it
    can never cover two whole ones.
]]
const MOST_PARTS = 3

-- Private -------------------------------------------------------------

-- A run of that many presence bits, which is the run every struct opens with.
local function filling (bits: number): { number }
    local out = table.create (bits) :: { number }
    for _ = 1, bits do
        table.insert (out, 1)
    end
    return out
end

-- The byte width of each window, which is the shape of the cut.
local function sizes (plan: { Words.Word }): { number }
    local out = table.create (#plan) :: { number }
    for _, word in plan do
        table.insert (out, word.bytes)
    end
    return out
end

local function drawn (rng: Rng.Rng): { number }
    local count = Rng.int (rng, 0, MOST)
    local out = table.create (count) :: { number }

    for _ = 1, count do
        if Rng.bool (rng) then
            table.insert (out, Rng.pick (rng, NOTABLE))
        else
            table.insert (out, Rng.int (rng, 1, CEILING))
        end
    end
    return out
end

-- Public --------------------------------------------------------------

return {
    --[[
        The cut itself, for the bit counts either side of every window the planner has. Widest first
        while the run has room for it, then the next widest, and a single byte for whatever is left
        over.
    ]]
    Harness.case ("words.sequence", function ()
        local cuts = {
            { bits = 0, into = {} },
            { bits = 1, into = { 1 } },
            { bits = 8, into = { 1 } },
            { bits = 9, into = { 2 } },
            { bits = 16, into = { 2 } },
            { bits = 24, into = { 2, 1 } },
            { bits = 25, into = { 4 } },
            { bits = 32, into = { 4 } },
            { bits = 40, into = { 4, 1 } },
            { bits = 48, into = { 4, 2 } },
            { bits = 56, into = { 4, 2, 1 } },
            { bits = 63, into = { 4, 4 } },
            { bits = 64, into = { 4, 4 } },
            { bits = 96, into = { 4, 4, 4 } },
        }
        for _, cut in cuts do
            Expect.equal (sizes (Words.plan (filling (cut.bits))), cut.into)
        end
    end),

    --[[
        What the cut costs, at every length up to three whole words. The windows follow with no
        gap and no overlap, take exactly the bytes the bits need, and leave at most seven over as
        the align. Every length rather than a chosen few, since a planner that has miscounted does
        it at one width and agrees with itself at both of its neighbours.
    ]]
    Harness.case ("words.run", function ()
        for bits = 0, REACH do
            local plan = Words.plan (filling (bits))

            local at = 0
            for _, word in plan do
                if word.at ~= at then
                    Expect.holds (false, `{bits} bits put a window at {word.at} and not {at}`)
                end
                at += word.bytes
            end

            local wanted = math.ceil (bits / 8)
            if at ~= wanted then
                Expect.holds (false, `{bits} bits took {at} bytes and not {wanted}`)
            end

            local align = at * 8 - bits
            if align > 7 then Expect.holds (false, `{bits} bits left {align} align bits`) end
        end
    end),

    --[[
        A record's presence bits at the width the surface caps one to. Sixty four of them fall into
        two whole words carrying a bit at every offset, which is the commonest run in the system and
        the one a reader takes apart with nothing but a constant extract each.
    ]]
    Harness.case ("words.presence", function ()
        local plan = Words.plan (filling (PRESENCE))
        Expect.equal (sizes (plan), { 4, 4 })

        for index, word in plan do
            Expect.equal (word.at, (index - 1) * 4)
            Expect.equal (#word.parts, 32)

            for offset, part in word.parts do
                Expect.equal (part.field, (index - 1) * 32 + offset)
                Expect.equal (part.offset, offset - 1)
                Expect.equal (part.width, 1)
                Expect.equal (part.shift, 0)
            end
        end
    end),

    --[[
        One run laid out in full: two fields whole in the first window, a third filling it and
        carrying three bits over, a fourth spanning the last two. A part names its field, its place
        in the window, its width and how far up the field it starts, which is all a reader needs.
    ]]
    Harness.case ("words.parts", function ()
        local plan = Words.plan ({ 3, 12, 20, 9 })
        Expect.equal (sizes (plan), { 4, 2 })

        Expect.equal (plan[1].at, 0)
        Expect.equal (plan[1].parts, {
            { field = 1, offset = 0, width = 3, shift = 0 },
            { field = 2, offset = 3, width = 12, shift = 0 },
            { field = 3, offset = 15, width = 17, shift = 0 },
        })

        Expect.equal (plan[2].at, 4)
        Expect.equal (plan[2].parts, {
            { field = 3, offset = 0, width = 3, shift = 17 },
            { field = 4, offset = 3, width = 9, shift = 0 },
        })
    end),

    --[[
        A field across two boundaries, which is three parts rather than the two a field usually
        splits into. Both shapes of it are here: one opening at the top of a two-byte window covers
        the byte after it whole and ends in the byte after that, and one opening at the top of a
        four-byte window does the same over the two that follow.
    ]]
    Harness.case ("words.thrice", function ()
        local across = Words.plan ({ 15, 10 })
        Expect.equal (sizes (across), { 4 })
        Expect.equal (across[1].parts[2], { field = 2, offset = 15, width = 10, shift = 0 })

        local wider = Words.plan ({ 31, 18, 7 })
        Expect.equal (sizes (wider), { 4, 2, 1 })
        Expect.equal (wider[1].parts[2], { field = 2, offset = 31, width = 1, shift = 0 })
        Expect.equal (wider[2].parts[1], { field = 2, offset = 0, width = 16, shift = 1 })
        Expect.equal (wider[3].parts[1], { field = 2, offset = 0, width = 1, shift = 17 })
    end),

    --[[
        A field of no bits at all, which a ranged int over a single value is. It takes no room,
        produces no part, and does not move the fields after it. Nothing else here reaches one:
        every run above is drawn or filled from widths of at least one, so a planner emitting an
        empty part or losing count of the field after it would pass the whole file.
    ]]
    Harness.case ("words.empty-field", function ()
        local plan = Words.plan ({ 4, 0, 4 })
        Expect.equal (sizes (plan), { 1 })
        Expect.equal (plan[1].parts, {
            { field = 1, offset = 0, width = 4, shift = 0 },
            { field = 3, offset = 4, width = 4, shift = 0 },
        })

        -- A run of nothing but those is no run at all.
        Expect.equal (Words.plan ({ 0, 0 }), {})
    end),

    --[[
    Every run, against what a plan owes whichever way it laid its fields out. A field sits where the
    windowing put it rather than where its declaration alone would, since one that fits a window
    goes ahead of one that would be cut across it. What is left is what either laying owes: every
    bit placed, every piece knowing how far up its field it starts and staying inside its window.
]]
    Harness.property ("words.places", "leaves", function (rng: Rng.Rng)
        local widths = drawn (rng)
        local plan = Words.plan (widths)

        local total = 0
        for _, width in widths do
            total += width
        end

        local at, previous = 0, math.huge
        for _, word in plan do
            Expect.equal (word.at, at)
            Expect.holds (
                word.bytes == 1 or word.bytes == 2 or word.bytes == 4,
                `a window of {word.bytes} bytes`
            )
            Expect.holds (word.bytes <= previous, `a {word.bytes} byte window after a {previous}`)

            at += word.bytes
            previous = word.bytes
        end
        Expect.equal (at, math.ceil (total / 8))

        local held: { [number]: number } = {}
        local pieces: { [number]: number } = {}
        for _, word in plan do
            for _, part in word.parts do
                local field = part.field
                Expect.holds (
                    part.width > 0
                        and part.offset >= 0
                        and part.offset + part.width <= word.bytes * 8,
                    `a part of {part.width} at {part.offset} in {word.bytes} bytes`
                )

                Expect.equal (part.shift, held[field] or 0)

                held[field] = (held[field] or 0) + part.width
                pieces[field] = (pieces[field] or 0) + 1
            end
        end

        for field, width in widths do
            Expect.equal (held[field], width)
            Expect.holds (
                pieces[field] <= MOST_PARTS,
                `field {field} came apart into {pieces[field]} pieces`
            )
        end
    end),
}
