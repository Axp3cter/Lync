--!strict
--!optimize 2
-- The word planner alone: the windows a run of bit fields is cut into, and where each field sits.

local Protocol = require("@src/wire/Protocol")
local Words = require("@src/shape/Words")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

local CEILING = Protocol.BIT_CEILING
local PRESENCE = Protocol.MAX_FIELDS

-- How far the run sweep counts, past six of the widest window and a tail.
local REACH = 200
local MOST = 12

-- The narrowest widths and those at or beside a window edge, where the split is decided.
local NOTABLE = table.freeze({ 1, 2, 7, 8, 9, 15, 16, 17, CEILING })

-- A field is at most three bytes and nothing follows the single-byte window, so a field can start
-- inside one window, cover a whole one, and end inside the last.
local MOST_PARTS = 3

local function filling(bits: number): { number }
    return table.create(bits, 1)
end

local function sizes(plan: { Words.Word }): { number }
    local out = table.create(#plan) :: { number }
    for _, word in plan do
        table.insert(out, word.bytes)
    end
    return out
end

local function drawn(rng: Rng.Rng): { number }
    local count = rng:int(0, MOST)
    local out = table.create(count) :: { number }
    for _ = 1, count do
        table.insert(out, if rng:bool() then rng:pick(NOTABLE) else rng:int(1, CEILING))
    end
    return out
end

return {
    -- Widest first while the run has room for it, then the next, and a single byte for the rest.
    Harness.case("words.sequence", function()
        for _, cut in
            {
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
        do
            Expect.equal(sizes(Words.plan(filling(cut.bits))), cut.into)
        end
    end),

    -- The windows follow with no gap, take exactly the bytes the bits need, and leave at most
    -- seven over as the align, at every length up to three whole words.
    Harness.case("words.run", function()
        for bits = 0, REACH do
            local plan = Words.plan(filling(bits))
            local at = 0
            for _, word in plan do
                if word.at ~= at then
                    Expect.holds(false, `{bits} bits put a window at {word.at}`)
                end
                at += word.bytes
            end
            local wanted = math.ceil(bits / 8)
            if at ~= wanted then
                Expect.holds(false, `{bits} bits took {at} bytes, not {wanted}`)
            end
            local align = at * 8 - bits
            if align > 7 then Expect.holds(false, `{bits} bits left {align} align bits`) end
        end
    end),

    -- Sixty four presence bits fall into two whole words carrying a bit at every offset.
    Harness.case("words.presence", function()
        local plan = Words.plan(filling(PRESENCE))
        Expect.equal(sizes(plan), { 4, 4 })
        for index, word in plan do
            Expect.equal(word.at, (index - 1) * 4)
            Expect.equal(#word.parts, 32)
            for offset, part in word.parts do
                Expect.equal(part.field, (index - 1) * 32 + offset)
                Expect.equal(part.offset, offset - 1)
                Expect.equal(part.width, 1)
                Expect.equal(part.shift, 0)
            end
        end
    end),

    -- Two fields whole, a third filling the window and carrying three bits over, a fourth whole in
    -- the next.
    Harness.case("words.parts", function()
        local plan = Words.plan({ 3, 12, 20, 9 })
        Expect.equal(sizes(plan), { 4, 2 })
        Expect.equal(plan[1].at, 0)
        Expect.equal(plan[1].parts, {
            { field = 1, offset = 0, width = 3, shift = 0 },
            { field = 2, offset = 3, width = 12, shift = 0 },
            { field = 3, offset = 15, width = 17, shift = 0 },
        })
        Expect.equal(plan[2].at, 4)
        Expect.equal(plan[2].parts, {
            { field = 3, offset = 0, width = 3, shift = 17 },
            { field = 4, offset = 3, width = 9, shift = 0 },
        })
    end),

    -- A part is cut at a window and never at a byte, and a field can reach across three windows.
    Harness.case("words.thrice", function()
        local across = Words.plan({ 15, 10 })
        Expect.equal(sizes(across), { 4 })
        Expect.equal(across[1].parts[2], { field = 2, offset = 15, width = 10, shift = 0 })

        local wider = Words.plan({ 31, 18, 7 })
        Expect.equal(sizes(wider), { 4, 2, 1 })
        Expect.equal(wider[1].parts[2], { field = 2, offset = 31, width = 1, shift = 0 })
        Expect.equal(wider[2].parts[1], { field = 2, offset = 0, width = 16, shift = 1 })
        Expect.equal(wider[3].parts[1], { field = 2, offset = 0, width = 1, shift = 17 })
    end),

    -- A field of no bits takes no room, produces no part, and does not move the fields after it.
    -- Where cutting and fitting spend the same bytes, the plan that cuts nothing wins: three
    -- fields of six bits take three bytes either way, and each stays in one piece.
    Harness.case("words.tie-cuts-nothing", function()
        local plan = Words.plan({ 6, 6, 6 })
        Expect.equal(#plan, 2)
        Expect.equal(plan[1].bytes + plan[2].bytes, 3)
        local pieces = 0
        for _, window in plan do
            for _, part in window.parts do
                pieces += 1
                Expect.equal(part.shift, 0)
                Expect.equal(part.width, 6)
            end
        end
        Expect.equal(pieces, 3)
    end),

    Harness.case("words.empty-field", function()
        local plan = Words.plan({ 4, 0, 4 })
        Expect.equal(sizes(plan), { 1 })
        Expect.equal(plan[1].parts, {
            { field = 1, offset = 0, width = 4, shift = 0 },
            { field = 3, offset = 4, width = 4, shift = 0 },
        })
        Expect.equal(Words.plan({ 0, 0 }), {})
    end),

    -- Whichever way a plan laid its fields out: every bit placed, every piece inside its window and
    -- knowing its own shift, windows narrowing and taking exactly the bytes the bits need.
    Harness.property("words.places", "leaves", function(rng: Rng.Rng)
        local widths = drawn(rng)
        local plan = Words.plan(widths)

        local total = 0
        for _, width in widths do
            total += width
        end

        local at, previous = 0, math.huge
        for _, word in plan do
            Expect.equal(word.at, at)
            Expect.holds(
                word.bytes == 1 or word.bytes == 2 or word.bytes == 4,
                `{word.bytes} bytes`
            )
            Expect.holds(word.bytes <= previous, `a {word.bytes} byte window after a {previous}`)
            at += word.bytes
            previous = word.bytes
        end
        Expect.equal(at, math.ceil(total / 8))

        local held: { [number]: number } = {}
        local pieces: { [number]: number } = {}
        for _, word in plan do
            for _, part in word.parts do
                local field = part.field
                Expect.holds(
                    part.width > 0
                        and part.offset >= 0
                        and part.offset + part.width <= word.bytes * 8,
                    `a part of {part.width} at {part.offset} in {word.bytes} bytes`
                )
                Expect.equal(part.shift, held[field] or 0)
                held[field] = (held[field] or 0) + part.width
                pieces[field] = (pieces[field] or 0) + 1
            end
        end

        for field, width in widths do
            Expect.equal(held[field], width)
            Expect.holds(
                pieces[field] <= MOST_PARTS,
                `field {field} came apart into {pieces[field]}`
            )
        end
    end),
}
