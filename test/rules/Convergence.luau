--!strict
--!optimize 2
-- Two machines told the same story: the engine driven beside the oracle, and held to it.

local Lync = require ("@src")
local Session = require ("@src/runtime/Session")
local Shape = require ("@src/shape")
local Types = require ("@src/Types")

local Doubles = require ("@fixtures/Doubles")
local Scenarios = require ("@fixtures/Scenarios")

local Expect = require ("@test/harness/Expect")
local Generate = require ("@test/harness/Generate")
local Harness = require ("@test/harness")
local Oracle = require ("@test/harness/Oracle")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

--[[
    The namespace and the definition inside it. Both are labels rather than anything the library
    reads meaning from, and both are fixed rather than drawn: a run that named its own namespace
    would make two failing tapes read differently for no reason, and nothing here opens two.
]]
const SPACE = "convergence"
const RECORDS = "records"

--[[
    The viewer a scripted scenario gets when it names none of its own. Those are written for the
    goldens, where the bytes on the lane are the observation. A set nobody watches replicates
    nothing, so there is no convergence to check without one, and joining one before the first step
    is the smallest change that makes the scenario mean something here.
]]
const LONE = "watcher"

--[[
    What a drawn run holds at once, and how often a flush falls between two mutations. Small on
    purpose: convergence is a claim about interleaving rather than about volume, so six ids through
    two dozen mutations reaches every fold of the net-op table while leaving a failing tape short
    enough to read. The scripted scenarios carry the volume.
]]
const IDS = 6
const WATCHING = 3
const PARTS = 3
const ACTS = 24
const FLUSHES = 0.35

--[[
    How many flushes a starved run is given to reach rest. An omitted budget is still a budget,
    prorated by the time since the last flush, and a suite running its whole scenario inside one
    tick is handed very little of one, so a drain takes several rounds. The bound is here so a drain
    that never finishes fails saying so rather than running until something else gives out.
]]
const DRAINS = 64

-- How often an update to an optional field clears it rather than writing one.
const CLEARS = 0.25

--[[
    The context a standalone read is handed. Nothing here validates, so nothing reads it, and it is
    passed anyway because a read taking two arguments in a suite and three in the library would be
    a signature this file agrees with and nothing else does.
]]
const CTX: Types.ValidateContext = table.freeze ({ player = nil, now = 0, last = nil })

-- Types ---------------------------------------------------------------

--[[
    One client machine: its session, the handle it reads through, and every callback it has been
    given since the last flush. `gone` marks a player that left, which stays in the list rather than
    leaving it, because a departed client being told nothing more is the claim and a list it is not
    in cannot make it.
]]
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
    read codec: Lync.Codec<any>,
    read oracle: Oracle.Oracle,
    read clients: { Client },
    read key: string?,
    drains: boolean,
}

-- Private -------------------------------------------------------------

--[[
    The definitions one machine requires, built fresh for each side because that is what two
    machines do: both run the same declaration module and neither holds the other's objects. A suite
    sharing one table between the sides would have the server and the client reading one view and
    agreeing by construction.
]]
local function defined (codec: Lync.Codec<any>, key: string?): any
    local set = Lync.replicate (codec)
    return { [RECORDS] = if key ~= nil then set:keyBy (key) else set }
end

-- The fields a record carries on the lossy lane, which the model has to know about.
local function lossy (of: any): { [string]: boolean }
    local out = {}
    for name, child in of.cell.children do
        if child.marker == "newest" then out[name] = true end
    end
    return out
end

--[[
    A record as the wire leaves it, which is what the oracle is handed rather than what a caller
    passed. A quantized field comes back on its grid, so a model holding the original would call
    two writes to one grid point a change nobody is told about. Whether the round trip itself is
    faithful is settled elsewhere, and this asks only that both machines hold the same record.
]]
local function settled (of: any, record: any): any
    local bytes = buffer.create (of.maxBytes)
    local size = of.write (bytes, 0, record)

    local at, value = of.read (bytes, 0, CTX)
    Expect.holds (at == size, `a record read {at} bytes of the {size} it was written into`)
    return value
end

-- Every callback a client is handed, in the order it was handed them.
local function watching (set: any, into: { Oracle.Event })
    --[[
        Copied, because a record reaching a callback is the row itself and the surface says as much
        of every read: borrowed, so copy what you keep. A log holding the row would hold whatever
        the next frame made of it, and a check reading it afterwards would be reading the present
        and calling it the past.
    ]]
    local function added (id: number, record: any)
        table.insert (into, { kind = "added" :: "added", id = id, record = table.clone (record) })
    end

    local function changed (id: number, record: any, old: any)
        table.insert (into, {
            kind = "changed" :: "changed",
            id = id,
            record = table.clone (record),
            old = old,
        })
    end

    local function removed (id: number, cause: Lync.Cause)
        table.insert (into, { kind = "removed" :: "removed", id = id, cause = cause })
    end

    set:onAdded (added)
    set:onChanged (changed)
    set:onRemoved (removed)
end

--[[
    The client under a label. Labels are spent once, here and in the oracle, because a person who
    leaves and comes back arrives as a new Player holding nothing and granted nothing the old one
    was. A run reusing a name would be asserting the opposite of what the engine can do.
]]
local function client (run: Run, who: string): Client
    for _, held in run.clients do
        if held.who == who then return held end
    end
    error (`no client named {who}`, 0)
end

local function opened (codec: Lync.Codec<any>, key: string?): Run
    local wire = Doubles.wire ()
    local roster = Doubles.roster ()
    local defs = defined (codec, key)
    local of = Shape.build (codec, RECORDS)

    local server = Session.new (SPACE, defs, wire:server (), roster, "server")
    server:start ()

    return {
        wire = wire,
        roster = roster,
        server = server,
        set = defs[RECORDS],
        codec = codec,
        oracle = Oracle.new (
            key,
            {},
            function (record: any): any return settled (of, record) end,
            lossy (of)
        ),
        clients = {},
        key = key,
        drains = false,
    }
end

--[[
    A machine arriving. It requires the definitions itself, attaches its listeners before it starts,
    and the lane runs to quiet so the handshake completes before the first mutation. Attaching first
    is what makes a late join observable at all: the catch-up keyframes arrive during the first
    flush after readiness, and a listener attached after them would see nothing.
]]
local function joins (run: Run, who: string)
    local player = run.roster:join (who)
    local defs = defined (run.codec, run.key)
    local session = Session.new (SPACE, defs, run.wire:client (player), run.roster, "client")
    local seen: { Oracle.Event } = {}

    watching (defs[RECORDS], seen)
    session:start ()
    run.wire:settle ()

    Oracle.joins (run.oracle, who)
    table.insert (run.clients, {
        who = who,
        player = player,
        session = session,
        set = defs[RECORDS],
        seen = seen,
        gone = false,
    })
end

-- A person out of the game, on both of the engine's surfaces a departure touches.
local function leaves (run: Run, who: string)
    local held = client (run, who)
    run.roster:leave (held.player)
    run.wire:gone (held.player)
    Oracle.leaves (run.oracle, who)
    held.gone = true
end

--[[
    One flush, on both sides, answering what each client should have been told. The lane runs to
    quiet rather than one round, because a frame the transport held is still this flush's traffic
    and a comparison taken before it landed would report a client behind by the reorder the lane was
    faking.
]]
local function shipped (run: Run, budget: number?): { [string]: { Oracle.Event } }
    run.server:flush (budget)
    run.wire:settle ()

    if run.drains and budget == nil then
        for round = 1, Doubles.ROUNDS do
            local before = run.wire:moved ().frames
            run.server:flush ()
            run.wire:settle ()

            if run.wire:moved ().frames == before then break end
            if round == Doubles.ROUNDS then
                Expect.holds (false, `the lane was still draining after {Doubles.ROUNDS} flushes`)
            end
        end
    end

    return Oracle.flush (run.oracle)
end

--[[
    Where each kind sits in the order a flush answers in, which is what a drain has to be read back
    into. The fan says everything gone, then everything that arrived, then everything that changed,
    and each of those by id.
]]
const RANK = table.freeze ({ removed = 1, added = 2, changed = 3 } :: { [string]: number })

-- The tellings of a drain, in the one order a single flush would have given them.
local function ordered (of: { Oracle.Event }): { Oracle.Event }
    local out = table.clone (of)
    table.sort (out, function (left: Oracle.Event, right: Oracle.Event): boolean
        if RANK[left.kind] ~= RANK[right.kind] then return RANK[left.kind] < RANK[right.kind] end
        return left.id < right.id
    end)
    return out
end

-- What a client was told, against what it should have been told.
local function agrees (run: Run, held: Client, want: { Oracle.Event }, what: string)
    local got = if run.drains then ordered (held.seen) else held.seen
    local read, wanted = Oracle.line (got), Oracle.line (want)
    Expect.holds (read == wanted, `{what}: {held.who} saw "{read}" and not "{wanted}"`)

    for index, event in want do
        local mine = got[index]
        if event.record ~= nil then Expect.equal (mine.record, event.record) end
        if event.old ~= nil then Expect.equal (mine.old, event.old) end
    end
end

--[[
    What a client holds against what it should, read through the surface a caller reads it with.
    The count is the other half rather than a convenience: a client holding every record it should
    could still hold one more, and the two together are exact, so nothing walks its own ids.
]]
local function holding (run: Run, held: Client, what: string)
    local want = Oracle.view (run.oracle, held.who)
    local count = 0

    for id, record in want do
        count += 1
        Expect.equal (held.set:get (id), record)
    end
    Expect.holds (#held.set == count, `{what}: {held.who} counts {#held.set} and not {count}`)
end

-- Every client checked against the oracle, and every departed one checked against silence.
local function agreed (run: Run, want: { [string]: { Oracle.Event } }, what: string)
    for _, held in run.clients do
        if held.gone then
            local read = Oracle.line (held.seen)
            Expect.holds (read == "", `{what}: {held.who} left and was told "{read}"`)
            continue
        end

        agrees (run, held, want[held.who], what)
        holding (run, held, what)
        table.clear (held.seen)
    end
end

-- One step, on the engine and on the oracle, in that order so a throw names the surface.
local function performed (run: Run, of: Scenarios.Step)
    if of.act == "add" then
        run.set:add (of.id, of.record)
        Oracle.add (run.oracle, of.id, of.record)
        return
    end
    if of.act == "update" then
        run.set:update (of.id, of.fields)
        Oracle.update (run.oracle, of.id, of.fields)
        return
    end
    if of.act == "remove" then
        run.set:remove (of.id)
        Oracle.remove (run.oracle, of.id)
        return
    end
    if of.act == "clear" then
        run.set:clear ()
        Oracle.clear (run.oracle)
        return
    end
    if of.act == "audience" then
        run.set:audience (of.key, client (run, of.who).player)
        Oracle.audience (run.oracle, of.key, { of.who })
        return
    end
    if of.act == "join" then
        joins (run, of.who)
        return
    end
    if of.act == "leave" then
        leaves (run, of.who)
        return
    end
    agreed (run, shipped (run, of.budget), of.mark)
end

--[[
    A scenario opened, with a viewer if it names none of its own. Nothing here closes: a close
    releases the transports and resolves what is outstanding, which is a lifecycle claim, and a
    suite closing would be asserting a behaviour it is not about and cannot see the other half.
]]
local function staged (of: Scenarios.Scenario): Run
    local run = opened (of.fixture.codec, of.key)
    if #Scenarios.viewers (of) == 0 then joins (run, LONE) end
    return run
end

--[[
    Whether a scenario ever flushes at a budget, which is what decides who drives it. A budgeted
    flush defers, so the client is behind on purpose and the callbacks it was handed are not the
    oracle's from that flush until it catches up. Splitting the scenarios on the question rather
    than listing them is what keeps a new one from landing on the side that cannot check it.
]]
local function defers (of: Scenarios.Scenario): boolean
    for _, at in of.steps do
        if at.act == "flush" and at.budget ~= nil then return true end
    end
    return false
end

-- Flushes until nothing more arrives, which is how a deferred run reaches rest.
local function drained (run: Run, held: Client)
    local count = -1
    for _ = 1, DRAINS do
        if #held.set == count then return end
        count = #held.set
        shipped (run)
    end
    Expect.holds (false, `{held.who} was still draining after {DRAINS} flushes`)
end

-- A drawn run ---------------------------------------------------------

-- A step, frozen where every step the scenarios write is frozen.
local function step (of: Scenarios.Step): Scenarios.Step return table.freeze (of) end

--[[
    The field a drawn set partitions by, or none. A key must be a scalar the wire can order, which
    is the same list a map key draws from, and a drawn record need hold no field of that kind at
    all. Half the runs go unkeyed even where one is available, because an unkeyed set is one
    partition every client holds and that is the path most callers take.
]]
local function partitioned (rng: Rng.Rng, shape: Generate.Shape): string?
    if not Rng.bool (rng) then return nil end

    local able: { string } = {}
    for index, name in shape.names do
        if table.find (Generate.KEYED, shape.of[index].at) == nil then continue end
        table.insert (able, name)
    end

    if #able == 0 then return nil end
    return Rng.pick (rng, able)
end

--[[
    One field of an update. The key field draws from the partitions in play, so a migration lands on
    a key some audience was granted rather than on one nobody can see. An optional field is
    sometimes cleared, which is the one place `Lync.none` reaches a set, and never on a field that
    cannot take it.
]]
local function written (
    rng: Rng.Rng,
    shape: Generate.Shape,
    at: number,
    key: string?,
    parts: { any }
): any
    if shape.names[at] == key then return Rng.pick (rng, parts) end

    local child = shape.of[at]
    if child.at ~= "optional" then return Generate.value (child, rng) end
    if Rng.bool (rng, CLEARS) then return Lync.none end
    return Generate.value (child.of[1], rng)
end

--[[
    A legal run of one set's life, in the same step vocabulary the scripted scenarios use, so one
    driver replays a drawn run and a written one without knowing which it holds. Legality is the
    whole difficulty, since the surface throws on an add onto a live id and on four other shapes a
    draw could reach, so what is drawn is the shape of the run rather than the calls in it.
]]
local function drawn (rng: Rng.Rng, shape: Generate.Shape, key: string?): { Scenarios.Step }
    local parts = {}
    local at = if key ~= nil then table.find (shape.names, key) else nil
    if at ~= nil then
        for _ = 1, Rng.int (rng, 1, PARTS) do
            table.insert (parts, Generate.value (shape.of[at], rng))
        end
    end

    local free, watchers = {}, { "p1" }
    local live: { number } = {}
    local minted = 1
    for id = IDS, 1, -1 do
        table.insert (free, id)
    end

    local out = { step ({ act = "join" :: "join", who = "p1" }) }
    for _, part in parts do
        table.insert (out, step ({ act = "audience" :: "audience", key = part, who = "p1" }))
    end

    local marks = 0
    local function flushed ()
        marks += 1
        table.insert (out, step ({ act = "flush" :: "flush", mark = `flush-{marks}` }))
    end

    local function ways (): { string }
        local acts = {}
        if #free > 0 then table.insert (acts, "add") end
        if #live > 0 then
            table.insert (acts, "update")
            table.insert (acts, "remove")
            table.insert (acts, "clear")
        end
        if #watchers < WATCHING then table.insert (acts, "join") end
        if #watchers > 1 then table.insert (acts, "leave") end
        if #parts > 0 then table.insert (acts, "audience") end
        return acts
    end

    for _ = 1, Rng.int (rng, 1, ACTS) do
        local act = Rng.pick (rng, ways ())

        if act == "add" then
            local id = table.remove (free) :: number
            table.insert (live, id)

            local record = table.clone (Generate.value (shape, rng))
            if key ~= nil then record[key] = Rng.pick (rng, parts) end
            table.insert (out, step ({ act = "add" :: "add", id = id, record = record }))
        elseif act == "update" then
            local fields = {}
            for _ = 1, Rng.int (rng, 1, #shape.names) do
                local index = Rng.int (rng, 1, #shape.names)
                fields[shape.names[index]] = written (rng, shape, index, key, parts)
            end

            local id = Rng.pick (rng, live)
            table.insert (out, step ({ act = "update" :: "update", id = id, fields = fields }))
        elseif act == "remove" then
            local id = table.remove (live, Rng.int (rng, 1, #live)) :: number
            table.insert (free, id)
            table.insert (out, step ({ act = "remove" :: "remove", id = id }))
        elseif act == "clear" then
            table.move (live, 1, #live, #free + 1, free)
            table.clear (live)
            table.insert (out, step ({ act = "clear" :: "clear" }))
        elseif act == "join" then
            minted += 1
            local who = `p{minted}`
            table.insert (watchers, who)
            table.insert (out, step ({ act = "join" :: "join", who = who }))
        elseif act == "leave" then
            local who = table.remove (watchers, Rng.int (rng, 1, #watchers)) :: string
            table.insert (out, step ({ act = "leave" :: "leave", who = who }))
        else
            table.insert (
                out,
                step ({
                    act = "audience" :: "audience",
                    key = Rng.pick (rng, parts),
                    who = Rng.pick (rng, watchers),
                })
            )
        end

        if Rng.bool (rng, FLUSHES) then flushed () end
    end

    flushed ()
    return out
end

-- Public --------------------------------------------------------------

return {
    --[[
        Every scripted scenario, both sides, compared after every flush. These are the sequences a
        person wrote down because they are the ones worth being sure of, from a keyframe alone
        through a migration and a starved drain to the acceptance record over the whole vocabulary
        at once.
    ]]
    Harness.case ("conv.scenarios", function ()
        local driven = 0
        for _, of in Scenarios.all do
            if defers (of) then continue end
            driven += 1

            local run = staged (of)
            for _, at in of.steps do
                performed (run, at)
            end
        end
        Expect.holds (driven > 0, "every scenario defers, so nothing was compared in flight")
    end),

    --[[
        Any legal run of one set's life. Every client's view equals the records its audiences allow,
        and every callback it was handed equals the one the oracle says it was owed, after every
        flush rather than at the end.
    ]]
    Harness.property ("conv.replicates", "model", function (rng: Rng.Rng)
        local shape = Generate.record (rng)
        local key = partitioned (rng, shape)
        local run = opened (Generate.codec (shape), key)
        run.drains = true

        for _, of in drawn (rng, shape, key) do
            performed (run, of)
        end
    end),

    --[[
        `Scenarios.quiet` driven against the oracle, which is the one scenario whose whole claim is
        that nothing ships. Both machines still have to agree afterwards, so what this adds to the
        golden beside it is that costing nothing and saying nothing are the same run.
    ]]
    Harness.case ("conv.quiet", function ()
        local of = Scenarios.quiet
        local run = staged (of)

        for _, at in of.steps do
            local before = run.wire:moved ().frames
            performed (run, at)
            if at.act ~= "flush" then continue end
            if at.mark == "keyframe" then continue end

            local after = run.wire:moved ().frames
            Expect.holds (after == before, `the {at.mark} flush fired {after - before} frames`)
        end
    end),

    --[[
        More records than the smallest legal budget can carry. A starved flush ships the prefix that
        fits and holds the rest, so what deferral promises is that the end state is the same rather
        than the path to it, and this is the one place a run is checked at rest.
    ]]
    Harness.case ("conv.starved", function ()
        local driven = 0
        for _, of in Scenarios.all do
            if not defers (of) then continue end
            driven += 1

            local run = staged (of)
            for _, at in of.steps do
                if at.act ~= "flush" then
                    performed (run, at)
                    continue
                end

                shipped (run, at.budget)
                if at.budget == nil then continue end

                for _, held in run.clients do
                    local count, whole = #held.set, 0
                    for _ in Oracle.truth (run.oracle) do
                        whole += 1
                    end
                    Expect.holds (count > 0, `{of.name} at {at.budget} shipped none of {whole}`)
                    Expect.holds (count < whole, `{of.name} at {at.budget} shipped all {whole}`)
                end
            end

            for _, held in run.clients do
                drained (run, held)
                holding (run, held, `{of.name} drained`)
            end
        end
        Expect.holds (driven > 0, "no scenario flushes at a budget, so deferral is unchecked")
    end),
}
