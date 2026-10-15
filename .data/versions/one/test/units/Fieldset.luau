--!strict
--!optimize 2
-- Which fields a delta section carries, as the two forms it says that in and the bytes of each.

local Bytes = require("@src/wire/Bytes")
local Catalog = require("@src/kernel/Catalog")
local Fieldset = require("@src/state/Fieldset")
local Protocol = require("@src/wire/Protocol")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

local LIST = Protocol.FIELDSET_LIST
local MASK = Protocol.FIELDSET_MASK
local BYTE = 8

-- Field counts a case lays a set at: the one that costs nothing but its flag, the first with a
-- choice to make, the awkward ones around powers of two, and the widest a record may be.
local COUNTS = table.freeze({ 1, 2, 3, 7, 8, 9, 16, 17, 64 })

-- The set a case walks every subset of.
local EVERY = 5
local ROOM = 32

type Bits = { mode: number, fields: { number }, full: { number } }

local function chosen(fields: { number }, full: { number }): Fieldset.Chosen
    return { mode = 0, count = #fields, fields = fields, full = full }
end

-- One fieldset written and taken straight back up, both ends stopping on the same byte.
local function through(
    of: Fieldset.Fieldset,
    fields: { number },
    full: { number }
): (Fieldset.Chosen, number)
    local b = buffer.create(of.widest)
    local laid = chosen(fields, full)
    local wrote = of.write(b, 0, laid)
    local back = chosen({}, {})
    Expect.equal(of.read(b, 0, back), wrote)
    Expect.equal(back.mode, laid.mode)
    return back, wrote
end

local function same(back: Fieldset.Chosen, fields: { number }, full: { number })
    Expect.equal(back.count, #fields)
    for index = 1, #fields do
        Expect.equal(back.fields[index], fields[index])
        Expect.equal(back.full[index], full[index])
    end
end

-- An ascending selection of `count` of the `over` fields, and a coverage flag for each.
local function picked(rng: Rng.Rng, over: number): ({ number }, { number })
    local pool = {}
    for field = 1, over do
        pool[field] = field
    end
    rng:shuffle(pool)
    local count = rng:int(1, over)
    local fields = table.move(pool, 1, count, 1, {})
    table.sort(fields)
    local full = {}
    for index = 1, count do
        full[index] = if rng:bool() then 1 else 0
    end
    return fields, full
end

-- A fieldset composed by hand, which is how a case reaches bytes no encoder would have written.
local function forged(of: Fieldset.Fieldset, said: Bits, pad: boolean): buffer
    local b = buffer.create(ROOM)
    local at = Bytes.put(b, 0, 1, said.mode)
    if said.mode == LIST then
        at = Bytes.put(b, at, of.width, #said.fields - 1)
        for _, field in said.fields do
            at = Bytes.put(b, at, of.width, field - 1)
        end
    else
        for field = 1, of.over do
            at = Bytes.put(b, at, 1, if table.find(said.fields, field) then 1 else 0)
        end
    end
    for _, flag in said.full do
        at = Bytes.put(b, at, 1, flag)
    end
    if pad then Bytes.put(b, at, 1, 1) end
    return b
end

-- The code a read raised and the words under it, or nothing where the read came back.
local function refused(of: Fieldset.Fieldset, b: buffer): (string?, string?)
    local ok, why = pcall(of.read, b, 0, chosen({}, {}))
    if ok or type(why) ~= "table" then return nil, nil end
    return (why :: any).code, (why :: any).facts.said
end

local function refuses(of: Fieldset.Fieldset, b: buffer, phrase: string)
    local code, said = refused(of, b)
    Expect.equal(code, Catalog.SECTION)
    Expect.holds(said ~= nil and string.find(said, phrase, 1, true) ~= nil, `it said "{said}"`)
end

return {
    -- What a compiled fieldset says about itself, and that the widest bounds every write.
    Harness.case("fieldset.shape", function()
        local single = Fieldset.of(1)
        Expect.equal({ single.over, single.width, single.widest }, { 1, 0, 1 })
        for _, over in COUNTS do
            local of = Fieldset.of(over)
            Expect.equal(of.over, over)
            for count = 1, over do
                local fields, full = {}, {}
                for index = 1, count do
                    fields[index], full[index] = index, index % 2
                end
                local _, wrote = through(of, fields, full)
                Expect.holds(wrote <= of.widest, `{count} of {over} came to {wrote} bytes`)
            end
        end
    end),

    -- The list wins while the indices cost less than a bit a field, the mask after, and the form
    -- flips once. At sixty four fields the list wins through nine and the mask from ten.
    Harness.case("fieldset.mode-crossover", function()
        for _, over in COUNTS do
            local of = Fieldset.of(over)
            local flips, was = 0, LIST
            for count = 1, over do
                local fields, full = {}, {}
                for index = 1, count do
                    fields[index], full[index] = index, 0
                end
                local laid = chosen(fields, full)
                of.write(buffer.create(of.widest), 0, laid)
                if laid.mode ~= was then
                    flips += 1
                    was = laid.mode
                end
            end
            Expect.holds(flips <= 1, `a set of {over} fields changed form {flips} times`)
        end

        local wide = Fieldset.of(64)
        for _, at in { { 9, LIST }, { 10, MASK } } do
            local fields, full = {}, {}
            for index = 1, at[1] do
                fields[index], full[index] = index, 1
            end
            local laid = chosen(fields, full)
            wide.write(buffer.create(wide.widest), 0, laid)
            Expect.equal(laid.mode, at[2])
        end
    end),

    -- Every selection a small set can make, both forms reached along the way, and the one-field
    -- set spending one byte on its mode bit and flag.
    Harness.case("fieldset.every-subset", function()
        local of = Fieldset.of(EVERY)
        for held = 1, 2 ^ EVERY - 1 do
            local fields, full = {}, {}
            for field = 1, EVERY do
                if bit32.extract(held, field - 1, 1) == 0 then continue end
                table.insert(fields, field)
                table.insert(full, field % 2)
            end
            same(through(of, fields, full), fields, full)
        end

        local single = Fieldset.of(1)
        for _, flag in { 0, 1 } do
            local back, wrote = through(single, { 1 }, { flag })
            Expect.equal(wrote, 1)
            same(back, { 1 }, { flag })
        end
    end),

    -- A drawn selection of a drawn set out and back, each flag beside the field it belongs to,
    -- and the mode answered into the record on the way out and back.
    Harness.property("fieldset.round-trip", "leaves", function(rng: Rng.Rng)
        local of = Fieldset.of(rng:pick(COUNTS))
        local fields, full = picked(rng, of.over)
        local back = through(of, fields, full)
        same(back, fields, full)
        Expect.holds(back.mode == LIST or back.mode == MASK, `a fieldset wrote mode {back.mode}`)
    end),

    -- Everything is read to a count and nothing is cleared: a record still holding a longer
    -- selection writes the same bytes, and a read into one leaves what sits past the count alone.
    Harness.property("fieldset.past-the-count", "leaves", function(rng: Rng.Rng)
        local of = Fieldset.of(rng:pick(COUNTS))
        local fields, full = picked(rng, of.over)
        local count = #fields
        local clean = buffer.create(of.widest)
        of.write(clean, 0, chosen(fields, full))

        local left, flags = table.clone(fields), table.clone(full)
        for index = count + 1, of.over do
            left[index], flags[index] = of.over - (index % of.over), 1
        end
        local dirty = buffer.create(of.widest)
        of.write(dirty, 0, { mode = 0, count = count, fields = left, full = flags })
        Expect.equal(buffer.tostring(dirty), buffer.tostring(clean))

        local back = chosen(table.create(of.over, 99), table.create(of.over, 7))
        of.read(clean, 0, back)
        same(back, fields, full)
        if count < of.over then
            Expect.equal({ back.fields[count + 1], back.full[count + 1] }, { 99, 7 })
        end
    end),

    -- A fieldset no encoder writes, refused where it is read: out of order, a repeat, a field the
    -- set has not got, nothing selected, and a bit left standing above the last flag.
    Harness.case("fieldset.refuses", function()
        local of = Fieldset.of(EVERY)
        refuses(
            of,
            forged(of, { mode = LIST, fields = { 4, 2 }, full = { 1, 1 } }, false),
            "out of order"
        )
        refuses(
            of,
            forged(of, { mode = LIST, fields = { 3, 3 }, full = { 0, 0 } }, false),
            "out of order"
        )
        local past = { mode = LIST, fields = { 2, EVERY + 1 }, full = { 1, 1 } }
        refuses(of, forged(of, past, false), "has not got")
        refuses(of, forged(of, { mode = MASK, fields = {}, full = {} }, false), "no fields")

        local said: Bits = { mode = MASK, fields = { 3 }, full = { 1 } }
        Expect.holds((1 + EVERY + 1) % BYTE ~= 0, "the forged fieldset ends on a byte")
        refuses(of, forged(of, said, true), "above it")
        local back = chosen({}, {})
        of.read(forged(of, said, false), 0, back)
        same(back, said.fields, said.full)
    end),
}
