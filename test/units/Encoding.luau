--!strict
--!optimize 2
-- A codec on its own: what it encodes decodes back, in exactly the bytes it takes, with its
-- instances returned per call, and what does not fit is refused with a line that names it.

local Lync = require("@src")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

return {
    -- A value encodes to exactly its bytes and decodes back whole, every validate run on the way.
    Harness.case("encode.round-trip", function()
        local seen = 0
        local profile = Lync.struct({
            coins = Lync.vlq():validate(function(_: number, ctx: Lync.ValidateContext): string?
                seen += if ctx.player == nil then 1 else 0
                return nil
            end),
            mods = Lync.map(Lync.str(1, 50), Lync.int(0, 100), 0, 8),
        })
        local value = { coins = 9000000001, mods = { speed = 5, jump = 100 } }
        local bytes, refs = Lync.encode(profile, value)
        Expect.equal(refs, nil)
        Expect.equal(Lync.decode(profile, bytes), value)
        Expect.equal(seen, 1)
        Expect.equal(buffer.len((Lync.encode(Lync.int(0, 255), 7))), 1)
    end),

    -- Instances come back per call, so two encodes in flight never share them.
    Harness.case("encode.refs", function()
        local list = Lync.array(Lync.inst(), 0, 4)
        local one, two = Instance.new("Folder"), Instance.new("Folder")
        local first, firstRefs = Lync.encode(list, { one, two, one })
        local second, secondRefs = Lync.encode(list, { two })
        Expect.equal(firstRefs, { one, two })
        Expect.equal(secondRefs, { two })
        Expect.equal(Lync.decode(list, first, firstRefs), { one, two, one })
        Expect.equal(Lync.decode(list, second, secondRefs), { two })
    end),

    -- A value the codec refuses, bytes that do not read, and bytes with more after the value are
    -- each refused with a line naming what went wrong.
    Harness.case("encode.refuses", function()
        local count = Lync.int(0, 10)
        Expect.throws(function()
            Lync.encode(count, 11)
        end, "encode refused the value")
        Expect.throws(function()
            Lync.decode(Lync.str(0, 4), buffer.fromstring("\9"))
        end, "decode refused the bytes")
        local padded = buffer.create(2)
        Expect.throws(function()
            Lync.decode(count, padded)
        end, "decode read 1 of 2 bytes")
        Expect.throws(function()
            Lync.encode(Lync.struct({ pos = Lync.f32():newest() }), { pos = 1 })
        end, "keeps nothing to differ from")
    end),
}
