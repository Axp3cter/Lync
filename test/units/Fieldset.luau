--!strict
--!optimize 2
--[[
    Which fields a delta section carries, as the two forms it says that in and the bytes of each.
]]

local Bytes = require ("@src/wire/Bytes")
local Catalog = require ("@src/kernel/Catalog")
local Fieldset = require ("@src/state/Fieldset")
local Protocol = require ("@src/wire/Protocol")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

const LIST = Protocol.FIELDSET_LIST
const MASK = Protocol.FIELDSET_MASK

const BROKEN = Catalog.SECTION
const BYTE = 8

--[[
    Field counts a case lays a set at. One is the set that costs nothing but its flag, two is the
    first that has a choice to make, and sixty four is the count the two forms cross over inside.
    The rest are the awkward ones: a power of two, one past it, and one under.
]]
const COUNTS = table.freeze ({ 1, 2, 3, 7, 8, 9, 16, 17, 64 })

-- The set a case walks every subset of, which is thirty one of them.
const EVERY = 5

-- How much room a case building bytes by hand gives itself, which is more than any fieldset here.
const ROOM = 32

-- Types ---------------------------------------------------------------

type Bits = { mode: number, fields: { number }, full: { number } }

-- Private -------------------------------------------------------------

-- A selection as the record the pair reads and fills, with the arrays no longer than the count.
local function chosen (fields: { number }, full: { number }): Fieldset.Chosen
    return { mode = 0, count = #fields, fields = fields, full = full }
end

--[[
    One fieldset written and taken straight back up, answering what came back and how many bytes it
    took. Both ends are asked for the same byte, since a reader that stopped somewhere else would
    read every field of the section after it at the wrong offset.
]]
local function through (
    of: Fieldset.Fieldset,
    fields: { number },
    full: { number }
): (Fieldset.Chosen, number)
    local b = buffer.create (of.widest)
    local laid = chosen (fields, full)

    local wrote = of.write (b, 0, laid)
    local back = chosen ({}, {})
    local read = of.read (b, 0, back)

    Expect.equal (read, wrote)
    Expect.equal (back.mode, laid.mode)
    return back, wrote
end

-- What came back held against what went in, field for field and flag for flag, to the count.
local function same (back: Fieldset.Chosen, fields: { number }, full: { number })
    Expect.equal (back.count, #fields)
    for index = 1, #fields do
        Expect.equal (back.fields[index], fields[index])
        Expect.equal (back.full[index], full[index])
    end
end

-- An ascending selection of `count` of the `over` fields, drawn without repeats.
local function picked (rng: Rng.Rng, over: number, count: number): { number }
    local pool = {}
    for field = 1, over do
        pool[field] = field
    end

    Rng.shuffle (rng, pool)
    local out = table.move (pool, 1, count, 1, {})
    table.sort (out)
    return out
end

-- A coverage flag per selected field, each of them a truth the wire carries as one bit.
local function covered (rng: Rng.Rng, count: number): { number }
    local out = {}
    for index = 1, count do
        out[index] = if Rng.bool (rng) then 1 else 0
    end
    return out
end

--[[
    A fieldset composed by hand, which is how a case reaches bytes no encoder would have written.
    The pad is put in above the last flag rather than left there, because a byte is cleared by
    whoever first writes at its bottom bit and every bit here is written from that bit up.
]]
local function forged (of: Fieldset.Fieldset, said: Bits, pad: boolean): buffer
    local b = buffer.create (ROOM)
    local at = Bytes.put (b, 0, 1, said.mode)

    if said.mode == LIST then
        at = Bytes.put (b, at, of.width, #said.fields - 1)
        for _, field in said.fields do
            at = Bytes.put (b, at, of.width, field - 1)
        end
    else
        local holds: { [number]: boolean } = {}
        for _, field in said.fields do
            holds[field] = true
        end
        for field = 1, of.over do
            at = Bytes.put (b, at, 1, if holds[field] then 1 else 0)
        end
    end

    for _, flag in said.full do
        at = Bytes.put (b, at, 1, flag)
    end

    if pad then Bytes.put (b, at, 1, 1) end
    return b
end

-- The code a read raised, and the words under it, or nothing where the read came back.
local function refused (of: Fieldset.Fieldset, b: buffer): (string?, string?)
    local ok, why = pcall (of.read, b, 0, chosen ({}, {}))
    if ok or type (why) ~= "table" then return nil, nil end

    local held = why :: { code: string, facts: { said: string } }
    return held.code, held.facts.said
end

-- Public --------------------------------------------------------------

return {
    --[[
        What a compiled fieldset says about itself. The field count is the caller's, the width is
        what one index costs, and the widest is what the whole thing can come to. A caller sizing a
        scratch or cutting a section at a bound reads the last of those and cannot work it out from
        the count alone, since which of the two forms wins is the module's own arithmetic.
    ]]
    Harness.case ("fieldset.shape", function ()
        local single = Fieldset.of (1)
        Expect.equal (single.over, 1)
        Expect.equal (single.width, 0)
        Expect.equal (single.widest, 1)

        for _, over in COUNTS do
            local of = Fieldset.of (over)
            Expect.equal (of.over, over)
            Expect.holds (of.widest >= 1, `a set of {over} fields has a fieldset of no bytes`)
        end
    end),

    --[[
        The widest is a bound and not an estimate. Every count a set can make is written and
        measured, and none of them comes to more, which is the promise a caller cutting a section at
        a bound is holding. The buffer is exactly that many bytes, so a write past it raises here
        rather than answering a number that is quietly wrong.
    ]]
    Harness.case ("fieldset.widest-bounds-every-write", function ()
        for _, over in COUNTS do
            local of = Fieldset.of (over)

            for count = 1, over do
                local fields, full = {}, {}
                for index = 1, count do
                    fields[index] = index
                    full[index] = index % 2
                end

                local _, wrote = through (of, fields, full)
                Expect.holds (wrote <= of.widest, `{count} of {over} came to {wrote} bytes`)
            end
        end
    end),

    --[[
        Which form is used, as the count rises. The list wins while the indices cost less than a bit
        a field, the mask wins after, and the crossing happens once: a mode that flipped twice would
        be arithmetic nobody could size a section against.
    ]]
    Harness.case ("fieldset.mode-crossover", function ()
        for _, over in COUNTS do
            local of = Fieldset.of (over)
            local flips = 0
            local was = LIST

            for count = 1, over do
                local fields, full = {}, {}
                for index = 1, count do
                    fields[index], full[index] = index, 0
                end

                local b = buffer.create (of.widest)
                local laid = chosen (fields, full)
                of.write (b, 0, laid)

                if laid.mode ~= was then
                    flips += 1
                    was = laid.mode
                end
            end
            Expect.holds (flips <= 1, `a set of {over} fields changed form {flips} times`)
        end
    end),

    --[[
        Where the crossing is for a set of sixty four fields, which is the widest a record may be.
        An index costs six bits there, so the list wins through nine changed fields and the mask
        wins from ten, and that number is the whole reason the mode bit is worth its bit.
    ]]
    Harness.case ("fieldset.mode-crosses-at-ten", function ()
        local of = Fieldset.of (64)

        for _, at in { { 9, LIST }, { 10, MASK } } do
            local count, wanted = at[1], at[2]

            local fields, full = {}, {}
            for index = 1, count do
                fields[index], full[index] = index, 1
            end

            local laid = chosen (fields, full)
            of.write (buffer.create (of.widest), 0, laid)
            Expect.equal (laid.mode, wanted)
        end
    end),

    --[[
        Every selection a small set can make, both forms reached along the way. Thirty one subsets
        of five fields, each with the coverage flags that follow from its own indices, so a fieldset
        that read one field right and the next one wrong is caught by the subset that holds both.
    ]]
    Harness.case ("fieldset.every-subset", function ()
        local of = Fieldset.of (EVERY)

        for held = 1, 2 ^ EVERY - 1 do
            local fields, full = {}, {}
            for field = 1, EVERY do
                if bit32.extract (held, field - 1, 1) == 0 then continue end

                table.insert (fields, field)
                table.insert (full, field % 2)
            end

            local back = through (of, fields, full)
            same (back, fields, full)
        end
    end),

    --[[
        A set of one field spends nothing on saying which, so what a fieldset comes to there is
        the mode bit and the one coverage flag: two bits, which is one byte.
    ]]
    Harness.case ("fieldset.one-field", function ()
        local of = Fieldset.of (1)

        for _, flag in { 0, 1 } do
            local back, wrote = through (of, { 1 }, { flag })
            Expect.equal (wrote, 1)
            same (back, { 1 }, { flag })
        end
    end),

    --[[
        A drawn selection of a drawn set, out and back. The fields come back in the order they went
        in and each flag comes back beside the field it belongs to, which is the pairing a section
        reads its columns against.
    ]]
    Harness.property ("fieldset.round-trip", "leaves", function (rng: Rng.Rng)
        local over = Rng.pick (rng, COUNTS)
        local of = Fieldset.of (over)

        local count = Rng.int (rng, 1, over)
        local fields = picked (rng, over, count)
        local full = covered (rng, count)

        local back = through (of, fields, full)
        same (back, fields, full)
    end),

    --[[
        The mode is answered rather than asked. A caller has nothing to decide about which form is
        smaller, so the encoder writes it into the record on the way out and the reader writes back
        what it found, which is what lets whoever is measuring a flush say what it came to.
    ]]
    Harness.property ("fieldset.mode-answered", "leaves", function (rng: Rng.Rng)
        local over = Rng.pick (rng, COUNTS)
        local of = Fieldset.of (over)

        local count = Rng.int (rng, 1, over)
        local fields = picked (rng, over, count)
        local full = covered (rng, count)

        local laid = chosen (fields, full)
        local b = buffer.create (of.widest)
        of.write (b, 0, laid)
        Expect.holds (laid.mode == LIST or laid.mode == MASK, `a fieldset wrote mode {laid.mode}`)

        local back = chosen ({}, {})
        of.read (b, 0, back)
        Expect.equal (back.mode, laid.mode)
    end),

    --[[
        Everything is read to a count and nothing is cleared, which is the rule every reused array
        in this library is read under. A record still holding a longer selection writes the same
        bytes as one holding exactly what it says, and reading into it leaves what sits past the
        count alone rather than answering it as a field.
    ]]
    Harness.property ("fieldset.past-the-count", "leaves", function (rng: Rng.Rng)
        local over = Rng.pick (rng, COUNTS)
        local of = Fieldset.of (over)

        local count = Rng.int (rng, 1, over)
        local fields = picked (rng, over, count)
        local full = covered (rng, count)

        local clean = buffer.create (of.widest)
        of.write (clean, 0, chosen (fields, full))

        local left = table.clone (fields)
        local flags = table.clone (full)
        for index = count + 1, over do
            left[index], flags[index] = over - (index % over), 1
        end

        local dirty = buffer.create (of.widest)
        local held: Fieldset.Chosen = { mode = 0, count = count, fields = left, full = flags }
        of.write (dirty, 0, held)

        Expect.equal (buffer.tostring (dirty), buffer.tostring (clean))
    end),

    --[[
        A read into a record that already held a longer selection. What comes back is the count and
        the entries under it, and the entries above are the ones that were there, because a reader
        that cleared them would be paying per field for a fact the count already carries.
    ]]
    Harness.case ("fieldset.reads-into-a-used-record", function ()
        local of = Fieldset.of (EVERY)

        local b = buffer.create (of.widest)
        of.write (b, 0, chosen ({ 2, 4 }, { 1, 0 }))

        local back = chosen ({ 9, 9, 9, 9, 9 }, { 7, 7, 7, 7, 7 })
        of.read (b, 0, back)

        same (back, { 2, 4 }, { 1, 0 })
        Expect.equal (back.fields[3], 9)
        Expect.equal (back.full[3], 7)
    end),

    --[[
        A list naming its fields out of order, which no encoder writes and one comparison convicts.
        The reader stops at the first index that is not above the one before it, so what it refuses
        is a fieldset rather than the section around it and nothing after the list is read.
    ]]
    Harness.case ("fieldset.refuses-out-of-order", function ()
        local of = Fieldset.of (EVERY)
        local b = forged (of, { mode = LIST, fields = { 4, 2 }, full = { 1, 1 } }, false)

        local code, said = refused (of, b)
        Expect.equal (code, BROKEN)
        Expect.holds (said ~= nil and string.find (said, "out of order") ~= nil, `it said "{said}"`)
    end),

    --[[
        A list naming one field twice, which the same comparison convicts. A repeat is not above the
        index before it, so it needs no test of its own, and a reader that took it would read one
        column twice and every column after it at the wrong offset.
    ]]
    Harness.case ("fieldset.refuses-a-repeat", function ()
        local of = Fieldset.of (EVERY)
        local b = forged (of, { mode = LIST, fields = { 3, 3 }, full = { 0, 0 } }, false)

        local code, said = refused (of, b)
        Expect.equal (code, BROKEN)
        Expect.holds (said ~= nil and string.find (said, "out of order") ~= nil, `it said "{said}"`)
    end),

    --[[
        A list naming a field the set has not got. A count past the field count needs no test of its
        own either: that many ascending indices inside the count do not exist, so whichever of the
        two the list runs into first is what convicts it.
    ]]
    Harness.case ("fieldset.refuses-a-field-it-has-not-got", function ()
        local of = Fieldset.of (EVERY)
        local b = forged (of, { mode = LIST, fields = { 2, EVERY + 1 }, full = { 1, 1 } }, false)

        local code, said = refused (of, b)
        Expect.equal (code, BROKEN)
        Expect.holds (said ~= nil and string.find (said, "has not got") ~= nil, `it said "{said}"`)
    end),

    --[[
        A mask with no bit set at all, which the list form cannot spell and the mask form can.
        Refused where it is read, since nothing downstream has a field to apply.
    ]]
    Harness.case ("fieldset.refuses-nothing-selected", function ()
        local of = Fieldset.of (EVERY)
        local b = forged (of, { mode = MASK, fields = {}, full = {} }, false)

        local code, said = refused (of, b)
        Expect.equal (code, BROKEN)
        Expect.holds (said ~= nil and string.find (said, "no fields") ~= nil, `it said "{said}"`)
    end),

    --[[
        A bit left standing above the fieldset. The values after it begin on a byte, so the bits
        between the last flag and that byte are the zeros an align is made of, and one of them set
        is a frame this library did not write.
    ]]
    Harness.case ("fieldset.refuses-padding", function ()
        local of = Fieldset.of (EVERY)
        local said: Bits = { mode = MASK, fields = { 3 }, full = { 1 } }

        Expect.holds ((1 + EVERY + 1) % BYTE ~= 0, "the forged fieldset ends on a byte")

        local code, why = refused (of, forged (of, said, true))
        Expect.equal (code, BROKEN)
        Expect.holds (why ~= nil and string.find (why, "above it") ~= nil, `it said "{why}"`)

        -- The same bytes without the bit, so what is being refused is the pad and not the fieldset.
        local back = chosen ({}, {})
        of.read (forged (of, said, false), 0, back)
        same (back, said.fields, said.full)
    end),
}
