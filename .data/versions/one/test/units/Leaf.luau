--!strict
--!optimize 2
-- The leaf emitters: every node that is not a bit region, written and read back through Leaf.

local Base = require("@src/codec/Base")
local Bytes = require("@src/wire/Bytes")
local Catalog = require("@src/kernel/Catalog")
local Codecs = require("@src/codec")
local Ir = require("@src/shape/Ir")
local Leaf = require("@src/shape/emit/Leaf")
local Lower = require("@src/shape/Lower")
local Serial = require("@src/shape/Serial")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

local AT = 3
local ROOM = 256
local WIDEST = 24
local CTX = nil :: any

type Pair = { node: any, write: Ir.Write, read: Ir.Read, side: Ir.Sidecar }

-- A codec lowered to its leaf node and handed to the emitter that node is for.
local function leaf(of: any): Pair
    local site: Lower.Site = { paths = Serial.interner(), expected = Serial.interner() }
    local node: any = Lower.of(Base.cell(of), "root", site)
    local side: Ir.Sidecar = { refs = {}, slotOf = {}, bears = false }
    local paths, expected = site.paths, site.expected
    local write: Ir.Write, read: Ir.Read
    local op = node.op
    if op == "f32" or op == "f64" then
        write, read = Leaf.float(node, paths, expected)
    elseif op == "vlq" or op == "vli" then
        write, read = Leaf.varint(node, paths, expected)
    elseif op == "bytes" then
        write, read = Leaf.bytes(node, paths, expected)
    elseif op == "run" then
        write, read = Leaf.run(node, paths, expected)
    elseif op == "wide" then
        write, read = Leaf.wide(node, paths, expected)
    elseif op == "slot" then
        write, read = Leaf.slot(node, paths, expected, side)
    else
        error(`no leaf emitter for {op}`)
    end
    return { node = node, write = write, read = read, side = side }
end

-- A value written from AT and read back, with the end of the write and the read agreeing.
local function through(of: Pair, value: any): (any, buffer)
    local b = buffer.create(ROOM)
    local after = of.write(b, AT, value)
    local got, back = of.read(b, AT, CTX)
    Expect.equal(got, after)
    return back, b
end

local function rejected(call: () -> ()): Catalog.Code?
    local ok, thrown = pcall(call)
    if ok then return nil end
    return (thrown :: any).code
end

local function refuses(of: Pair, value: any)
    Expect.throws(function()
        of.write(buffer.create(ROOM), AT, value)
    end, "root expected")
end

return {
    -- Every width a run can take, out and back, spending exactly the bytes its bits round to.
    Harness.property("leaf.runs", "leaves", function(rng: Rng.Rng)
        local width = rng:int(1, WIDEST)
        local count = rng:int(0, 40)
        local top = 2 ^ width - 1
        local values = table.create(count, 0)
        for index = 1, count do
            values[index] = rng:int(0, top)
        end
        local b = buffer.create(ROOM)
        local after = Leaf.packed(b, AT, width, count, values)
        Expect.equal(after, AT + Bytes.whole(count * width))
        local into = {}
        local got, clean = Leaf.unpacked(b, AT, width, count, into)
        Expect.equal(got, after)
        Expect.equal(clean, true)
        Expect.equal(into, values)

        -- Bits past the last element are padding, and a pad that is not nothing is not clean.
        if count * width % 8 == 0 then return end
        local last = after - 1
        buffer.writeu8(b, last, bit32.bor(buffer.readu8(b, last), 0x80))
        local _, still = Leaf.unpacked(b, AT, width, count, into)
        Expect.equal(still, false)
    end),

    Harness.case("leaf.float", function()
        local single = leaf(Codecs.f32())
        Expect.equal(single.node.op, "f32")
        Expect.equal(through(single, 1.5), 1.5)
        local double = leaf(Codecs.f64())
        Expect.equal(through(double, math.pi), math.pi)
        Expect.equal(through(double, -0.1), -0.1)
        refuses(single, "1")
        refuses(double, nil)
    end),

    Harness.case("leaf.varint", function()
        local vlq = leaf(Codecs.vlq())
        for _, value in { 0, 127, 300, 2 ^ 40 } do
            Expect.equal(through(vlq, value), value)
        end
        refuses(vlq, -1)
        refuses(vlq, 1.5)
        refuses(vlq, "7")
        local vli = leaf(Codecs.vli())
        for _, value in { 0, -1, -300, 2 ^ 52, -(2 ^ 52) } do
            Expect.equal(through(vli, value), value)
        end
        refuses(vli, 2 ^ 53)

        -- A varint that never ends is the receiver's problem, dropped rather than raised.
        local b = buffer.create(ROOM)
        buffer.fill(b, 0, 0xFF)
        Expect.equal(
            rejected(function()
                vlq.read(b, AT, CTX)
            end),
            Catalog.VARINT
        )
    end),

    Harness.case("leaf.bytes", function()
        local text = leaf(Codecs.str(0, 10))
        Expect.equal(text.node.op, "bytes")
        Expect.equal(through(text, "hello"), "hello")
        Expect.equal(through(text, ""), "")
        refuses(text, "eleven chars")
        local _, b = through(text, "hi")
        buffer.writeu8(b, AT, 11)
        Expect.equal(
            rejected(function()
                text.read(b, AT, CTX)
            end),
            Catalog.COUNT
        )

        local bytes = leaf(Codecs.buffer(2, 4))
        local raw = buffer.fromstring("abc")
        local back = through(bytes, raw)
        Expect.equal(buffer.tostring(back), "abc")
        refuses(bytes, buffer.fromstring("a"))

        -- Over an alphabet the symbols pack at the alphabet's width, and the pad has to be nothing.
        local coded = leaf(Codecs.str.alphabet("abc", 0, 6))
        Expect.equal(through(coded, "cabcab"), "cabcab")
        Expect.equal(through(coded, ""), "")
        refuses(coded, "abd")
        local _, cb = through(coded, "a")
        local symbols = AT + 1
        buffer.writeu8(cb, symbols, 3)
        Expect.equal(
            rejected(function()
                coded.read(cb, AT, CTX)
            end),
            Catalog.TAG
        )
        buffer.writeu8(cb, symbols, 0xF0)
        Expect.equal(
            rejected(function()
                coded.read(cb, AT, CTX)
            end),
            Catalog.PAD
        )
    end),

    Harness.case("leaf.run", function()
        local run = leaf(Codecs.array(Codecs.int(0, 5), 0, 8))
        Expect.equal(run.node.op, "run")
        Expect.equal(through(run, { 5, 0, 3 }), { 5, 0, 3 })
        Expect.equal(through(run, {}), {})
        refuses(run, { 1, 2, 3, 4, 5, 6, 7, 8, 9 })
        refuses(run, { 6 })
        local _, b = through(run, { 5 })
        buffer.writeu8(b, AT + 1, 6)
        Expect.equal(
            rejected(function()
                run.read(b, AT, CTX)
            end),
            Catalog.TAG
        )
        buffer.writeu8(b, AT + 1, 0x80 + 5)
        Expect.equal(
            rejected(function()
                run.read(b, AT, CTX)
            end),
            Catalog.PAD
        )

        -- A grid that fills its bits reads back whole, and a shifted one through its reading.
        local whole = leaf(Codecs.array(Codecs.int(0, 7), 1, 8))
        Expect.equal(through(whole, { 7, 0, 1 }), { 7, 0, 1 })
        local shifted = leaf(Codecs.array(Codecs.int(-4, 3), 0, 8))
        Expect.equal(through(shifted, { -4, 3, 0 }), { -4, 3, 0 })
        local flags = leaf(Codecs.array(Codecs.bool(), 0, 20))
        local many = { true, false, true, true, false, false, true, false, true, true, true }
        Expect.equal(through(flags, many), many)
    end),

    -- A field too wide to pack takes whole bytes, and the bits above its width are padding.
    Harness.case("leaf.wide", function()
        local wide = leaf(Codecs.int(0, 2 ^ 30))
        Expect.equal(wide.node.op, "wide")
        Expect.equal(wide.node.maxBytes, 4)
        Expect.equal(through(wide, 12345), 12345)
        Expect.equal(through(wide, 2 ^ 30), 2 ^ 30)
        refuses(wide, 2 ^ 30 + 1)
        local b = buffer.create(ROOM)
        buffer.writeu32(b, AT, 2 ^ 31)
        Expect.equal(
            rejected(function()
                wide.read(b, AT, CTX)
            end),
            Catalog.PAD
        )
        buffer.writeu32(b, AT, 2 ^ 30 + 1)
        Expect.equal(
            rejected(function()
                wide.read(b, AT, CTX)
            end),
            Catalog.TAG
        )

        local odd = leaf(Codecs.int(0, 2 ^ 40))
        Expect.equal(odd.node.maxBytes, 6)
        Expect.equal(through(odd, 2 ^ 40 - 12345), 2 ^ 40 - 12345)
    end),

    -- An instance rides beside the frame. Nothing is slot zero, and one instance is one slot.
    Harness.case("leaf.slot", function()
        local slot = leaf(Codecs.inst("BasePart"))
        Expect.equal(slot.node.op, "slot")
        Expect.equal(slot.side.bears, true)
        Expect.equal(through(slot, nil), nil)
        local part = Instance.new("Part")
        local b = buffer.create(ROOM)
        slot.write(b, AT, part)
        Expect.equal(buffer.readu8(b, AT), 1)
        slot.write(b, AT, part)
        Expect.equal(#slot.side.refs, 1)
        local _, back = slot.read(b, AT, CTX)
        Expect.equal(back, part)

        -- What arrives in the sidecar is a claim, held to being an instance of the class.
        slot.side.refs[1] = Instance.new("Model") :: any
        Expect.equal(
            rejected(function()
                slot.read(b, AT, CTX)
            end),
            Catalog.SIDECAR
        )
        slot.side.refs[1] = 5 :: any
        Expect.equal(
            rejected(function()
                slot.read(b, AT, CTX)
            end),
            Catalog.SIDECAR
        )
    end),

    Harness.case("leaf.none", function()
        local write, read = Leaf.none()
        local b = buffer.create(ROOM)
        Expect.equal(write(b, AT, "anything"), AT)
        local after, value = read(b, AT, CTX)
        Expect.equal(after, AT)
        Expect.equal(value, nil)
    end),
}
