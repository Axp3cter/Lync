--!strict
--!optimize 2
-- Lync.tagged: discriminated union with u8 variant tag.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.composite.Tagged", function(): ()
    beforeEach(Sandbox.resetAll)

    local function buildBasic(): any
        return Lync.tagged("type", {
            damage = Lync.struct({ amount = Lync.int(0, 255) }),
            heal = Lync.struct({ amount = Lync.int(0, 255), source = Lync.string }),
        })
    end

    describe("metadata", function(): ()
        it("flags _isTagged", function(): ()
            expect((buildBasic() :: any)._isTagged):toBe(true)
        end)
        it("records _tagField", function(): ()
            expect((buildBasic() :: any)._tagField):toBe("type")
        end)
        it("preserves variant codec table", function(): ()
            local v = (buildBasic() :: any)._variants
            expect(v):toBeType("table")
            expect(v.damage):toBeType("table")
            expect(v.heal):toBeType("table")
        end)
    end)

    describe("variant round-trip", function(): ()
        it("damage variant", function(): ()
            local c = buildBasic()
            local r = Channel.roundTripStrict(c, { type = "damage", amount = 50 })
            expect(r.type):toBe("damage")
            expect(r.amount):toBe(50)
        end)
        it("heal variant with string", function(): ()
            local c = buildBasic()
            local r = Channel.roundTripStrict(c, { type = "heal", amount = 30, source = "potion" })
            expect(r.type):toBe("heal")
            expect(r.amount):toBe(30)
            expect(r.source):toBe("potion")
        end)
        it("single-variant struct works", function(): ()
            local s = Lync.tagged("kind", { only = Lync.struct({ x = Lync.int(0, 255) }) })
            local r = Channel.roundTripStrict(s, { kind = "only", x = 7 })
            expect(r.kind):toBe("only")
            expect(r.x):toBe(7)
        end)
        it("variant tag = u8 (1-byte overhead per variant)", function(): ()
            local s = Lync.tagged("t", { a = Lync.struct({ v = Lync.int(0, 255) }) })
            local _, w = Channel.roundTripStrict(s, { t = "a", v = 42 })
            expect(w):toBe(2)
        end)
    end)

    describe("write-side validation", function(): ()
        it("unknown variant throws", function(): ()
            local c = buildBasic()
            expect(function(): ()
                Channel.encode(c, { type = "nope" })
            end):toThrow("unknown variant")
        end)
        it("missing tag field throws", function(): ()
            local c = buildBasic()
            expect(function(): ()
                Channel.encode(c, { amount = 10 })
            end):toThrow("missing tagField")
        end)
    end)

    describe("define-time errors", function(): ()
        it("empty tag field throws", function(): ()
            expect(function(): ()
                Lync.tagged("", { a = Lync.bool })
            end):toThrow("empty")
        end)
        it("no variants throws", function(): ()
            expect(function(): ()
                Lync.tagged("t", {})
            end):toThrow("at least one")
        end)
    end)

    describe("_hasUnknown propagation", function(): ()
        it("propagates from any variant", function(): ()
            local c = Lync.tagged("t", {
                ok = Lync.struct({ x = Lync.int(0, 255) }),
                anything = Lync.struct({ payload = Lync.unknown }),
            })
            expect((c :: any)._hasUnknown):toBe(true)
        end)
        it("nil when no variant carries unknown", function(): ()
            local c = Lync.tagged("t", {
                a = Lync.struct({ x = Lync.int(0, 255) }),
                b = Lync.struct({ y = Lync.string }),
            })
            expect((c :: any)._hasUnknown):toBeNil()
        end)
    end)

    describe("tag id is stable across runs (sorted variant names)", function(): ()
        it("variant tag = sorted index", function(): ()
            local c = Lync.tagged("t", {
                charlie = Lync.struct({ x = Lync.int(0, 255) }),
                alpha = Lync.struct({ x = Lync.int(0, 255) }),
                bravo = Lync.struct({ x = Lync.int(0, 255) }),
            })
            -- alpha < bravo < charlie sorted -> tags 0,1,2.
            local rA = Channel.encode(c, { t = "alpha", x = 1 })
            local rB = Channel.encode(c, { t = "bravo", x = 1 })
            local rC = Channel.encode(c, { t = "charlie", x = 1 })
            expect(buffer.readu8(rA.buffer, 0)):toBe(0)
            expect(buffer.readu8(rB.buffer, 0)):toBe(1)
            expect(buffer.readu8(rC.buffer, 0)):toBe(2)
        end)
        it("redefining the codec yields the same tag mapping", function(): ()
            local c1 = Lync.tagged("t", {
                a = Lync.struct({ x = Lync.int(0, 255) }),
                b = Lync.struct({ x = Lync.int(0, 255) }),
            })
            local c2 = Lync.tagged("t", {
                b = Lync.struct({ x = Lync.int(0, 255) }), -- order shouldn't matter
                a = Lync.struct({ x = Lync.int(0, 255) }),
            })
            local r1 = Channel.encode(c1, { t = "a", x = 1 })
            local r2 = Channel.encode(c2, { t = "a", x = 1 })
            expect(buffer.readu8(r1.buffer, 0)):toBe(buffer.readu8(r2.buffer, 0))
        end)
    end)

    describe("nested tagged", function(): ()
        it("tagged inside struct round-trips", function(): ()
            local action = Lync.tagged("type", {
                attack = Lync.struct({ damage = Lync.int(0, 255) }),
                defend = Lync.struct({ block = Lync.int(0, 255) }),
            })
            local outer = Lync.struct({ action = action, hp = Lync.int(0, 255) })
            local r = Channel.roundTripStrict(outer, {
                action = { type = "attack", damage = 50 },
                hp = 100,
            })
            expect(r.action.type):toBe("attack")
            expect(r.action.damage):toBe(50)
            expect(r.hp):toBe(100)
        end)
        it("array of tagged round-trips", function(): ()
            local event = Lync.tagged("kind", {
                a = Lync.struct({ x = Lync.int(0, 255) }),
                b = Lync.struct({ y = Lync.int(0, 255) }),
            })
            local arr = Lync.array(event)
            local r = Channel.roundTripStrict(arr, {
                { kind = "a", x = 1 },
                { kind = "b", y = 2 },
                { kind = "a", x = 3 },
            })
            expect(#r):toBe(3)
            expect(r[1].kind):toBe("a")
            expect(r[2].kind):toBe("b")
            expect(r[3].x):toBe(3)
        end)
    end)

    describe("read-side validation", function(): ()
        it("unknown tag byte throws", function(): ()
            local c = Lync.tagged("t", {
                a = Lync.struct({ x = Lync.int(0, 255) }),
            })
            local b = buffer.create(2)
            buffer.writeu8(b, 0, 5) -- tag 5 not assigned
            buffer.writeu8(b, 1, 0)
            expect(function(): ()
                c.read(b, 0, nil)
            end):toThrow("unknown tag")
        end)
    end)

    describe("max variants (256)", function(): ()
        it("256 variants is accepted at define time", function(): ()
            local schema: { [string]: any } = {}
            for i = 1, 256 do
                schema[`v_{i}`] = Lync.struct({ x = Lync.int(0, 255) })
            end
            expect(function(): ()
                Lync.tagged("t", schema)
            end).never:toThrow()
        end)
        it("257 variants throws", function(): ()
            local schema: { [string]: any } = {}
            for i = 1, 257 do
                schema[`v_{i}`] = Lync.struct({ x = Lync.int(0, 255) })
            end
            expect(function(): ()
                Lync.tagged("t", schema)
            end):toThrow()
        end)
    end)
end)

return nil
