--!strict
--!optimize 2
-- The trust split: what a payload is read under, what a failed read leaves behind, and which side
-- of the split each drop is recorded on.

local Boundary = require("@src/runtime/Boundary")
local Catalog = require("@src/kernel/Catalog")
local Codecs = require("@src/codec")
local Compile = require("@src/shape/Compile")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Records = require("@test/harness/Records")

local AT = table.freeze({ file = "Game.Net", line = 9 })
local ROOM = 64

-- A packet of one checked int, so a read can end three ways: taken, resumed past a check, closed.
local function compiled(): (Compile.Packet, Boundary.Names)
    local of = Codecs.int(0, 100):validate(function(value: number): string?
        return if value > 50 then "too high" else nil
    end)
    local packet = {
        kind = "packet",
        of = of,
        isUnreliable = false,
        isNewest = false,
        isTimestamped = false,
        at = AT,
    }
    local def = Compile.build("edge", { Hit = packet :: any }).byName.Hit :: Compile.Packet
    return def, { paths = def.built.paths, expected = def.built.expected }
end

local heard = Records.made

return {
    -- A frame from a client is read under the hostile context, one from the server under the
    -- trusted one, and each definition's last hearing is stamped per sender.
    Harness.case("boundary.contexts", function()
        local of = Boundary.new("edge")
        local alice = Doubles.roster():join("alice")
        Boundary.opened(of, alice, 5)
        Expect.equal(of.ctx, of.hostile)
        Expect.equal({ of.ctx.player, of.ctx.now, of.ctx.last }, { alice, 5, nil })
        Boundary.stamped(of, alice, 2, 5)
        Expect.equal(of.ctx.last, nil)
        Boundary.opened(of, alice, 7)
        Boundary.stamped(of, alice, 2, 7)
        Expect.equal(of.ctx.last, 5)

        Boundary.opened(of, nil, 8)
        Expect.equal(of.ctx, of.trusted)
        Expect.equal(of.ctx.player, nil)
        Boundary.stamped(of, nil, 2, 8)
        Expect.equal(of.ctx.last, nil)
        Boundary.stamped(of, nil, 2, 9)
        Expect.equal(of.ctx.last, 8)

        Boundary.left(of, alice)
        Expect.equal(of.stamps[alice], nil)
    end),

    -- A payload that decodes is taken. One a check turns away is dropped naming the definition,
    -- its site, the player and the reason, and the frame resumes past it.
    Harness.case("boundary.resumes-past-a-check", function()
        local def, names = compiled()
        local of = Boundary.new("edge")
        local alice = Doubles.roster():join("alice")
        local b = buffer.create(ROOM)
        def.built.write(b, 0, 7)
        def.built.write(b, 1, 70)
        Boundary.opened(of, alice, 1)

        local at, value = Boundary.ran(of, def, names, def.built.read, b, 0)
        Expect.equal({ at, value, of.took, of.live }, { 1, 7, true, true })

        local said = heard(function()
            at, value = Boundary.ran(of, def, names, def.built.read, b, 1)
        end)
        Expect.equal({ at, value, of.took, of.live }, { 2, nil, false, true })
        Expect.equal(#said, 1)
        Expect.equal(said[1].kind, "warn")
        Expect.equal(said[1].data.code, Catalog.VALIDATE)
        Expect.equal(said[1].data.definition, "Hit")
        Expect.equal(said[1].data.file, AT.file)
        Expect.equal(said[1].data.line, AT.line)
        Expect.equal(said[1].data.player, alice)
        Expect.equal(said[1].data.reason, "too high")
    end),

    -- A payload the reader cannot take at all closes the frame, with the path and the expected
    -- form read back from the interners, and is an error when the server sent it.
    Harness.case("boundary.closes-on-a-fault", function()
        local def, names = compiled()
        local of = Boundary.new("edge")
        local b = buffer.create(ROOM)
        buffer.writeu8(b, 0, 101)
        Boundary.opened(of, nil, 1)
        local said = heard(function()
            local at, value = Boundary.ran(of, def, names, def.built.read, b, 0)
            Expect.equal({ at, value, of.took, of.live }, { nil, nil, false, false })
        end)
        Expect.equal(said[1].kind, "error")
        Expect.equal(said[1].data.code, Catalog.TAG)
        Expect.equal(said[1].data.path, "Hit")
        Expect.equal(said[1].data.expected, "int(0,100):validate")

        Boundary.opened(of, Doubles.roster():join("bob"), 2)
        local raised = heard(function()
            Boundary.ran(of, def, names, function()
                error("a reader's own mistake")
            end, b, 0)
        end)
        Expect.equal(raised[1].kind, "warn")
        Expect.equal(raised[1].data.code, Catalog.BOUNDS)
        Expect.holds(
            string.find(raised[1].data.said :: string, "own mistake", 1, true) ~= nil,
            "the raise was lost"
        )
    end),

    -- A failure about the frame itself closes it and is recorded under the frame's sender.
    Harness.case("boundary.lost", function()
        local of = Boundary.new("edge")
        local alice = Doubles.roster():join("alice")
        Boundary.opened(of, alice, 1)
        local said = heard(function()
            Boundary.lost(of, Catalog.HELLO, { code = Catalog.HELLO })
        end)
        Expect.equal(of.live, false)
        Expect.equal(said[1].kind, "warn")
        Expect.equal(said[1].data.code, Catalog.HELLO)
        Expect.equal(said[1].data.player, alice)
        Expect.equal(said[1].data.file, "Lync")
    end),
}
