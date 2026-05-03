--!strict
--!optimize 2
-- Property test: random-composed codecs round-trip random valid inputs.

local Env = require(script:FindFirstAncestor("test").Env)

local Channel = Env.Channel
local Lync = Env.Lync
local Random = Env.Random
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("property.Composite", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("array(int) of random length", function(): ()
        it("100 random arrays round-trip", function(): ()
            local rng = Random.new(0xA1)
            local codec = Lync.array(Lync.int(0, 255))
            for _ = 1, 100 do
                local n = rng:int(0, 50)
                local input = table.create(n)
                for i = 1, n do
                    input[i] = rng:int(0, 255)
                end
                local decoded = Channel.roundTripStrict(codec, input)
                if #decoded ~= n then
                    error(`length mismatch: {#decoded} vs {n}`)
                end
                for i = 1, n do
                    if decoded[i] ~= input[i] then
                        error(`element mismatch at {i}`)
                    end
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("nested struct round-trip", function(): ()
        it("two-level struct with mixed fields", function(): ()
            local rng = Random.new(0xB2)
            local inner = Lync.struct({
                x = Lync.int(0, 255),
                y = Lync.int(-128, 127),
                name = Lync.string,
            })
            local outer = Lync.struct({
                child = inner,
                flag = Lync.bool,
                value = Lync.int(0, 65535),
            })
            for _ = 1, 50 do
                local input = {
                    child = {
                        x = rng:int(0, 255),
                        y = rng:int(-128, 127),
                        name = rng:string(rng:int(0, 30)),
                    },
                    flag = rng:bool(),
                    value = rng:int(0, 65535),
                }
                local decoded = Channel.roundTripStrict(outer, input)
                if decoded.child.x ~= input.child.x then
                    error("child.x mismatch")
                end
                if decoded.flag ~= input.flag then
                    error("flag mismatch")
                end
                if decoded.value ~= input.value then
                    error("value mismatch")
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("optional(int) round-trip", function(): ()
        it("nil and present cases", function(): ()
            local rng = Random.new(0xC3)
            local c = Lync.optional(Lync.int(0, 65535))
            for _ = 1, 100 do
                local input: number? = if rng:bool() then rng:int(0, 65535) else nil
                local decoded = Channel.roundTripStrict(c, input)
                if decoded ~= input then
                    error(`mismatch: {tostring(decoded)} vs {tostring(input)}`)
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("tuple round-trip", function(): ()
        it("(u16, string, bool)", function(): ()
            local rng = Random.new(0xD4)
            local c = Lync.tuple(Lync.int(0, 65535), Lync.string, Lync.bool)
            for _ = 1, 100 do
                local input = { rng:int(0, 65535), rng:string(rng:int(0, 20)), rng:bool() }
                local decoded = Channel.roundTripStrict(c, input)
                if decoded[1] ~= input[1] then
                    error("tuple[1] mismatch")
                end
                if decoded[2] ~= input[2] then
                    error("tuple[2] mismatch")
                end
                if decoded[3] ~= input[3] then
                    error("tuple[3] mismatch")
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("map(string, int) round-trip", function(): ()
        it("100 random small maps", function(): ()
            local rng = Random.new(0xE5)
            local c = Lync.map(Lync.string, Lync.int(0, 1000))
            for _ = 1, 100 do
                local n = rng:int(0, 10)
                local input: { [string]: number } = {}
                for i = 1, n do
                    input[rng:string(rng:int(1, 8))] = rng:int(0, 1000)
                end
                local decoded = Channel.roundTripStrict(c, input)
                for k, v in input do
                    if decoded[k] ~= v then
                        error(`map mismatch at key "{k}"`)
                    end
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("tagged dispatch round-trip", function(): ()
        it("two variants, random selection", function(): ()
            local rng = Random.new(0xF6)
            local c = Lync.tagged("type", {
                damage = Lync.struct({ amount = Lync.int(0, 1000) }),
                heal = Lync.struct({ amount = Lync.int(0, 100), source = Lync.string }),
            })
            for _ = 1, 100 do
                local input
                if rng:bool() then
                    input = { type = "damage", amount = rng:int(0, 1000) }
                else
                    input = {
                        type = "heal",
                        amount = rng:int(0, 100),
                        source = rng:string(rng:int(1, 12)),
                    }
                end
                local decoded = Channel.roundTripStrict(c, input)
                if decoded.type ~= input.type then
                    error("tag mismatch")
                end
                if decoded.amount ~= input.amount then
                    error("amount mismatch")
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("array of struct round-trip", function(): ()
        it("variable-length arrays of structs preserve shape", function(): ()
            local rng = Random.new(0x1A)
            local elem = Lync.struct({ x = Lync.int(0, 255), y = Lync.int(0, 255) })
            local c = Lync.array(elem)
            for _ = 1, 50 do
                local n = rng:int(0, 30)
                local input = table.create(n)
                for i = 1, n do
                    input[i] = { x = rng:int(0, 255), y = rng:int(0, 255) }
                end
                local decoded = Channel.roundTripStrict(c, input)
                if #decoded ~= n then
                    error(`length mismatch: {#decoded} vs {n}`)
                end
                for i = 1, n do
                    if decoded[i].x ~= input[i].x or decoded[i].y ~= input[i].y then
                        error(`element[{i}] mismatch`)
                    end
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("optional of array", function(): ()
        it("nil and present array round-trip", function(): ()
            local rng = Random.new(0x2B)
            local c = Lync.optional(Lync.array(Lync.int(0, 255)))
            for _ = 1, 100 do
                if rng:bool() then
                    local n = rng:int(0, 20)
                    local input = table.create(n)
                    for i = 1, n do
                        input[i] = rng:int(0, 255)
                    end
                    local decoded = Channel.roundTripStrict(c, input)
                    if #decoded ~= n then
                        error("optional array length mismatch")
                    end
                else
                    local decoded = Channel.roundTripStrict(c, nil)
                    if decoded ~= nil then
                        error("optional should be nil")
                    end
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("triple-nested struct round-trip", function(): ()
        it("3-level deep struct survives", function(): ()
            local rng = Random.new(0x3C)
            local l3 = Lync.struct({ v = Lync.int(0, 100) })
            local l2 = Lync.struct({ inner = l3, label = Lync.string })
            local l1 = Lync.struct({ child = l2, count = Lync.int(0, 1000) })
            for _ = 1, 50 do
                local input = {
                    child = {
                        inner = { v = rng:int(0, 100) },
                        label = rng:string(rng:int(1, 10)),
                    },
                    count = rng:int(0, 1000),
                }
                local decoded = Channel.roundTripStrict(l1, input)
                if decoded.child.inner.v ~= input.child.inner.v then
                    error("deep mismatch")
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("bitfield round-trip with random fields", function(): ()
        it("4 mixed-width fields", function(): ()
            local rng = Random.new(0x4D)
            local c = Lync.bitfield({
                flag = { type = "bool" },
                small = { type = "uint", width = 4 },
                med = { type = "uint", width = 12 },
                neg = { type = "int", width = 8 },
            })
            for _ = 1, 100 do
                local input = {
                    flag = rng:bool(),
                    small = rng:int(0, 15),
                    med = rng:int(0, 4095),
                    neg = rng:int(-128, 127),
                }
                local decoded = Channel.roundTripStrict(c, input)
                if decoded.flag ~= input.flag then
                    error("flag")
                end
                if decoded.small ~= input.small then
                    error("small")
                end
                if decoded.med ~= input.med then
                    error("med")
                end
                if decoded.neg ~= input.neg then
                    error("neg")
                end
            end
            expect(true):toBe(true)
        end)
    end)
end)

return nil
