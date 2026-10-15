--!strict
--!optimize 2
-- Two machines told the same story: the engine driven beside the oracle, and held to it.

local Session = require("@src/runtime/Session")
local Set = require("@src/api/Set")
local Shape = require("@src/shape")
local Types = require("@src/Types")

local Doubles = require("@fixtures/Doubles")
local Scenarios = require("@fixtures/Scenarios")

local Expect = require("@test/harness/Expect")
local Generate = require("@test/harness/Generate")
local Harness = require("@test/harness")
local Oracle = require("@test/harness/Oracle")
local Rng = require("@test/harness/Rng")
local Turns = require("@test/harness/Turns")

-- The namespace and the definition inside it, fixed so two failing tapes read alike.
local SPACE = "convergence"
local RECORDS = "records"

-- The viewer a scripted scenario gets when it names none of its own, since a set nobody watches
-- replicates nothing and there is no convergence to check without one.
local LONE = "watcher"

-- What a drawn run holds at once and how often a flush falls between two mutations. Small on
-- purpose: convergence is a claim about interleaving rather than volume, and the scripted
-- scenarios carry the volume.
local IDS = 6
local WATCHING = 3
local PARTS = 3
local ACTS = 24
local FLUSHES = 0.35

-- How many flushes a starved run is given to reach rest. An omitted budget is still a budget,
-- prorated by the time since the last flush, so a drain inside one tick takes several rounds.
local DRAINS = 64

-- How often an update to an optional field clears it rather than writing one.
local CLEARS = 0.25

-- Where each kind sits in the order a flush answers in: everything gone, then everything that
-- arrived, then everything that changed, each by id.
local RANK = table.freeze({ removed = 1, added = 2, changed = 3 } :: { [string]: number })

-- One client machine and every callback it has been given since the last flush. `gone` marks a
-- player that left, who stays in the list because being told nothing more is the claim.
type Client = {
    read who: string,
    read player: Player,
    read session: Session.Session,
    read set: any,
    read seen: { Oracle.Event },
    gone: boolean,
}

-- One run: a server, the clients on the other end of one lane, and the oracle beside them.
type Run = {
    read wire: Doubles.Wire,
    read roster: Doubles.Roster,
    read server: Session.Session,
    read set: any,
    read codec: Types.Codec<any>,
    read oracle: Oracle.Oracle,
    read clients: { Client },
    read key: string?,
    drains: boolean,
}

-- Machines ------------------------------------------------------------

-- The definitions one machine requires, built fresh for each side so neither holds the other's.
local function defined(codec: Types.Codec<any>, key: string?): any
    local set: any = Set.new(codec)
    return { [RECORDS] = if key ~= nil then set:keyBy(key) else set }
end

-- The fields a record carries on the lossy lane, which the model has to know about.
local function lossy(of: any): { [string]: boolean }
    local out = {}
    for name, child in of.cell.children do
        if child.marker == "newest" then out[name] = true end
    end
    return out
end

-- A record as the wire leaves it, which is what the oracle is handed rather than what a caller
-- passed, since a quantized field comes back on its grid.
local function settled(of: any, record: any): any
    local bytes, size = Turns.wrote(of, record)
    return Turns.read(of, bytes, size)
end

-- Every callback a client is handed, in the order it was handed them. Records are copied because
-- a callback is handed the row itself.
local function watching(set: any, into: { Oracle.Event })
    set:onAdded(function(id: number, record: any)
        table.insert(into, { kind = "added" :: "added", id = id, record = table.clone(record) })
    end)
    set:onChanged(function(id: number, record: any, old: any)
        local copy = table.clone(record)
        table.insert(into, { kind = "changed" :: "changed", id = id, record = copy, old = old })
    end)
    set:onRemoved(function(id: number, cause: Types.Cause)
        table.insert(into, { kind = "removed" :: "removed", id = id, cause = cause })
    end)
end

-- The client under a label. Labels are spent once, since a person who leaves and comes back
-- arrives as a new Player holding nothing.
local function client(run: Run, who: string): Client
    for _, held in run.clients do
        if held.who == who then return held end
    end
    error(`no client named {who}`, 0)
end

local function opened(codec: Types.Codec<any>, key: string?): Run
    local wire = Doubles.wire()
    local roster = Doubles.roster()
    local defs = defined(codec, key)
    local of = Shape.build(codec, RECORDS)
    local server = Session.new(SPACE, defs, wire:server(), roster, "server")
    server:start()

    local function settles(record: any): any
        return settled(of, record)
    end
    return {
        wire = wire,
        roster = roster,
        server = server,
        set = defs[RECORDS],
        codec = codec,
        oracle = Oracle.new(key, {}, settles, lossy(of)),
        clients = {},
        key = key,
        drains = false,
    }
end

-- A machine arriving. Its listeners attach before it starts, which is what makes a late join
-- observable: the catch-up keyframes arrive during the first flush after readiness.
local function joins(run: Run, who: string)
    local player = run.roster:join(who)
    local defs = defined(run.codec, run.key)
    local session = Session.new(SPACE, defs, run.wire:client(player), run.roster, "client")
    local seen: { Oracle.Event } = {}
    watching(defs[RECORDS], seen)
    session:start()
    run.wire:settle()

    Oracle.joins(run.oracle, who)
    table.insert(run.clients, {
        who = who,
        player = player,
        session = session,
        set = defs[RECORDS],
        seen = seen,
        gone = false,
    })
end

-- A person out of the game, on both of the engine's surfaces a departure touches.
local function leaves(run: Run, who: string)
    local held = client(run, who)
    run.roster:leave(held.player)
    run.wire:gone(held.player)
    Oracle.leaves(run.oracle, who)
    held.gone = true
end

-- One flush, on both sides, answering what each client should have been told. The lane runs to
-- quiet, since a frame the transport held is still this flush's traffic.
local function shipped(run: Run, budget: number?): { [string]: { Oracle.Event } }
    run.server:flush(budget)
    run.wire:settle()

    if run.drains and budget == nil then
        for round = 1, Doubles.ROUNDS do
            local before = run.wire:moved().frames
            run.server:flush()
            run.wire:settle()
            if run.wire:moved().frames == before then break end
            if round == Doubles.ROUNDS then
                Expect.holds(false, `the lane was still draining after {Doubles.ROUNDS} flushes`)
            end
        end
    end
    return Oracle.flush(run.oracle)
end

-- Checks --------------------------------------------------------------

-- The tellings of a drain, in the one order a single flush would have given them.
local function ordered(of: { Oracle.Event }): { Oracle.Event }
    local out = table.clone(of)
    table.sort(out, function(left: Oracle.Event, right: Oracle.Event): boolean
        if RANK[left.kind] ~= RANK[right.kind] then return RANK[left.kind] < RANK[right.kind] end
        return left.id < right.id
    end)
    return out
end

-- The tellings of a drain without the changes to records that arrived in it, since a delta a
-- budget put off to a later round reaches a client that already holds the record it names.
local function settledIn(of: { Oracle.Event }): { Oracle.Event }
    local arrived: { [number]: boolean } = {}
    for _, event in of do
        if event.kind == "added" then arrived[event.id] = true end
    end
    local out = {}
    for _, event in ordered(of) do
        if event.kind ~= "changed" or not arrived[event.id] then table.insert(out, event) end
    end
    return out
end

-- What a client was told, against what it should have been told.
local function agrees(run: Run, held: Client, want: { Oracle.Event }, what: string)
    local got = if run.drains then settledIn(held.seen) else held.seen
    local read, wanted = Oracle.line(got), Oracle.line(want)
    Expect.holds(read == wanted, `{what}: {held.who} saw "{read}" and not "{wanted}"`)
    for index, event in want do
        local mine = got[index]
        if event.record ~= nil then Expect.equal(mine.record, event.record) end
        if event.old ~= nil then Expect.equal(mine.old, event.old) end
    end
end

-- What a client holds against what it should, read through the surface a caller reads it with.
-- The count is the other half: a client holding every record it should could still hold one more.
local function holding(run: Run, held: Client, what: string)
    local want = Oracle.view(run.oracle, held.who)
    local count = 0
    for id, record in want do
        count += 1
        Expect.equal(held.set:get(id), record)
    end
    Expect.holds(#held.set == count, `{what}: {held.who} counts {#held.set} and not {count}`)
end

-- Every client checked against the oracle, and every departed one checked against silence.
local function agreed(run: Run, want: { [string]: { Oracle.Event } }, what: string)
    for _, held in run.clients do
        if held.gone then
            local read = Oracle.line(held.seen)
            Expect.holds(read == "", `{what}: {held.who} left and was told "{read}"`)
            continue
        end
        agrees(run, held, want[held.who], what)
        holding(run, held, what)
        table.clear(held.seen)
    end
end

-- One step, on the engine and on the oracle, in that order so a throw names the surface.
local function performed(run: Run, of: Scenarios.Step)
    if of.act == "add" then
        run.set:add(of.id, of.record)
        Oracle.add(run.oracle, of.id, of.record)
    elseif of.act == "update" then
        run.set:update(of.id, of.fields)
        Oracle.update(run.oracle, of.id, of.fields)
    elseif of.act == "remove" then
        run.set:remove(of.id)
        Oracle.remove(run.oracle, of.id)
    elseif of.act == "clear" then
        run.set:clear()
        Oracle.clear(run.oracle)
    elseif of.act == "audience" then
        run.set:audience(of.key, client(run, of.who).player)
        Oracle.audience(run.oracle, of.key, { of.who })
    elseif of.act == "join" then
        joins(run, of.who)
    elseif of.act == "leave" then
        leaves(run, of.who)
    else
        agreed(run, shipped(run, of.budget), of.mark)
    end
end

-- A scenario opened, with a viewer if it names none of its own. Nothing here closes, since a
-- close is a lifecycle claim this suite is not about.
local function staged(of: Scenarios.Scenario): Run
    local run = opened(of.fixture.codec, of.key)
    if #Scenarios.viewers(of) == 0 then joins(run, LONE) end
    return run
end

-- Whether a scenario ever flushes at a budget. A budgeted flush defers, so the client is behind
-- on purpose until it catches up, and only the end state can be checked.
local function defers(of: Scenarios.Scenario): boolean
    for _, at in of.steps do
        if at.act == "flush" and at.budget ~= nil then return true end
    end
    return false
end

-- Flushes until nothing more arrives, which is how a deferred run reaches rest.
local function drained(run: Run, held: Client)
    local count = -1
    for _ = 1, DRAINS do
        if #held.set == count then return end
        count = #held.set
        shipped(run)
    end
    Expect.holds(false, `{held.who} was still draining after {DRAINS} flushes`)
end

-- A drawn run ---------------------------------------------------------

-- The field a drawn set partitions by, or none. Half the runs go unkeyed even where one is
-- available, because an unkeyed set is the path most callers take.
local function partitioned(rng: Rng.Rng, shape: Generate.Shape): string?
    if not rng:bool() then return nil end
    local able: { string } = {}
    for index, name in shape.names do
        if table.find(Generate.KEYED, shape.of[index].at) ~= nil then table.insert(able, name) end
    end
    return if #able == 0 then nil else rng:pick(able)
end

-- One field of an update. The key field draws from the partitions in play, so a migration lands
-- on a key some audience was granted. An optional field is sometimes cleared, which is the one
-- place the none sentinel reaches a set.
local function written(
    rng: Rng.Rng,
    shape: Generate.Shape,
    at: number,
    key: string?,
    parts: { any }
): any
    if shape.names[at] == key then return rng:pick(parts) end
    local child = shape.of[at]
    if child.at ~= "optional" then return Generate.value(child, rng) end
    if rng:bool(CLEARS) then return Set.NONE end
    return Generate.value(child.of[1], rng)
end

-- What a drawn run has in play, from which the next legal act is chosen.
type Play = {
    read parts: { any },
    read free: { number },
    read live: { number },
    read watchers: { string },
    minted: number,
}

-- The acts legal right now: the surface throws on an add onto a live id and on four other shapes
-- a draw could reach, so what is drawn is the shape of the run rather than the calls in it.
local function ways(of: Play): { string }
    local acts = {}
    if #of.free > 0 then table.insert(acts, "add") end
    if #of.live > 0 then
        table.insert(acts, "update")
        table.insert(acts, "remove")
        table.insert(acts, "clear")
    end
    if #of.watchers < WATCHING then table.insert(acts, "join") end
    if #of.watchers > 1 then table.insert(acts, "leave") end
    if #of.parts > 0 then table.insert(acts, "audience") end
    return acts
end

-- One legal act as a step, with the play moved along to match.
local function acted(
    rng: Rng.Rng,
    shape: Generate.Shape,
    key: string?,
    of: Play,
    act: string
): Scenarios.Step
    if act == "add" then
        local id = table.remove(of.free) :: number
        table.insert(of.live, id)
        local record = table.clone(Generate.value(shape, rng))
        if key ~= nil then record[key] = rng:pick(of.parts) end
        return { act = "add" :: "add", id = id, record = record }
    elseif act == "update" then
        local fields = {}
        for _ = 1, rng:int(1, #shape.names) do
            local index = rng:int(1, #shape.names)
            fields[shape.names[index]] = written(rng, shape, index, key, of.parts)
        end
        return { act = "update" :: "update", id = rng:pick(of.live), fields = fields }
    elseif act == "remove" then
        local id = table.remove(of.live, rng:int(1, #of.live)) :: number
        table.insert(of.free, id)
        return { act = "remove" :: "remove", id = id }
    elseif act == "clear" then
        table.move(of.live, 1, #of.live, #of.free + 1, of.free)
        table.clear(of.live)
        return { act = "clear" :: "clear" }
    elseif act == "join" then
        of.minted += 1
        local who = `p{of.minted}`
        table.insert(of.watchers, who)
        return { act = "join" :: "join", who = who }
    elseif act == "leave" then
        local who = table.remove(of.watchers, rng:int(1, #of.watchers)) :: string
        return { act = "leave" :: "leave", who = who }
    end
    return { act = "audience" :: "audience", key = rng:pick(of.parts), who = rng:pick(of.watchers) }
end

-- A legal run of one set's life, in the same step vocabulary the scripted scenarios use, so one
-- driver replays a drawn run and a written one without knowing which it holds.
local function drawn(rng: Rng.Rng, shape: Generate.Shape, key: string?): { Scenarios.Step }
    local play: Play = { parts = {}, free = {}, live = {}, watchers = { "p1" }, minted = 1 }
    local at = if key ~= nil then table.find(shape.names, key) else nil
    if at ~= nil then
        for _ = 1, rng:int(1, PARTS) do
            table.insert(play.parts, Generate.value(shape.of[at], rng))
        end
    end
    for id = IDS, 1, -1 do
        table.insert(play.free, id)
    end

    local out: { Scenarios.Step } = { { act = "join" :: "join", who = "p1" } }
    for _, part in play.parts do
        table.insert(out, { act = "audience" :: "audience", key = part, who = "p1" })
    end

    local marks = 0
    local function flushed()
        marks += 1
        table.insert(out, { act = "flush" :: "flush", mark = `flush-{marks}` })
    end
    for _ = 1, rng:int(1, ACTS) do
        table.insert(out, acted(rng, shape, key, play, rng:pick(ways(play))))
        if rng:bool(FLUSHES) then flushed() end
    end
    flushed()
    return out
end

return {
    -- Every scripted scenario, both sides, compared after every flush.
    Harness.case("conv.scenarios", function()
        local driven = 0
        for _, of in Scenarios.all do
            if defers(of) then continue end
            driven += 1
            local run = staged(of)
            for _, at in of.steps do
                performed(run, at)
            end
        end
        Expect.holds(driven > 0, "every scenario defers, so nothing was compared in flight")
    end),

    -- Any legal run of one set's life. Every client's view equals the records its audiences allow,
    -- and every callback it was handed equals the one the oracle says it was owed, after every
    -- flush rather than at the end.
    Harness.property("conv.replicates", "model", function(rng: Rng.Rng)
        local shape = Generate.record(rng)
        local key = partitioned(rng, shape)
        local run = opened(Generate.codec(shape), key)
        run.drains = true
        for _, of in drawn(rng, shape, key) do
            performed(run, of)
        end
    end),

    -- The quiet scenario against the oracle: costing nothing and saying nothing are the same run.
    Harness.case("conv.quiet", function()
        local of = Scenarios.quiet
        local run = staged(of)
        for _, at in of.steps do
            local before = run.wire:moved().frames
            performed(run, at)
            if at.act ~= "flush" or at.mark == "keyframe" then continue end
            local after = run.wire:moved().frames
            Expect.holds(after == before, `the {at.mark} flush fired {after - before} frames`)
        end
    end),

    -- More records than the smallest legal budget can carry. A starved flush ships the prefix that
    -- fits and holds the rest, so deferral promises the same end state rather than the same path.
    Harness.case("conv.starved", function()
        local driven = 0
        for _, of in Scenarios.all do
            if not defers(of) then continue end
            driven += 1
            local run = staged(of)
            for _, at in of.steps do
                if at.act ~= "flush" then
                    performed(run, at)
                    continue
                end
                shipped(run, at.budget)
                if at.budget == nil then continue end
                for _, held in run.clients do
                    local count, whole = #held.set, 0
                    for _ in Oracle.truth(run.oracle) do
                        whole += 1
                    end
                    Expect.holds(count > 0, `{of.name} at {at.budget} shipped none of {whole}`)
                    Expect.holds(count < whole, `{of.name} at {at.budget} shipped all {whole}`)
                end
            end
            for _, held in run.clients do
                drained(run, held)
                holding(run, held, `{of.name} drained`)
            end
        end
        Expect.holds(driven > 0, "no scenario flushes at a budget, so deferral is unchecked")
    end),
}
