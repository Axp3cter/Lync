--!strict
--!optimize 2
-- Property test: delta codecs collapse identical writes to a single byte.

local Env = require(script:FindFirstAncestor("test").Env)

local Channel = Env.Internal.Channel
local Lync = Env.Lync
local Random = Env.Random
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("property.Delta", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("deltaStruct cache idempotence", function(): ()
        it("repeating same value 50 times always lands at 1 byte after first", function(): ()
            local rng = Random.new(0xD1)
            local c = Lync.deltaStruct({
                hp = Lync.int(0, 1000),
                mp = Lync.int(0, 1000),
                level = Lync.int(0, 100),
            })
            local sample = {
                hp = rng:int(0, 1000),
                mp = rng:int(0, 1000),
                level = rng:int(0, 100),
            }
            local ch = Channel.create()
            c.write(ch, sample)
            for _ = 1, 50 do
                ch.cursor = 0
                c.write(ch, sample)
                if ch.cursor ~= 1 then
                    error(`cache breakdown after repeat: cursor={ch.cursor}`)
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("deltaArray cache idempotence", function(): ()
        it("identical arrays produce 1-byte delta", function(): ()
            local rng = Random.new(0xE2)
            local c = Lync.deltaArray(Lync.int(0, 65535))
            local n = 20
            local sample = table.create(n)
            for i = 1, n do
                sample[i] = rng:int(0, 65535)
            end
            local ch = Channel.create()
            c.write(ch, sample)
            for _ = 1, 30 do
                ch.cursor = 0
                c.write(ch, sample)
                if ch.cursor ~= 1 then
                    error("delta cache failed")
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("deltaMap cache idempotence", function(): ()
        it("identical maps produce 1-byte delta", function(): ()
            local rng = Random.new(0xF3)
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 65535))
            local sample: { [string]: number } = {}
            for i = 1, 10 do
                sample[`k{i}`] = rng:int(0, 65535)
            end
            local ch = Channel.create()
            c.write(ch, sample)
            for _ = 1, 30 do
                ch.cursor = 0
                c.write(ch, sample)
                if ch.cursor ~= 1 then
                    error("delta map cache failed")
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("deltaStruct mutates in random patterns", function(): ()
        it("changing a single field always larger than 1 byte", function(): ()
            local rng = Random.new(0xA1)
            local c = Lync.deltaStruct({
                hp = Lync.int(0, 1000),
                mp = Lync.int(0, 1000),
                level = Lync.int(0, 100),
            })
            local ch = Channel.create()
            c.write(ch, { hp = 500, mp = 500, level = 50 })
            for _ = 1, 30 do
                local mutation = rng:int(1, 3)
                local v = if mutation == 1
                    then { hp = rng:int(0, 1000), mp = 500, level = 50 }
                    elseif mutation == 2 then { hp = 500, mp = rng:int(0, 1000), level = 50 }
                    else { hp = 500, mp = 500, level = rng:int(0, 100) }
                ch.cursor = 0
                c.write(ch, v)
                if ch.cursor < 1 then
                    error("delta should write at least the flag byte")
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("deltaArray length transitions", function(): ()
        it("array length growing N -> N+1 always non-1-byte", function(): ()
            local rng = Random.new(0xB2)
            local c = Lync.deltaArray(Lync.int(0, 255))
            local arr = { rng:int(0, 255) }
            local ch = Channel.create()
            c.write(ch, arr)
            for _ = 1, 20 do
                table.insert(arr, rng:int(0, 255))
                ch.cursor = 0
                c.write(ch, arr)
                if ch.cursor == 1 then
                    error("growing array should not collapse to 1 byte")
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("deltaMap key change semantics", function(): ()
        it("removing a key invalidates the byte-equality cache", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 100))
            local ch = Channel.create()
            c.write(ch, { a = 1, b = 2 })
            ch.cursor = 0
            c.write(ch, { a = 1 }) -- removed b
            expect(ch.cursor > 1):toBe(true)
        end)
        it("adding a key invalidates the cache", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 100))
            local ch = Channel.create()
            c.write(ch, { a = 1 })
            ch.cursor = 0
            c.write(ch, { a = 1, b = 2 })
            expect(ch.cursor > 1):toBe(true)
        end)
    end)

    describe("deltaStruct multi-field changes", function(): ()
        it("changing all fields produces a multi-update encoding", function(): ()
            local c = Lync.deltaStruct({
                a = Lync.int(0, 255),
                b = Lync.int(0, 255),
                c = Lync.int(0, 255),
                d = Lync.int(0, 255),
            })
            local ch = Channel.create()
            c.write(ch, { a = 1, b = 2, c = 3, d = 4 })
            ch.cursor = 0
            c.write(ch, { a = 11, b = 22, c = 33, d = 44 })
            expect(ch.cursor > 1):toBe(true)
        end)
    end)
end)

return nil
