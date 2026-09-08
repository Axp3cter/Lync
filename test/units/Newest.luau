--!strict
--!optimize 2
-- The newest lane: what a stream has to say, how it is grouped into a section, and what a
-- receiver takes of it.

local Apply = require("@src/state/Apply")
local Catalog = require("@src/kernel/Catalog")
local Codecs = require("@src/codec")
local Compile = require("@src/shape/Compile")
local Newest = require("@src/state/Newest")
local Sections = require("@src/state/Sections")
local Store = require("@src/state/Store")
local Types = require("@src/Types")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local ROOM = 2048
local CTX: Types.ValidateContext = table.freeze({ player = nil, now = 0, last = nil })
local AT = table.freeze({ file = "Game.Net", line = 1 })

type Rig = {
    def: any,
    sender: Store.Store,
    receiver: Store.Store,
    out: Newest.Lane,
    back: Newest.Lane,
    streams: Newest.Streams,
    taken: Newest.Streams,
    heard: Apply.Heard,
    b: buffer,
    pos: number,
    hp: number,
}

-- A set with two newest fields, one rated, and a plain one, keyed by team.
local function rigged(key: string?): Rig
    local fields = {
        pos = Codecs.vec3():newest(),
        hp = Codecs.int(0, 100):newest(20),
        team = Codecs.int(0, 3),
    }
    local set = { kind = "set", of = Codecs.struct(fields), keyField = key, at = AT }
    local def: any = Compile.build("newest", { roster = set :: any }).byName.roster
    local out, back = Newest.of(Sections.of(def)), Newest.of(Sections.of(def))
    return {
        def = def,
        sender = Store.new(def),
        receiver = Store.new(def),
        out = out,
        back = back,
        streams = Newest.streams(out),
        taken = Newest.streams(back),
        heard = Apply.heard(),
        b = buffer.create(ROOM),
        pos = out.place[def.fieldIndex.pos],
        hp = out.place[def.fieldIndex.hp],
    }
end

-- A record on both stores at the same slot, at the given position and health.
local function shared(rig: Rig, id: number, at: Vector3, hp: number)
    local slot = Store.bind(rig.sender, id)
    Store.holds(rig.receiver, { id }, { slot }, 1)
    local gens = rig.receiver.gens :: any
    gens[slot] = 0
    for _, store in { rig.sender, rig.receiver } do
        store.writers[rig.def.fieldIndex.pos](slot, id, at)
        store.writers[rig.def.fieldIndex.hp](slot, id, hp)
        store.writers[rig.def.fieldIndex.team](slot, id, 1)
    end
    Newest.established(rig.out, rig.sender, { slot }, 1)
end

-- A section of the grouped streams written by the sender and applied at the receiver, answering
-- how many fields it grouped and how many records it named.
local function carried(rig: Rig, group: { number }, now: number): (number, number)
    for index, at in group do
        rig.out.group[index] = at
    end
    local count = rig.out.counts[group[1]]
    rig.out.key = 1
    local after = Newest.section(rig.out, rig.streams, rig.sender, #group, rig.b, 0, now, count)
    local many, named, held = Newest.taken(rig.back, rig.b, 0, CTX)
    for index = 1, many do
        held = Newest.values(rig.back, rig.b, held, CTX, index, named)
        local at = rig.back.group[index]
        Newest.apply(rig.back, rig.taken, rig.receiver, rig.heard, at, rig.back.seqs[index], named)
    end
    Expect.equal(held, after)
    return many, named
end

return {
    -- The lane knows its streams, each with its rate and its mark, and the receiver's streams
    -- start having said and heard nothing.
    Harness.case("newest.lane", function()
        local rig = rigged()
        Expect.equal(#rig.out.fields, 2)
        Expect.equal(rig.out.streams, true)
        Expect.equal(rig.out.hz[rig.hp], 20)
        Expect.equal(rig.out.hz[rig.pos], nil)
        Expect.equal(rig.out.mark[rig.pos](Vector3.new(1, 2, 3)), Vector3.new(1, 2, 3))
        Expect.equal(rig.out.mark[rig.hp](7), 7)
        Expect.equal(rig.streams.at, { 0, 0 })
        Expect.equal(rig.streams.took, { false, false })

        local plain = { kind = "set", of = Codecs.struct({ a = Codecs.bool() }), at = AT }
        local def: any = Compile.build("plain", { roster = plain :: any }).byName.roster
        Expect.equal(Newest.of(Sections.of(def)).streams, false)
    end),

    -- A stream says what moved since it last sent, nothing for a slot at its sent value or one
    -- nobody holds, and a rated stream says nothing until its window reopens.
    Harness.case("newest.changed", function()
        local rig = rigged()
        shared(rig, 1, Vector3.new(1, 0, 0), 50)
        shared(rig, 2, Vector3.new(2, 0, 0), 60)
        shared(rig, 3, Vector3.new(3, 0, 0), 70)
        Expect.equal(Newest.changed(rig.out, rig.streams, rig.sender, rig.pos, 1, 13), 0)

        rig.sender.writers[rig.def.fieldIndex.pos](1, 1, Vector3.new(9, 0, 0))
        rig.sender.writers[rig.def.fieldIndex.pos](3, 3, Vector3.new(8, 0, 0))
        rig.sender.writers[rig.def.fieldIndex.hp](3, 3, 71)
        Store.unbind(rig.sender, 2)
        Expect.equal(Newest.changed(rig.out, rig.streams, rig.sender, rig.pos, 1, 13), 2)
        Expect.equal({ rig.out.runs[rig.pos][1], rig.out.runs[rig.pos][2] }, { 1, 3 })
        Expect.equal(rig.out.held[rig.pos][2], Vector3.new(8, 0, 0))
        Expect.equal(Newest.changed(rig.out, rig.streams, rig.sender, rig.hp, 1, 2), 1)
        Expect.equal(Newest.alike(rig.out, rig.pos, rig.hp), false)

        rig.streams.last[rig.hp] = 1
        Expect.equal(Newest.opened(rig.out, rig.streams, rig.hp, 1.01), false)
        Expect.equal(Newest.changed(rig.out, rig.streams, rig.sender, rig.hp, 1.01, 2), 0)
        Expect.equal(Newest.opened(rig.out, rig.streams, rig.hp, 1.1), true)
        Expect.equal(Newest.opened(rig.out, rig.streams, rig.pos, 1.01), true)
    end),

    -- Two streams naming the same records share one section: the receiver takes both fields on
    -- the slots it holds, the sender records them as sent, and a sequence no newer is dropped.
    Harness.case("newest.section", function()
        local rig = rigged("team")
        shared(rig, 1, Vector3.new(1, 0, 0), 50)
        shared(rig, 2, Vector3.new(2, 0, 0), 60)
        rig.sender.writers[rig.def.fieldIndex.pos](1, 1, Vector3.new(5, 0, 0))
        rig.sender.writers[rig.def.fieldIndex.pos](2, 2, Vector3.new(6, 0, 0))
        rig.sender.writers[rig.def.fieldIndex.hp](1, 1, 55)
        rig.sender.writers[rig.def.fieldIndex.hp](2, 2, 66)
        Newest.changed(rig.out, rig.streams, rig.sender, rig.pos, 1, 13)
        Newest.changed(rig.out, rig.streams, rig.sender, rig.hp, 1, 2)
        Expect.equal(Newest.alike(rig.out, rig.pos, rig.hp), true)

        rig.heard.watching = true
        local many, named = carried(rig, { rig.pos, rig.hp }, 1)
        Expect.equal({ many, named }, { 2, 2 })
        Expect.equal(rig.back.key, 1)
        Expect.equal(rig.receiver.rows[1], { pos = Vector3.new(5, 0, 0), hp = 55, team = 1 })
        Expect.equal(rig.receiver.rows[2], { pos = Vector3.new(6, 0, 0), hp = 66, team = 1 })
        Expect.equal(rig.heard.olds[1], { pos = Vector3.new(1, 0, 0), hp = 50, team = 1 })
        local _, _, changed = Apply.parted(rig.heard)
        Expect.equal(changed, { 1, 2 })
        Expect.equal(rig.streams.at, { 1, 1 })
        Expect.equal(rig.streams.last, { 1, 1 })
        Expect.equal(rig.taken.heard, { 1, 1 })
        Expect.equal((rig.sender.sent[rig.def.fieldIndex.hp] :: any)[1], 55)
        Expect.equal(Newest.changed(rig.out, rig.streams, rig.sender, rig.pos, 2, 13), 0)

        -- The same section replayed is no newer and changes nothing, even after the receiver moved
        -- on, and a stream number this set does not have is refused.
        rig.receiver.writers[rig.def.fieldIndex.hp](1, 1, 1)
        rig.back.seqs[1] = 0
        Newest.apply(rig.back, rig.taken, rig.receiver, rig.heard, rig.hp, 1, 2)
        Expect.equal(rig.receiver.rows[1].hp, 1)
        buffer.writeu8(rig.b, 0, 0xFF)
        local ok, why = pcall(Newest.taken, rig.back, rig.b, 0, CTX)
        Expect.holds(not ok, "a section naming a stream this set has not got was taken")
        Expect.equal((why :: any).code, Catalog.SECTION)
    end),

    -- A slot rebound since the section was written stands at another generation and is left
    -- alone, and sweeping puts every stream back to having said nothing, keeping only the
    -- sequence it says it with, since a viewer orders sections by that across a clear.
    Harness.case("newest.generations-and-sweep", function()
        local rig = rigged()
        shared(rig, 1, Vector3.new(1, 0, 0), 50)
        rig.sender.writers[rig.def.fieldIndex.pos](1, 1, Vector3.new(5, 0, 0))
        Newest.changed(rig.out, rig.streams, rig.sender, rig.pos, 1, 13)
        local gens = rig.receiver.gens :: { [number]: number }
        gens[1] = 3
        carried(rig, { rig.pos }, 1)
        Expect.equal(rig.receiver.rows[1].pos, Vector3.new(1, 0, 0))

        local spoken = table.clone(rig.streams.at)
        Expect.holds(spoken[rig.pos] > 0, "the stream had said nothing before the sweep")
        Newest.sweep(rig.streams)
        Expect.equal(rig.streams.at, spoken)
        Expect.equal(rig.streams.last, {})
        Expect.equal(rig.streams.took, { false, false })
        Expect.equal(rig.streams.from, { 0, 0 })
    end),
}
