--!strict
--!optimize 2
-- The lowering alone: the node each declaration becomes, and the paths its refusals read as.

local Base = require("@src/codec/Base")
local Codecs = require("@src/codec")
local Lower = require("@src/shape/Lower")
local Protocol = require("@src/wire/Protocol")
local Serial = require("@src/shape/Serial")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local NARROW = 15
local WIDE = 2 ^ (Protocol.BIT_CEILING + 6)
local ROOT = "root"

local function site(): Lower.Site
    return { paths = Serial.interner(), expected = Serial.interner() }
end

local function lowered(of: any, at: string?): (any, Lower.Site)
    local held = site()
    return Lower.of(Base.cell(of), at or ROOT, held), held
end

local function ops(shapes: { any }): string
    local out = {}
    for _, shape in shapes do
        table.insert(out, shape.op)
    end
    return table.concat(out, " ")
end

return {
    -- The kinds with one leaf narrow enough to flow become a one-join word, a wide one whole bytes.
    Harness.case("lower.leaves", function()
        local word = lowered(Codecs.int(0, NARROW))
        Expect.equal(word.op, "word")
        Expect.equal(#word.leaves, 1)
        Expect.equal(#word.joins, 1)
        Expect.equal(word.bits, 4)
        Expect.equal(word.joins[1].pull, nil)

        local wide = lowered(Codecs.int(0, WIDE))
        Expect.equal(wide.op, "wide")
        Expect.equal(wide.grid.width, Protocol.BIT_CEILING + 7)

        Expect.equal(lowered(Codecs.empty()).op, "none")
        Expect.equal(lowered(Codecs.f32()).op, "f32")
        Expect.equal(lowered(Codecs.f64()).op, "f64")
        Expect.equal(lowered(Codecs.vlq()).op, "vlq")
        Expect.equal(lowered(Codecs.vli()).op, "vli")
        Expect.equal(lowered(Codecs.inst("Part")).class, "Part")
        Expect.equal(lowered(Codecs.buffer(0, 4)).form, "buffer")
        Expect.equal(lowered(Codecs.str.alphabet("ab", 0, 4)).alphabet, "ab")
    end),

    -- A run where the element is one leaf that fits, a list otherwise, and pairs for a map.
    Harness.case("lower.collections", function()
        local run = lowered(Codecs.array(Codecs.int(0, NARROW), 0, 8))
        Expect.equal(run.op, "run")
        Expect.equal(run.elem.width, 4)
        Expect.equal(run.count.max, 8)

        local list = lowered(Codecs.array(Codecs.str(0, 4), 0, 8))
        Expect.equal(list.op, "list")
        Expect.equal(list.elem.op, "bytes")

        local wideList = lowered(Codecs.array(Codecs.int(0, WIDE), 1, 1))
        Expect.equal(wideList.op, "list")
        Expect.equal(wideList.elem.op, "wide")

        local pairs = lowered(Codecs.map(Codecs.int(0, NARROW), Codecs.str(0, 4), 0, 8))
        Expect.equal(pairs.op, "pairs")
        Expect.equal(pairs.key.op, "word")
        Expect.equal(pairs.value.op, "bytes")
        Expect.holds(pairs.keyed ~= nil, "a one-leaf key did not pack as a run")
    end),

    -- An optional on its own gets a region for its bit, both halves nameless.
    Harness.case("lower.lone-optional", function()
        local group = lowered(Codecs.optional(Codecs.str(0, 4)))
        Expect.equal(group.op, "group")
        Expect.equal(group.word.bits, 1)
        Expect.equal(group.word.joins[1].key, nil)
        Expect.equal(#group.parts, 1)
        Expect.equal(group.parts[1].key, nil)
        Expect.equal(group.parts[1].of.op, "opt")
        Expect.equal(group.parts[1].of.bit, 1)
        Expect.equal(group.parts[1].of.inner.op, "bytes")
    end),

    -- A record's four regions: presence bits first, packed fields, then byte parts, then the tail.
    Harness.case("lower.record", function()
        local group = lowered(Codecs.struct({
            flag = Codecs.bool(),
            wide = Codecs.int(0, WIDE),
            text = Codecs.str(0, 4),
            maybe = Codecs.optional(Codecs.bool()),
            narrow = Codecs.int(0, NARROW),
        }))
        Expect.equal(group.op, "group")
        Expect.equal(group.word.bits, 1 + 3 + 1 + 4)
        Expect.equal(group.word.joins[1].key, "maybe")
        Expect.equal(group.word.joins[1].pull ~= nil, true)
        Expect.equal(group.word.joins[2].key, "text")
        Expect.equal(group.word.joins[2].pull ~= nil, true)
        Expect.equal(group.word.joins[3].key, "flag")
        Expect.equal(group.word.joins[4].key, "narrow")

        Expect.equal(#group.parts, 3)
        Expect.equal(group.parts[1].key, "wide")
        Expect.equal(group.parts[1].of.op, "wide")
        Expect.equal(group.parts[2].key, "maybe")
        Expect.equal(group.parts[2].of.op, "opt")
        Expect.equal(group.parts[2].of.bit, 1)
        Expect.equal(group.parts[3].key, "text")
        Expect.equal(group.parts[3].of.op, "bytes")
        Expect.equal(group.parts[3].hoist, group.parts[3].of.hoist)
        Expect.equal(group.parts[3].hoist.leaf, 2)
        Expect.equal(group.parts[3].of.maxBytes, 4)

        Expect.equal(
            group.allow,
            { flag = true, wide = true, text = true, maybe = true, narrow = true }
        )
        Expect.equal(#group.nests, 0)
    end),

    -- A fixed inner record dissolves: its fields join the outer region under a nest that names it.
    Harness.case("lower.dissolved-record", function()
        local group = lowered(Codecs.struct({
            a = Codecs.bool(),
            inner = Codecs.struct({
                b = Codecs.bool(),
                deep = Codecs.struct({ c = Codecs.bool() }),
            }),
        }))
        Expect.equal(#group.nests, 2)
        Expect.equal(group.nests[1].key, "inner")
        Expect.equal(group.nests[1].under, nil)
        Expect.equal(group.nests[1].allow, { b = true, deep = true })
        Expect.equal(group.nests[2].key, "deep")
        Expect.equal(group.nests[2].under, 1)
        Expect.equal(group.nests[2].allow, { c = true })
        Expect.equal(group.allow, { a = true, inner = true })

        local joins = group.word.joins
        Expect.equal(joins[1].key, "a")
        Expect.equal(joins[1].nest, nil)
        Expect.equal(joins[2].key, "b")
        Expect.equal(joins[2].nest, 1)
        Expect.equal(joins[3].key, "c")
        Expect.equal(joins[3].nest, 2)
    end),

    -- A tagged union is a branch over sorted names, each arm allowed to carry the tag field.
    Harness.case("lower.tagged", function()
        local branch = lowered(Codecs.tagged("kind", {
            b = Codecs.struct({ y = Codecs.bool() }),
            a = Codecs.struct({ x = Codecs.bool() }),
        }))
        Expect.equal(branch.op, "branch")
        Expect.equal(branch.field, "kind")
        Expect.equal(branch.names, { "a", "b" })
        Expect.equal(branch.tagWidth, 1)
        Expect.equal(branch.arms[1].allow, { x = true, kind = true })
        Expect.equal(branch.arms[2].allow, { y = true, kind = true })
    end),

    -- A vector of floats comes apart into floats and is rebuilt as the engine's value.
    Harness.case("lower.apart", function()
        local vec = lowered(Codecs.vec3())
        Expect.equal(vec.op, "apart")
        Expect.equal(vec.engine, "Vector3")
        Expect.equal(vec.keys, { "X", "Y", "Z" })
        Expect.equal(ops(vec.parts), "f32 f32 f32")
        Expect.equal(vec.push({ 1, 2, 3 }), Vector3.new(1, 2, 3))

        local flat = lowered(Codecs.vec2(Codecs.vlq()))
        Expect.equal(ops(flat.parts), "vlq vlq")
        Expect.equal(flat.push({ 4, 5 }), Vector2.new(4, 5))

        local colour = lowered(Codecs.color3())
        Expect.equal(colour.engine, "Color3")
        Expect.equal(colour.push({ 1, 0, 0 }), Color3.new(1, 0, 0))

        local frame = lowered(Codecs.cframe(Codecs.vec3(), Codecs.rotation.quat(5)))
        Expect.equal(frame.engine, "CFrame")
        Expect.equal(frame.keys, { "Position", "Rotation" })
        Expect.equal(ops(frame.parts), "apart word")
        Expect.equal(
            frame.push({ Vector3.new(1, 2, 3), CFrame.identity }).Position,
            Vector3.new(1, 2, 3)
        )

        -- A vector of narrow components is a fold, so it packs as one word.
        Expect.equal(lowered(Codecs.vec3(Codecs.int(0, NARROW))).op, "word")
    end),

    -- A transform wraps the node its declaration lowers to, and checks ride on the outer tag.
    Harness.case("lower.transform-and-checks", function()
        local check = function()
            return nil
        end
        local plain = lowered(Codecs.int(0, NARROW):validate(check))
        Expect.equal(plain.tag.checks, { check })

        local xform = lowered(Codecs.int(0, NARROW):validate(check):as(tostring, tonumber :: any))
        Expect.equal(xform.op, "xform")
        Expect.equal(xform.inner.op, "word")
        Expect.equal(xform.inner.tag.checks, nil)
        Expect.holds(xform.tag.checks ~= nil, "the checks left the transform's tag")
        Expect.equal(xform.lift(5), "5")
    end),

    -- Every node's path is interned from the root through the names that reach it.
    Harness.case("lower.paths", function()
        local group, held = lowered(Codecs.struct({
            list = Codecs.array(Codecs.str(0, 4), 0, 2),
            inner = Codecs.struct({ deep = Codecs.optional(Codecs.f32()) }),
        }))
        local paths = held.paths.texts
        local found = {}
        for _, text in paths do
            found[text] = true
        end
        for _, want in
            {
                ROOT,
                "root.list",
                "root.list.element",
                "root.inner",
                "root.inner.deep",
                "root.inner.deep.inner",
            }
        do
            Expect.holds(found[want] == true, `no node was interned at {want}`)
        end
        Expect.equal(
            held.expected.texts[group.tag.expectId],
            Serial.describe({ cell = Base.cell(Codecs.struct({})) }):sub(1, 8)
        )
    end),
}
