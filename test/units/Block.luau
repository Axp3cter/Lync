--!strict
--!optimize 2
-- The composite emitters: records, lists, maps, variants, engine values and transforms, driven
-- through a walk that wires Word, Leaf and Block together the way the emitter does.

local Base = require("@src/codec/Base")
local Block = require("@src/shape/emit/Block")
local Catalog = require("@src/kernel/Catalog")
local Codecs = require("@src/codec")
local Ir = require("@src/shape/Ir")
local Leaf = require("@src/shape/emit/Leaf")
local Lower = require("@src/shape/Lower")
local Serial = require("@src/shape/Serial")
local Word = require("@src/shape/emit/Word")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local AT = 2
local ROOM = 512
local CTX = nil :: any

type Pair = { node: any, write: Ir.Write, read: Ir.Read }

local function emit(node: any, site: Lower.Site): (Ir.Write, Ir.Read)
    local paths, expected = site.paths, site.expected
    local op = node.op
    if op == "word" then return emit(Ir.group(node.tag, node, {}), site) end
    if op == "none" then return Leaf.none() end
    if op == "wide" then return Leaf.wide(node, paths, expected) end
    if op == "f32" or op == "f64" then return Leaf.float(node, paths, expected) end
    if op == "vlq" or op == "vli" then return Leaf.varint(node, paths, expected) end
    if op == "bytes" then return Leaf.bytes(node, paths, expected) end
    if op == "run" then return Leaf.run(node, paths, expected) end
    if op == "opt" then return emit(node.inner, site) end
    if op == "xform" then return Block.xform(node, emit(node.inner, site)) end
    if op == "list" then
        local write, read = emit(node.elem, site)
        return Block.list(node, write, read, paths, expected)
    end
    if op == "pairs" then
        local writeKey, readKey = emit(node.key, site)
        local writeValue, readValue = emit(node.value, site)
        return Block.pairs(node, writeKey, readKey, writeValue, readValue, paths, expected)
    end

    local children = if op == "group"
        then node.parts
        elseif op == "branch" then node.arms
        else node.parts
    local writes, reads = {}, {}
    for index, child in children do
        writes[index], reads[index] = emit(if op == "group" then child.of else child, site)
    end
    if op == "group" then
        local pack, unpack, solo
        if node.word ~= nil then
            pack, unpack, solo = Word.emit(node.word, paths, expected)
        end
        return Block.group(node, pack, unpack, solo, writes, reads, paths, expected)
    end
    if op == "branch" then return Block.branch(node, writes, reads, paths, expected) end
    return Block.apart(node, writes, reads, paths, expected)
end

local function built(of: any): Pair
    local site: Lower.Site = { paths = Serial.interner(), expected = Serial.interner() }
    local node: any = Lower.of(Base.cell(of), "root", site)
    local write, read = emit(node, site)
    return { node = node, write = write, read = read }
end

-- A value written from AT and read back, the two ends agreeing.
local function through(of: Pair, value: any): (any, buffer, number)
    local b = buffer.create(ROOM)
    local after = of.write(b, AT, value)
    local got, back = of.read(b, AT, CTX)
    Expect.equal(got, after)
    return back, b, after
end

local function rejected(call: () -> ()): Catalog.Code?
    local ok, why = pcall(call)
    if ok or type(why) ~= "table" then return nil end
    return (why :: any).code
end

local function refuses(of: Pair, value: any, said: string?)
    local thrown = Expect.throws(function()
        of.write(buffer.create(ROOM), AT, value)
    end)
    if said ~= nil then
        Expect.holds(string.find(thrown, said, 1, true) ~= nil, `it said {thrown}`)
    end
end

local RECORD = Codecs.struct({
    hp = Codecs.int(0, 100),
    name = Codecs.str(0, 8),
    tags = Codecs.array(Codecs.bool(), 0, 8),
    maybe = Codecs.optional(Codecs.str(0, 4)),
    inner = Codecs.struct({ near = Codecs.bool(), label = Codecs.str(0, 3) }),
})

return {
    -- A record with a word, parts after it, an option and a dissolved record, out and back.
    Harness.case("block.record", function()
        local of = built(RECORD)
        Expect.equal(of.node.op, "group")
        local full = {
            hp = 42,
            name = "kraken",
            tags = { true, false, true },
            maybe = "yes",
            inner = { near = true, label = "ok" },
        }
        Expect.equal(through(of, full), full)

        -- An absent option comes back absent, not as a key holding nothing.
        local bare = { hp = 0, name = "", tags = {}, inner = { near = false, label = "" } }
        local back = through(of, bare)
        Expect.equal(back, bare)
        Expect.equal(rawget(back, "maybe"), nil)

        -- A record carries the names it declares and no others, at every depth.
        refuses(of, 5)
        local extra = table.clone(full)
        extra.extra = 1
        refuses(of, extra, "extra")
        local deep = table.clone(full)
        deep.inner = { near = true, label = "ok", far = 1 }
        refuses(of, deep, "far")
    end),

    -- A bare word is a value alone through the word's own pair, and an option alone is a keyless
    -- part whose value is the group's own.
    Harness.case("block.alone", function()
        local number = built(Codecs.int(0, 1000))
        Expect.equal(through(number, 777), 777)
        refuses(number, 1001)

        local option = built(Codecs.optional(Codecs.int(0, 7)))
        Expect.equal(option.node.op, "group")
        Expect.equal(through(option, 5), 5)
        local _, _, after = through(option, nil)
        Expect.equal(after, AT + 1)
    end),

    Harness.case("block.list", function()
        local of = built(Codecs.array(Codecs.str(0, 4), 1, 3))
        Expect.equal(of.node.op, "list")
        Expect.equal(through(of, { "a", "", "abcd" }), { "a", "", "abcd" })
        refuses(of, {})
        refuses(of, { "a", "b", "c", "d" })
        local _, b = through(of, { "a" })
        buffer.writeu8(b, AT, 3)
        Expect.equal(
            rejected(function()
                of.read(b, AT, CTX)
            end),
            Catalog.COUNT
        )
    end),

    -- Keys of any shape lie in the order their encoded bytes read in, count first, and a map read
    -- back has to climb.
    Harness.case("block.pairs-by-bytes", function()
        local of = built(Codecs.map(Codecs.str(1, 8), Codecs.str(0, 4), 0, 8))
        Expect.equal(of.node.op, "pairs")
        local value = { b = "one", a = "two", aa = "thr" }
        local back, b = through(of, value)
        Expect.equal(back, value)
        Expect.equal(buffer.readstring(b, AT + 2, 1), "a")
        Expect.equal(buffer.readstring(b, AT + 8, 1), "b")
        Expect.equal(buffer.readstring(b, AT + 14, 2), "aa")
        Expect.equal(through(of, {}), {})

        -- Two keys out of order, then two keys alike, each turned away where it is read.
        buffer.writestring(b, AT + 2, "b")
        Expect.equal(
            rejected(function()
                of.read(b, AT, CTX)
            end),
            Catalog.MAP_ORDER
        )

        -- Fixed narrow keys rank as numbers, fixed wide ones by their leading bytes, and values
        -- on a grid lie as one run after the keys.
        local ranked = built(Codecs.map(Codecs.int(0, 2 ^ 30), Codecs.int(0, 7), 0, 8))
        local numbers = { [5] = 1, [2 ^ 30] = 7, [0] = 3, [300] = 0 }
        Expect.equal(through(ranked, numbers), numbers)
        local reals = built(Codecs.map(Codecs.f64(), Codecs.str(0, 4), 0, 8))
        local mixed = { [1.5] = "a", [-2] = "b", [1e9] = "c" }
        Expect.equal(through(reals, mixed), mixed)
    end),

    -- Keys that are one grid reading sort as indices and lie as one run, and two keys that fall on
    -- the same point are one key twice.
    Harness.case("block.pairs-on-a-grid", function()
        local of = built(Codecs.map(Codecs.int(0, 200), Codecs.str(0, 4), 1, 8))
        local value = { [7] = "x", [3] = "y", [200] = "" }
        local back, b = through(of, value)
        Expect.equal(back, value)
        Expect.equal(buffer.readu8(b, AT + 1), 3)
        Expect.equal(buffer.readu8(b, AT + 2), 7)

        buffer.writeu8(b, AT + 2, 3)
        Expect.equal(
            rejected(function()
                of.read(b, AT, CTX)
            end),
            Catalog.MAP_ORDER
        )
        buffer.writeu8(b, AT + 2, 201)
        Expect.equal(
            rejected(function()
                of.read(b, AT, CTX)
            end),
            Catalog.TAG
        )

        local stepped = built(Codecs.map(Codecs.quant(0, 10, 0.5), Codecs.str(0, 4), 0, 8))
        refuses(stepped, { [1] = "a", [1.1] = "b" }, "a key above")

        local runs = built(Codecs.map(Codecs.int(0, 15), Codecs.int(0, 3), 0, 16))
        local grid = { [1] = 3, [15] = 0, [8] = 2 }
        Expect.equal(through(runs, grid), grid)
    end),

    Harness.case("block.branch", function()
        local of = built(Codecs.tagged("kind", {
            hit = Codecs.struct({ amount = Codecs.int(0, 100) }),
            say = Codecs.struct({ text = Codecs.str(0, 8) }),
        }))
        Expect.equal(of.node.op, "branch")
        Expect.equal(through(of, { kind = "hit", amount = 9 }), { kind = "hit", amount = 9 })
        Expect.equal(through(of, { kind = "say", text = "hi" }), { kind = "say", text = "hi" })
        refuses(of, { kind = "run" })
        local _, b = through(of, { kind = "hit", amount = 1 })
        buffer.writeu8(b, AT, 2)
        Expect.equal(
            rejected(function()
                of.read(b, AT, CTX)
            end),
            Catalog.TAG
        )
    end),

    Harness.case("block.apart", function()
        local of = built(Codecs.vec3())
        Expect.equal(of.node.op, "apart")
        local back = through(of, Vector3.new(1, -2, 3.5))
        Expect.equal(back, Vector3.new(1, -2, 3.5))
        refuses(of, { 1, 2, 3 })
    end),

    Harness.case("block.xform", function()
        local of = built(Codecs.int(0, 100):as(function(wire: number)
            return wire / 100
        end, function(domain: number)
            return domain * 100
        end))
        Expect.equal(of.node.op, "xform")
        Expect.equal(through(of, 0.42), 0.42)
    end),
}
