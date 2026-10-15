--!strict
-- A whole game against a model: players arriving and leaving around a server, sets, packets and
-- queries in both directions, hostile clients, all over a wire that behaves the way Roblox remotes
-- do, and the model asked after every settle what each machine should hold and should have heard.

local Catalog = require("@src/kernel/Catalog")
local Codecs = require("@src/codec")
local Log = require("@src/kernel/Log")
local Lync = require("@src")
local Session = require("@src/runtime/Session")
local Sync = require("@src/state/Sync")

local Doubles = require("@fixtures/Doubles")
local Faithful = require("@fixtures/Faithful")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")
local Shrink = require("@test/harness/Shrink")

-- Constants -----------------------------------------------------------

local SPACE = "stateful"

-- What one game holds at most: record ids, players present at once, players ever, operations.
local IDS = 6
local CROWD = 4
local EVER = 6
local STEPS = 36

-- Flushes a settle may take before it is called stuck, and how many silent ones in a row are rest.
-- A silent flush alone is not rest, since a record wider than a prorated budget waits for the next.
local ROUNDS = 64
local QUIET = 3

-- A query deadline no case can reach, since the clock a deadline runs on is the real one.
local PATIENCE = 1e6

-- How often a player leaves between two frames of a settle, and how often a responder parks.
local MIDWAY = 0.01
local PARKS = 0.3

-- Whether a trace carries every frame the wire fired and handed over, for reading one failure.
local FRAMES = false

-- The handshake's accepting verdict, as its first byte says it.
local VERDICT_BYTES = 9
local ACCEPT = 1

local CHANNELS: { Faithful.Channel } = { "handshake", "reliable", "unreliable" }
local NAMES = { "a", "bb", "ccc", "d" }

-- Every key codec a set may be split by, with the keys a game draws from.
local KEYINGS = {
    {
        name = "int",
        codec = function()
            return Codecs.int(0, 2)
        end,
        keys = { 0, 1, 2 },
    },
    {
        name = "enum",
        codec = function()
            return Codecs.enum({ "red", "green", "blue" })
        end,
        keys = { "red", "green", "blue" },
    },
    {
        name = "bool",
        codec = function()
            return Codecs.bool()
        end,
        keys = { true, false },
    },
    {
        name = "str",
        codec = function()
            return Codecs.str(0, 4)
        end,
        keys = { "", "a", "bb" },
    },
    {
        name = "vlq",
        codec = function()
            return Codecs.vlq()
        end,
        keys = { 0, 1, 300 },
    },
}

-- What each kind of game draws its operations from, and how often.
local WEIGHTS: { [string]: { [string]: number } } = {
    sets = {
        join = 2,
        start = 3,
        leave = 1,
        add = 6,
        update = 5,
        mutate = 4,
        silent = 1,
        none = 2,
        refuse = 1,
        migrate = 2,
        remove = 2,
        clear = 1,
        audience = 4,
        group = 2,
        flush = 4,
        deliver = 4,
        half = 2,
        starve = 1,
        overtake = 2,
        hostile = 1,
        settle = 2,
    },
    traffic = {
        join = 2,
        start = 3,
        leave = 1,
        add = 2,
        update = 1,
        audience = 1,
        group = 2,
        ping = 4,
        pose = 4,
        chat = 3,
        askOut = 3,
        askIn = 3,
        release = 2,
        flush = 3,
        clientFlush = 2,
        deliver = 4,
        half = 2,
        starve = 1,
        overtake = 2,
        hostile = 2,
        settle = 2,
    },
}

-- Types ---------------------------------------------------------------

type Grant = {
    kind: "all" | "one" | "list" | "group" | "except",
    label: string?,
    labels: { string }?,
    index: number?,
    inner: Grant?,
}

type Client = {
    label: string,
    player: Player,
    present: boolean,
    started: boolean,
    admitted: boolean,
    accepted: boolean,
    compromised: boolean,
    defs: any,
    set: any,
    session: any,
    shadow: { [number]: any },
    pings: { number },
    poses: { number },
    chats: { { n: number, who: Player? } },
    heard: number,
}

type Ping =
    { n: number, must: { [string]: boolean }, allowed: { [string]: boolean }, open: boolean }

type Ask = {
    serial: number,
    label: string,
    outward: boolean,
    unreachable: boolean,
    done: number,
    ok: boolean?,
    value: any,
}

type Run = {
    rng: Rng.Rng,
    trace: { string },
    kind: string,
    shared: boolean,
    rough: boolean,
    keyed: boolean,
    keying: any,
    keys: { any },
    wide: number,
    open: boolean,
    roster: Doubles.Roster,
    wire: Faithful.Wire,
    server: any,
    defs: any,
    set: any,
    truth: { [number]: any },
    handed: { [number]: { [string]: any } },
    grants: { [any]: Grant },
    groups: { { group: any, members: { [string]: boolean } } },
    clients: { [string]: Client },
    labels: { string },
    byPlayer: { [Player]: Client },
    minted: number,
    serial: number,
    pings: { Ping },
    poseHeld: { { to: any, grant: Grant, n: number } },
    poseSent: { [string]: { [number]: number } },
    poseLast: { [string]: number },
    poseAccepted: { [string]: number },
    flushes: number,
    asks: { Ask },
    heardChats: { { label: string, n: number, who: any } },
    parked: { thread },
    complaints: { string },
    refusing: boolean,
    hello: string?,
}

-- State ---------------------------------------------------------------

-- Whether a key nobody assigned an audience goes to everybody, read off the library once, since
-- the answer is changing from everybody to nobody and the model follows whichever is in the tree.
local unassignedOpen: boolean? = nil

-- Private -------------------------------------------------------------

local function note(run: Run, line: string)
    table.insert(run.trace, line)
end

local function deep(value: any): any
    if type(value) ~= "table" then return value end
    local out = {}
    for key, held in value do
        out[key] = deep(held)
    end
    return out
end

-- A structural comparison raised with what was being compared, so a failure names the machine.
local function same(what: string, got: any, want: any)
    local ok, thrown = pcall(Expect.equal, got, want)
    if ok then return end
    local failure = Expect.failed(thrown)
    Expect.holds(false, `{what}: {if failure ~= nil then failure.message else tostring(thrown)}`)
end

local function weighted(rng: Rng.Rng, weights: { [string]: number }): string
    local names = {}
    local total = 0
    for name, weight in weights do
        table.insert(names, name)
        total += weight
    end
    table.sort(names)
    local roll = rng:int(1, total)
    for _, name in names do
        roll -= weights[name]
        if roll <= 0 then return name end
    end
    return names[#names]
end

local function shown(value: any): string
    if type(value) == "string" then return `"{value}"` end
    return tostring(value)
end

-- Schema --------------------------------------------------------------

local function definitions(run: Run): any
    local record = Codecs.struct({
        team = if run.keyed then run.keying.codec() else Codecs.int(0, 2),
        hp = Codecs.int(0, 100),
        tag = Codecs.optional(Codecs.str(0, 8)),
        blob = Codecs.optional(Codecs.str(0, run.wide)),
        inv = Codecs.array(
            Codecs.struct({ item = Codecs.int(0, 9), qty = Codecs.int(0, 99) }),
            0,
            4
        ),
        stats = Codecs.optional(
            Codecs.map(Codecs.str(1, 3), Codecs.array(Codecs.int(0, 9), 0, 3), 0, 3)
        ),
        pos = Codecs.struct({ x = Codecs.int(0, 50), tags = Codecs.array(Codecs.int(0, 9), 0, 3) }),
    })
    local set: any = Lync.replicate(record)
    if run.keyed then set = set:keyBy("team") end
    local numbered = Codecs.struct({ n = Codecs.vlq() })
    return {
        records = set,
        ping = Lync.packet(numbered),
        pose = (Lync.packet(numbered) :: any):newest(),
        chat = Lync.packet(Codecs.struct({ n = Codecs.vlq(), who = Codecs.inst() })),
        ask = Lync.query(numbered, Codecs.struct({ who = Codecs.str(0, 8), n = Codecs.vlq() })),
    }
end

-- Whether the tree sends a key nobody assigned to everybody, asked of a game with one record.
local function probed(): boolean
    local wire = Doubles.wire()
    local roster = Doubles.roster()
    local function defs(): any
        return {
            records = (Lync.replicate(Codecs.struct({ team = Codecs.int(0, 2) })) :: any):keyBy(
                "team"
            ),
        }
    end
    local serverDefs = defs()
    local server = Session.new(`{SPACE}Probe`, serverDefs, wire:server(), roster, "server")
    server:start()
    local player = roster:join("probe")
    local clientDefs = defs()
    Session.new(`{SPACE}Probe`, clientDefs, wire:client(player), roster, "client"):start()
    wire:settle()
    serverDefs.records:add(1, { team = 1 })
    for _ = 1, 4 do
        server:flush()
        wire:settle()
    end
    return clientDefs.records:get(1) ~= nil
end

-- Values --------------------------------------------------------------

local function ints(rng: Rng.Rng, most: number): { number }
    local out = {}
    for index = 1, rng:int(0, most) do
        out[index] = rng:int(0, 9)
    end
    return out
end

local function inventory(rng: Rng.Rng): { any }
    local out = {}
    for index = 1, rng:int(0, 4) do
        out[index] = { item = rng:int(0, 9), qty = rng:int(0, 99) }
    end
    return out
end

local function stats(rng: Rng.Rng): { [string]: { number } }
    local out = {}
    for _ = 1, rng:int(0, 3) do
        out[rng:pick(NAMES)] = ints(rng, 3)
    end
    return out
end

local function blob(run: Run): string
    local rng = run.rng
    if run.wide > 16 and rng:bool(0.4) then
        return string.rep("x", rng:int(run.wide // 2, run.wide))
    end
    return string.rep("y", rng:int(0, 16))
end

-- One field's fresh value, which for an optional field is sometimes absent.
local function fresh(run: Run, name: string): any
    local rng = run.rng
    if name == "team" then return rng:pick(run.keys) end
    if name == "hp" then return rng:int(0, 100) end
    if name == "tag" then return if rng:bool() then string.rep("t", rng:int(0, 8)) else nil end
    if name == "blob" then return if rng:bool(0.5) then blob(run) else nil end
    if name == "inv" then return inventory(rng) end
    if name == "stats" then return if rng:bool(0.7) then stats(rng) else nil end
    return { x = rng:int(0, 50), tags = ints(rng, 3) }
end

local FIELDS = { "team", "hp", "tag", "blob", "inv", "stats", "pos" }
local OPTIONAL = { "tag", "blob", "stats" }
local TABLED = { "inv", "stats", "pos" }

local function record(run: Run): any
    local out = {}
    for _, name in FIELDS do
        out[name] = fresh(run, name)
    end
    return out
end

-- A record with one field its codec refuses, and which field that is. The key is never the one
-- refused, since a refused key would be a partition and not only a record.
local function refused(run: Run): (string, any)
    local rng = run.rng
    local roll = rng:int(1, 6)
    if roll == 1 then return "hp", 101 end
    if roll == 2 then return "tag", string.rep("t", 9) end
    if roll == 3 then
        local inv = inventory(rng)
        inv[1] = { item = 3, qty = 100 }
        return "inv", inv
    end
    if roll == 4 then return "pos", { x = -1, tags = {} } end
    if roll == 5 then return "stats", { a = { 1 }, bb = { 2 }, ccc = { 3 }, d = { 4 } } end
    return "hp", "many"
end

-- Recipients ----------------------------------------------------------

local function covers(run: Run, grant: Grant, label: string): boolean
    if grant.kind == "all" then return true end
    if grant.kind == "one" then return grant.label == label end
    if grant.kind == "list" then return table.find(grant.labels :: { string }, label) ~= nil end
    if grant.kind == "group" then
        return run.groups[grant.index :: number].members[label] == true
    end
    return not covers(run, grant.inner :: Grant, label)
end

local function described(grant: Grant): string
    if grant.kind == "all" then return "all" end
    if grant.kind == "one" then return grant.label :: string end
    if grant.kind == "list" then return `[{table.concat(grant.labels :: { string }, ",")}]` end
    if grant.kind == "group" then return `group{grant.index}` end
    return `except({described(grant.inner :: Grant)})`
end

local function recipient(run: Run, grant: Grant): any
    if grant.kind == "all" then return Lync.all end
    if grant.kind == "one" then return run.clients[grant.label :: string].player end
    if grant.kind == "list" then
        local out = {}
        for _, label in grant.labels :: { string } do
            table.insert(out, run.clients[label].player)
        end
        return out
    end
    if grant.kind == "group" then return run.groups[grant.index :: number].group end
    return Lync.except(recipient(run, grant.inner :: Grant))
end

local function present(run: Run): { string }
    local out = {}
    for _, label in run.labels do
        if run.clients[label].present then table.insert(out, label) end
    end
    return out
end

local function granted(run: Run, nested: boolean): Grant
    local rng = run.rng
    local roll = rng:int(1, if nested or #run.labels == 0 then 2 else 6)
    if #run.labels == 0 then roll = 1 end
    if roll == 1 then return { kind = "all" } end
    if roll == 2 and #run.labels > 0 then
        return { kind = "group", index = rng:int(1, #run.groups) }
    end
    if roll == 2 then return { kind = "all" } end
    if roll == 3 then
        local here = present(run)
        local from = if #here > 0 and rng:bool(0.8) then here else run.labels
        return { kind = "one", label = rng:pick(from) }
    end
    if roll == 4 then
        local labels = {}
        for _, label in run.labels do
            if rng:bool() then table.insert(labels, label) end
        end
        return { kind = "list", labels = labels }
    end
    if roll == 5 then return { kind = "group", index = rng:int(1, #run.groups) } end
    local inner: Grant = if rng:bool()
        then { kind = "one", label = rng:pick(run.labels) }
        else granted(run, true)
    return { kind = "except", inner = inner }
end

-- Who the server may reach: present, and admitted by a hello it read.
local function ready(client: Client): boolean
    return client.present and client.admitted
end

-- Whether a client should see the records under a key.
local function sees(run: Run, label: string, key: any): boolean
    if not run.keyed then return true end
    local grant = run.grants[key]
    if grant == nil then return run.open end
    return covers(run, grant, label)
end

-- Bounds every ping still waiting to be shipped holds to: whoever is covered at every moment
-- between its fire and its shipping must get it, and nobody covered at none of them may.
local function touched(run: Run)
    for _, ping in run.pings do
        if not ping.open then continue end
        local now = {}
        for _, label in run.labels do
            local client = run.clients[label]
            if ready(client) and covers(run, (ping :: any).grant, label) then now[label] = true end
        end
        for label in ping.must do
            if not now[label] then ping.must[label] = nil end
        end
        for label in now do
            ping.allowed[label] = true
        end
    end
end

-- Machines ------------------------------------------------------------

local function parking(run: Run)
    if not run.rng:bool(PARKS) then return end
    table.insert(run.parked, coroutine.running())
    coroutine.yield()
end

local function released(run: Run, count: number?)
    local many = math.min(count or #run.parked, #run.parked)
    for _ = 1, many do
        local thread = table.remove(run.parked, 1) :: thread
        task.spawn(thread)
    end
end

local function serverStarted(run: Run)
    if run.server ~= nil then return end
    local defs = definitions(run)
    run.defs = defs
    run.set = defs.records
    defs.ask:onServer(function(value: any, player: Player): any
        parking(run)
        return { who = player.Name, n = value.n }
    end)
    defs.chat:onServer(function(value: any, player: Player)
        table.insert(run.heardChats, { label = player.Name, n = value.n, who = value.who })
    end)
    run.server = Session.new(SPACE, defs, run.wire:server(), run.roster, "server")
    run.server:start()
    note(run, "server starts")
end

local function joined(run: Run)
    run.minted += 1
    local label = `p{run.minted}`
    local player = run.roster:join(label)
    local client: Client = {
        label = label,
        player = player,
        present = true,
        started = false,
        admitted = false,
        accepted = false,
        compromised = false,
        defs = nil,
        set = nil,
        session = nil,
        shadow = {},
        pings = {},
        poses = {},
        chats = {},
        heard = 0,
    }
    run.clients[label] = client
    run.byPlayer[player] = client
    table.insert(run.labels, label)
    note(run, `join {label}`)
end

local function started(run: Run, client: Client)
    local defs = definitions(run)
    client.defs = defs
    client.set = defs.records
    local shadow = client.shadow
    defs.records:onAdded(function(id: number, row: any)
        shadow[id] = deep(row)
    end)
    defs.records:onChanged(function(id: number, row: any)
        shadow[id] = deep(row)
    end)
    defs.records:onRemoved(function(id: number)
        shadow[id] = nil
    end)
    defs.ping:onClient(function(value: any)
        table.insert(client.pings, value.n)
    end)
    defs.pose:onClient(function(value: any)
        table.insert(client.poses, value.n)
    end)
    defs.ask:onClient(function(value: any): any
        parking(run)
        return { who = client.label, n = value.n }
    end)
    local session = Session.new(SPACE, defs, run.wire:client(client.player), run.roster, "client")
    client.session = session
    client.started = true
    session:start()
    note(run, `start {client.label}`)
end

local function left(run: Run, client: Client, midway: boolean)
    client.present = false
    for _, held in run.groups do
        held.members[client.label] = nil
    end
    run.roster:leave(client.player)
    touched(run)
    note(run, `leave {client.label}{if midway then " (between two frames)" else ""}`)
end

-- The newest packets the server holds, as the transmissions its next flush makes of them.
local function posed(run: Run)
    run.flushes += 1
    local flush = run.flushes
    for _, held in run.poseHeld do
        for _, label in run.labels do
            local client = run.clients[label]
            if not ready(client) or not covers(run, held.grant, label) then continue end
            run.poseSent[label] = run.poseSent[label] or {}
            run.poseSent[label][held.n] = flush
            run.poseLast[label] = flush
            if client.accepted then run.poseAccepted[label] = flush end
        end
    end
    table.clear(run.poseHeld)
end

local function serverFlushed(run: Run, budget: number?)
    serverStarted(run)
    touched(run)
    for _, ping in run.pings do
        ping.open = false
    end
    posed(run)
    run.server:flush(budget)
end

local function clientsFlushed(run: Run)
    for _, label in run.labels do
        local client = run.clients[label]
        if client.started and client.present then client.session:flush() end
    end
end

local function owing(run: Run): boolean
    for _, sync in run.server.sets do
        if Sync.owing(sync) then return true end
    end
    return false
end

local function between(run: Run): () -> ()
    return function()
        if not run.rng:bool(MIDWAY) then return end
        local here = present(run)
        if #here == 0 then return end
        left(run, run.clients[run.rng:pick(here)], true)
    end
end

-- Checks --------------------------------------------------------------

local function checkedSets(run: Run)
    local count = 0
    for id, want in run.truth do
        count += 1
        same(`server record {id}`, run.set:get(id), want)
    end
    Expect.holds(#run.set == count, `the server holds {#run.set} records, the model {count}`)

    for _, label in run.labels do
        local client = run.clients[label]
        if not client.started or not client.present or client.compromised then continue end
        Expect.holds(client.admitted, `{label} started and was never admitted`)
        Expect.holds(client.accepted, `{label} started and was never told it may send`)
        local held = 0
        for id, want in run.truth do
            if not sees(run, label, want.team) then continue end
            held += 1
            same(`{label} record {id} (key {shown(want.team)})`, client.set:get(id), want)
        end
        Expect.holds(#client.set == held, `{label} holds {#client.set} records, the model {held}`)
        local told = 0
        for id, row in client.set do
            told += 1
            same(`{label} callbacks for record {id}`, client.shadow[id], row)
        end
        for id in client.shadow do
            Expect.holds(client.set:get(id) ~= nil, `{label} was told of record {id} it lacks`)
        end
    end
end

local function checkedPackets(run: Run)
    for _, label in run.labels do
        local client = run.clients[label]
        if client.compromised then continue end
        local seen: { [number]: boolean } = {}
        local last = -1
        for _, n in client.pings do
            Expect.holds(not seen[n], `{label} heard ping {n} twice`)
            Expect.holds(n > last, `{label} heard ping {n} after ping {last}`)
            seen[n] = true
            last = n
        end
        local byN: { [number]: Ping } = {}
        for _, ping in run.pings do
            byN[ping.n] = ping
        end
        for n in seen do
            local ping = byN[n]
            Expect.holds(ping ~= nil and ping.allowed[label] == true, `{label} heard ping {n}`)
        end
        if client.present and client.started then
            for _, ping in run.pings do
                if ping.must[label] then
                    Expect.holds(seen[ping.n] == true, `{label} never heard ping {ping.n}`)
                end
            end
        end

        local sent = run.poseSent[label] or {}
        local at = 0
        for _, n in client.poses do
            local flush = sent[n]
            Expect.holds(flush ~= nil, `{label} heard pose {n}, which was never sent it`)
            Expect.holds(flush >= at, `{label} heard pose {n} of flush {flush} after flush {at}`)
            at = flush
        end
        local accepted = run.poseAccepted[label]
        if
            not run.rough
            and client.present
            and accepted ~= nil
            and accepted == run.poseLast[label]
        then
            Expect.holds(at == accepted, `{label} last heard a pose of flush {at}, not {accepted}`)
        end
    end

    for _, heard in run.heardChats do
        local client = run.clients[heard.label]
        if client.compromised then continue end
        local want = client.chats[client.heard + 1]
        Expect.holds(want ~= nil, `the server heard chat {heard.n} from {heard.label}, one extra`)
        Expect.holds(want.n == heard.n, `the server heard chat {heard.n} from {heard.label}`)
        Expect.holds(want.who == heard.who, `chat {heard.n} from {heard.label} names someone else`)
        client.heard += 1
    end
    table.clear(run.heardChats)
    for _, label in run.labels do
        local client = run.clients[label]
        if client.compromised or not client.present or not client.started then continue end
        local missing = #client.chats - client.heard
        Expect.holds(missing == 0, `the server never heard {missing} chats from {label}`)
    end
end

local function checkedAsks(run: Run)
    for _, ask in run.asks do
        local client = run.clients[ask.label]
        local what = `{if ask.outward then "question to" else "question from"} {ask.label}`
        Expect.holds(ask.done <= 1, `{what} #{ask.serial} resolved {ask.done} times`)
        if client.compromised then continue end
        if not ask.outward and not client.present then continue end
        Expect.holds(ask.done == 1, `{what} #{ask.serial} never resolved`)
        if not client.present or ask.unreachable then continue end
        Expect.holds(ask.ok == true, `{what} #{ask.serial} failed with {tostring(ask.value)}`)
        same(`{what} #{ask.serial}`, ask.value, { who = ask.label, n = ask.serial })
    end
end

local function checked(run: Run)
    Expect.holds(not owing(run), "the server still owes a catch-up at rest")
    for _, label in run.labels do
        local client = run.clients[label]
        local held = run.server.link.ready[client.player] == true
        Expect.holds(held == ready(client), `{label} is ready on the server: {held}`)
    end
    checkedSets(run)
    checkedPackets(run)
    checkedAsks(run)
    Expect.holds(#run.complaints == 0, `the library said: {run.complaints[1]}`)
end

local function settled(run: Run)
    serverStarted(run)
    note(run, "settle")
    local line = #run.trace
    local silent = 0
    local frames = 0
    for round = 1, ROUNDS do
        released(run)
        frames += run.wire:settle(between(run))
        local before = run.wire:fired()
        serverFlushed(run)
        clientsFlushed(run)
        frames += run.wire:settle(between(run))
        local quiet = run.wire:fired() == before and #run.parked == 0 and not owing(run)
        silent = if quiet then silent + 1 else 0
        if silent >= QUIET then break end
        Expect.holds(round < ROUNDS, `no rest after {ROUNDS} flushes`)
    end
    run.trace[line] = `settle ({frames} frames)`
    checked(run)
end

-- Operations ----------------------------------------------------------

local function live(run: Run): { number }
    local out = {}
    for id in run.truth do
        table.insert(out, id)
    end
    table.sort(out)
    return out
end

local function handedFrom(rec: any): { [string]: any }
    local out = {}
    for _, name in TABLED do
        out[name] = rec[name]
    end
    return out
end

-- One table a caller handed the set, changed in place somewhere inside it.
local function mutated(run: Run, name: string, value: any): string
    local rng = run.rng
    if name == "inv" then
        local roll = rng:int(1, 3)
        if roll == 1 and #value > 0 then
            value[rng:int(1, #value)].qty = rng:int(0, 99)
            return "inv[i].qty"
        elseif roll == 2 and #value < 4 then
            table.insert(value, { item = rng:int(0, 9), qty = rng:int(0, 99) })
            return "inv+"
        elseif #value > 0 then
            table.remove(value)
            return "inv-"
        end
        table.insert(value, { item = 1, qty = 1 })
        return "inv+"
    elseif name == "stats" then
        local roll = rng:int(1, 3)
        local keys = {}
        for key in value do
            table.insert(keys, key)
        end
        table.sort(keys)
        if roll == 1 and #keys > 0 then
            local list = value[rng:pick(keys)]
            if #list > 0 then
                list[rng:int(1, #list)] = rng:int(0, 9)
            else
                table.insert(list, rng:int(0, 9))
            end
            return "stats[k][j]"
        elseif roll == 2 and #keys > 0 then
            value[rng:pick(keys)] = nil
            return "stats-k"
        end
        if #keys < 3 then
            value[rng:pick(NAMES)] = ints(rng, 3)
            return "stats+k"
        end
        value[keys[1]] = nil
        return "stats-k"
    end
    if rng:bool() then
        value.x = rng:int(0, 50)
        return "pos.x"
    end
    if #value.tags > 0 and rng:bool() then
        value.tags[rng:int(1, #value.tags)] = rng:int(0, 9)
        return "pos.tags[i]"
    end
    if #value.tags < 3 then
        table.insert(value.tags, rng:int(0, 9))
        return "pos.tags+"
    end
    table.remove(value.tags)
    return "pos.tags-"
end

local function applied(run: Run, id: number, fields: { [string]: any })
    local now = run.truth[id]
    for name, value in fields do
        if value == Lync.none then
            now[name] = nil
            run.handed[id][name] = nil
        else
            now[name] = deep(value)
            if type(value) == "table" then run.handed[id][name] = value end
        end
    end
end

local function said(fields: { [string]: any }): string
    local out = {}
    for name, value in fields do
        local text = if value == Lync.none
            then "none"
            elseif type(value) == "string" then `#{#value}`
            elseif type(value) == "table" then "{..}"
            else tostring(value)
        table.insert(out, `{name}={text}`)
    end
    table.sort(out)
    return table.concat(out, ",")
end

local function hostile(run: Run)
    local rng = run.rng
    local here = present(run)
    if #here == 0 then return end
    -- Mostly the one attacker again, so a game keeps honest players to hold to the model.
    local guilty: { string } = {}
    for _, label in here do
        if run.clients[label].compromised then table.insert(guilty, label) end
    end
    local suspects = if #guilty > 0 and rng:bool(0.8) then guilty else here
    local attacker = run.clients[rng:pick(suspects)]
    attacker.compromised = true
    local at = rng:pick(CHANNELS)
    local other = run.clients[rng:pick(run.labels)].player
    local frames = run.wire:frames()
    local bytes: any, refs: any, what: string = nil, nil, ""
    local kind = rng:int(1, 6)
    if kind <= 2 and #frames > 0 then
        local from = frames[rng:int(1, #frames)]
        if typeof(from.bytes) == "buffer" then
            local size = buffer.len(from.bytes)
            bytes = buffer.create(size)
            buffer.copy(bytes, 0, from.bytes)
            refs = from.refs
            what = `replay #{from.serial} ({from.at})`
            if rng:bool() then at = from.at end
            local how = rng:int(1, 4)
            if how == 2 and size > 0 then
                local index = rng:int(0, size - 1)
                buffer.writeu8(
                    bytes,
                    index,
                    bit32.bxor(buffer.readu8(bytes, index), rng:int(1, 255))
                )
                what ..= " flipped"
            elseif how == 3 and size > 1 then
                local cut = buffer.create(rng:int(0, size - 1))
                buffer.copy(cut, 0, bytes, 0, buffer.len(cut))
                bytes = cut
                what ..= " cut"
            elseif how == 4 then
                local tail = rng:bytes(rng:int(1, 8))
                local longer = buffer.create(size + buffer.len(tail))
                buffer.copy(longer, 0, bytes)
                buffer.copy(longer, size, tail)
                bytes = longer
                what ..= " grown"
            end
        end
    end
    if bytes == nil and kind <= 4 then
        bytes = rng:bytes(rng:int(0, 24))
        if kind == 4 and buffer.len(bytes) > 0 then buffer.writeu8(bytes, 0, rng:int(0, 8)) end
        what = `{buffer.len(bytes)} drawn bytes`
    elseif bytes == nil then
        local odd: { any } = {
            "hostile",
            7,
            true,
            { 1, 2 },
            { { buffer.create(3) } },
            other,
            function() end,
            Vector3.new(1, 2, 3),
            math.huge,
            0 / 0,
        }
        local index = rng:int(0, #odd)
        bytes = odd[index]
        what = `a {typeof(bytes)}`
    end
    local roll = rng:int(1, 7)
    if refs == nil or rng:bool(0.3) then
        refs = if roll == 1
            then nil
            elseif roll == 2 then {}
            elseif roll == 3 then { { other } }
            elseif roll == 4 then { { 1, "x" } }
            elseif roll == 5 then { 5 }
            elseif roll == 6 then "refs"
            else { { attacker.player, other }, { other } }
    end
    run.wire:inject(attacker.player, at, bytes, refs)
    note(run, `hostile {attacker.label} {at} {what} refs={typeof(refs)}`)
end

local function asked(run: Run, client: Client)
    run.serial += 1
    local ask: Ask = {
        serial = run.serial,
        label = client.label,
        outward = true,
        unreachable = not ready(client),
        done = 0,
        ok = nil,
        value = nil,
    }
    table.insert(run.asks, ask)
    local wasReady = ready(client)
    run.defs.ask:request(client.player, { n = ask.serial }, function(ok: boolean, value: any)
        ask.done += 1
        ask.ok, ask.value = ok, value
    end, PATIENCE)
    note(run, `ask {client.label} #{ask.serial}{if wasReady then "" else " (unreachable)"}`)
    if wasReady then return end
    Expect.holds(ask.done == 1, `question #{ask.serial} to unreachable {client.label} is open`)
    Expect.holds(ask.ok == false and ask.value == "unanswered", `question #{ask.serial} answered`)
end

local function askedBy(run: Run, client: Client)
    run.serial += 1
    local ask: Ask = {
        serial = run.serial,
        label = client.label,
        outward = false,
        unreachable = false,
        done = 0,
        ok = nil,
        value = nil,
    }
    table.insert(run.asks, ask)
    local defs = client.defs
    task.spawn(function()
        local ok, value = defs.ask:request({ n = ask.serial }, PATIENCE)
        ask.done += 1
        ask.ok, ask.value = ok, value
    end)
    note(run, `{client.label} asks #{ask.serial}`)
end

local function performed(run: Run, act: string, chosen: any?)
    local rng = run.rng
    local ids = live(run)
    local here = present(run)
    if act == "join" then
        if #here < CROWD and run.minted < EVER then joined(run) end
    elseif act == "start" then
        local waiting = {}
        for _, label in here do
            if not run.clients[label].started then table.insert(waiting, label) end
        end
        if #waiting > 0 then started(run, run.clients[rng:pick(waiting)]) end
    elseif act == "leave" then
        if #here > 0 then left(run, run.clients[rng:pick(here)], false) end
    elseif act == "add" then
        if #ids >= IDS then return end
        local id = rng:int(1, IDS)
        if run.truth[id] ~= nil then return end
        local rec = record(run)
        run.set:add(id, rec)
        run.truth[id] = deep(rec)
        run.handed[id] = handedFrom(rec)
        note(run, `add {id} {said(rec)}`)
    elseif act == "update" or act == "none" then
        if #ids == 0 then return end
        local id = rng:pick(ids)
        local fields: { [string]: any } = {}
        for _, name in FIELDS do
            if name ~= "team" and rng:bool(0.4) then fields[name] = fresh(run, name) end
        end
        if act == "none" then fields[rng:pick(OPTIONAL)] = Lync.none end
        if next(fields) == nil then fields.hp = rng:int(0, 100) end
        run.set:update(id, fields)
        applied(run, id, fields)
        note(run, `update {id} {said(fields)}`)
    elseif act == "migrate" then
        if #ids == 0 then return end
        local id = rng:pick(ids)
        local key = rng:pick(run.keys)
        local fields: { [string]: any } = { team = key }
        if rng:bool() then fields.hp = rng:int(0, 100) end
        run.set:update(id, fields)
        applied(run, id, fields)
        note(run, `migrate {id} to {shown(key)}`)
    elseif act == "mutate" or act == "silent" then
        if #ids == 0 then return end
        local id = rng:pick(ids)
        local name = rng:pick(TABLED)
        local value = run.handed[id][name]
        if value == nil then return end
        local where = mutated(run, name, value)
        if act == "mutate" then
            run.set:update(id, { [name] = value })
            applied(run, id, { [name] = value })
        end
        note(run, `{if act == "mutate" then "mutate" else "mutate unsent"} {id} {where}`)
    elseif act == "refuse" then
        local name, value = refused(run)
        local adding = #ids == 0 or rng:bool()
        local id = if adding then rng:int(IDS + 1, IDS + 3) else rng:pick(ids)
        local ok
        if adding then
            local rec = record(run)
            rec[name] = value
            run.refusing = true
            ok = pcall(run.set.add, run.set, id, rec)
            run.refusing = false
            if ok then run.set:remove(id) end
            Expect.holds(run.set:get(id) == nil, `a refused add left record {id} behind`)
        else
            local fields: { [string]: any } = { [name] = value }
            if rng:bool() then fields.hp = if name == "hp" then 50 else rng:int(0, 100) end
            local before = deep(run.truth[id])
            run.refusing = true
            ok = pcall(run.set.update, run.set, id, fields)
            run.refusing = false
            if ok then
                local back = {}
                for field in fields do
                    back[field] = if before[field] == nil then Lync.none else deep(before[field])
                end
                run.set:update(id, back)
                applied(run, id, back)
            else
                same(`record {id} after a refused update`, run.set:get(id), before)
            end
        end
        note(
            run,
            `refuse {if adding then "add" else "update"} {id} {name} ({if ok
                then "taken, undone"
                else "thrown"})`
        )
    elseif act == "remove" then
        if #ids == 0 then return end
        local id = rng:pick(ids)
        run.set:remove(id)
        run.truth[id] = nil
        run.handed[id] = nil
        note(run, `remove {id}`)
    elseif act == "clear" then
        if #ids == 0 or not rng:bool(0.5) then return end
        run.set:clear()
        table.clear(run.truth)
        table.clear(run.handed)
        note(run, "clear")
    elseif act == "audience" then
        if not run.keyed then return end
        local key = if chosen ~= nil then chosen else rng:pick(run.keys)
        local grant = granted(run, false)
        run.set:audience(key, recipient(run, grant))
        run.grants[key] = grant
        note(run, `audience {shown(key)} {described(grant)}`)
    elseif act == "group" then
        if #run.labels == 0 then return end
        local index = rng:int(1, #run.groups)
        local held = run.groups[index]
        local label = rng:pick(run.labels)
        local player = run.clients[label].player
        if held.members[label] then
            held.group:remove(player)
            held.members[label] = nil
            note(run, `group{index} - {label}`)
        else
            held.group:add(player)
            held.members[label] = true
            note(run, `group{index} + {label}`)
        end
        touched(run)
    elseif act == "ping" then
        if #run.labels == 0 then return end
        run.serial += 1
        local grant = granted(run, false)
        local ping: any = { n = run.serial, must = {}, allowed = {}, open = true, grant = grant }
        for _, label in run.labels do
            local client = run.clients[label]
            if ready(client) and covers(run, grant, label) then
                ping.must[label] = true
                ping.allowed[label] = true
            end
        end
        table.insert(run.pings, ping)
        run.defs.ping:fireClient(recipient(run, grant), { n = ping.n })
        note(run, `ping #{ping.n} to {described(grant)}`)
    elseif act == "pose" then
        if #run.labels == 0 then return end
        local grant = granted(run, false)
        local to = recipient(run, grant)
        run.serial += 1
        local found = false
        for _, held in run.poseHeld do
            if held.to == to then
                held.n = run.serial
                found = true
            end
        end
        if not found then table.insert(run.poseHeld, { to = to, grant = grant, n = run.serial }) end
        run.defs.pose:fireClient(to, { n = run.serial })
        note(run, `pose #{run.serial} to {described(grant)}`)
    elseif act == "chat" then
        local able = {}
        for _, label in here do
            if run.clients[label].started then table.insert(able, label) end
        end
        if #able == 0 then return end
        local client = run.clients[rng:pick(able)]
        run.serial += 1
        local who = if rng:bool() then client.player else nil
        table.insert(client.chats, { n = run.serial, who = who })
        client.defs.chat:fireServer({ n = run.serial, who = who })
        note(run, `{client.label} chats #{run.serial}`)
    elseif act == "askOut" then
        if #run.labels == 0 then return end
        local reachable = {}
        for _, label in run.labels do
            if ready(run.clients[label]) then table.insert(reachable, label) end
        end
        local from = if #reachable > 0 and rng:bool(0.8) then reachable else run.labels
        asked(run, run.clients[rng:pick(from)])
    elseif act == "askIn" then
        local able = {}
        for _, label in here do
            if run.clients[label].started then table.insert(able, label) end
        end
        if #able == 0 then return end
        askedBy(run, run.clients[rng:pick(able)])
    elseif act == "release" then
        if #run.parked == 0 then return end
        local count = rng:int(1, #run.parked)
        released(run, count)
        note(run, `release {count} responders`)
    elseif act == "flush" then
        local budget = if rng:bool() then nil else rng:int(1024, 8192)
        serverFlushed(run, budget)
        note(run, `flush {budget or "unbudgeted"}`)
    elseif act == "clientFlush" then
        clientsFlushed(run)
        note(run, "clients flush")
    elseif act == "deliver" then
        local count = run.wire:deliver(rng:int(1, 8))
        note(run, `deliver {count}`)
    elseif act == "half" then
        local count = run.wire:deliver(rng:int(1, 3), function(frame: any, to: Player?): boolean
            return frame.at == "handshake" and to == nil
        end)
        note(run, `deliver {count} hellos and no verdicts`)
    elseif act == "overtake" then
        -- The hellos read, a flush, and its frames handed over while every verdict waits.
        local hellos = run.wire:deliver(3, function(frame: any, to: Player?): boolean
            return frame.at == "handshake" and to == nil
        end)
        serverFlushed(run)
        local count = run.wire:deliver(rng:int(1, 12), function(frame: any, to: Player?): boolean
            return frame.at ~= "handshake" or to == nil
        end)
        note(run, `{hellos} hellos read, a flush, and {count} frames ahead of the verdicts`)
    elseif act == "starve" then
        local count = run.wire:deliver(rng:int(1, 8), function(frame: any, to: Player?): boolean
            return frame.at ~= "handshake" or to == nil
        end)
        note(run, `deliver {count} with every verdict held`)
    elseif act == "hostile" then
        hostile(run)
    elseif act == "settle" then
        settled(run)
    end
end

-- A game ----------------------------------------------------------------

local function opened(rng: Rng.Rng, kind: string, shared: boolean, trace: { string }): Run
    if unassignedOpen == nil then unassignedOpen = probed() end
    local keying = rng:pick(KEYINGS)
    local roster = Doubles.roster()
    local run: Run
    local rough = rng:bool(0.5)
    local wire = Faithful.new({
        draw = rng,
        roster = roster,
        shared = shared,
        faults = if rough then Faithful.ROUGH else Faithful.CALM,
        guard = function(frame: Faithful.Frame, to: Player?): boolean
            local held = if to ~= nil then run.byPlayer[to] else nil
            return held ~= nil and held.compromised
        end,
        said = if FRAMES
            then function(line: string)
                table.insert(trace, `  {line}`)
            end
            else nil,
    })
    run = (
        {
            rng = rng,
            trace = trace,
            kind = kind,
            shared = shared,
            rough = rough,
            keyed = rng:bool(0.6),
            keying = keying,
            keys = keying.keys,
            wide = if rng:bool(0.3) then 1100 else 16,
            open = unassignedOpen :: boolean,
            roster = roster,
            wire = wire,
            server = nil,
            defs = nil,
            set = nil,
            truth = {},
            handed = {},
            grants = {},
            groups = {
                { group = Lync.group(), members = {} },
                { group = Lync.group(), members = {} },
            },
            clients = {},
            labels = {},
            byPlayer = {},
            minted = 0,
            serial = 0,
            pings = {},
            poseHeld = {},
            poseSent = {},
            poseLast = {},
            poseAccepted = {},
            flushes = 0,
            asks = {},
            heardChats = {},
            parked = {},
            complaints = {},
            refusing = false,
            hello = nil,
        } :: any
    ) :: Run
    if not run.keyed then run.keys = { 0, 1, 2 } end
    note(
        run,
        `{kind}, {if shared then "one reliable order" else "an order per remote"}, `
            .. `{if rough then "rough" else "calm"} lossy lane, `
            .. `{if run.keyed then `keyed by {keying.name}` else "unkeyed"}, blob {run.wide}, `
            .. `an unassigned key is {if run.open then "open" else "hidden"}`
    )

    -- Every frame the server fires is held to who may hear it at the moment it goes.
    wire:watch(function(frame: Faithful.Frame)
        if frame.from ~= nil then
            if frame.at == "handshake" and run.hello == nil and typeof(frame.bytes) == "buffer" then
                run.hello = buffer.tostring(frame.bytes)
            end
            return
        end
        if frame.at == "handshake" then return end
        local to = frame.to
        if to ~= nil then
            local client = run.byPlayer[to]
            Expect.holds(
                client ~= nil and client.present,
                `a {frame.at} frame went to one who left`
            )
            Expect.holds(client.admitted, `a {frame.at} frame went to {client.label} unadmitted`)
            return
        end
        for _, label in run.labels do
            local client = run.clients[label]
            if client.present then
                Expect.holds(client.admitted, `a {frame.at} broadcast reached unadmitted {label}`)
            end
        end
    end)

    -- What the server reads off the handshake decides who is admitted, and what a client reads
    -- decides who may send.
    wire:arrived(function(frame: Faithful.Frame, to: Player?)
        if typeof(frame.bytes) ~= "buffer" then return end
        if to == nil and frame.at ~= "handshake" then return end
        if to == nil then
            local client = run.byPlayer[frame.from :: Player]
            local valid = buffer.tostring(frame.bytes) == run.hello
            if client ~= nil and client.present and valid and not client.admitted then
                client.admitted = true
                touched(run)
            end
            return
        end
        local client = run.byPlayer[to]
        if frame.at ~= "handshake" then return end
        local bytes = frame.bytes :: buffer
        if buffer.len(bytes) == VERDICT_BYTES and buffer.readu8(bytes, 0) == ACCEPT then
            client.accepted = true
        end
    end)
    return run
end

-- Whatever the library says while a frame is handed over is held against whoever sent it: a
-- hostile frame, or a compromised machine on either end, may make it say anything.
local function listening(run: Run): Lync.Connection
    return Log.onLog(function(kind: string, message: string, data: any)
        -- A refusal the case asked for raises through the log on its way out.
        if run.refusing then return end
        local frame, to = run.wire:delivering()
        if frame ~= nil then
            if frame.hostile then return end
            local from = if frame.from ~= nil then run.byPlayer[frame.from] else nil
            local into = if to ~= nil then run.byPlayer[to] else nil
            if (from ~= nil and from.compromised) or (into ~= nil and into.compromised) then
                return
            end
        end
        local code = if data.code == Catalog.UNREADY then " (unready)" else ""
        table.insert(run.complaints, `{kind}{code}: {message}`)
    end)
end

local function played(rng: Rng.Rng, kind: string, shared: boolean, trace: { string })
    if Log.console.connected then Log.console:disconnect() end
    local run = opened(rng, kind, shared, trace)
    local link = listening(run)
    local ok, thrown = pcall(function()
        -- Players before the server, some of them started, then more after it, so most games
        -- have honest clients to hold to the model from the first settle.
        local function arrive(count: number)
            for _ = 1, count do
                joined(run)
                if rng:bool(0.75) then started(run, run.clients[run.labels[#run.labels]]) end
            end
        end
        arrive(rng:int(0, 2))
        if rng:bool(0.2) then hostile(run) end
        serverStarted(run)
        arrive(rng:int(0, 2))
        if run.keyed then
            for _, key in run.keys do
                if rng:bool(0.6) then performed(run, "audience", key) end
            end
        end
        local weights = WEIGHTS[kind]
        for _ = 1, rng:int(1, STEPS) do
            local act = weighted(rng, weights)
            performed(run, act)
            Expect.holds(#run.complaints == 0, `the library said: {run.complaints[1]}`)
        end
        settled(run)
    end)
    link:disconnect()
    released(run)
    for _, held in run.groups do
        held.group:destroy()
    end
    if not ok then error(thrown, 0) end
end

local function reason(thrown: unknown): string
    local failure = Expect.failed(thrown)
    return if failure ~= nil then failure.message else tostring(thrown)
end

-- A property that shrinks its own failure, so the trace printed beside the tape is the shrunk
-- game's rather than the first one's. A replay is the runner shrinking, and is left to it.
local function game(name: string, kind: string, shared: boolean): Harness.Declaration
    return Harness.property(name, "stateful", function(rng: Rng.Rng)
        local trace = {}
        local ok, thrown = pcall(played, rng, kind, shared, trace)
        if ok then return end
        if rng:seed() == 0 then error(thrown, 0) end

        local crash = Expect.failed(thrown) == nil
        local minimal = Shrink.run(rng:tape(), function(tape: { number }): boolean
            local again, raised = pcall(played, Rng.replay(tape), kind, shared, {})
            if again then return false end
            if string.find(tostring(raised), Rng.UNSETTLED, 1, true) ~= nil then return false end
            return (Expect.failed(raised) == nil) == crash
        end)
        local shrunk = {}
        local _, last = pcall(played, Rng.replay(minimal), kind, shared, shrunk)
        local lines = { reason(last), `shrunk tape: {table.concat(minimal, " ")}`, "steps:" }
        for index, line in shrunk do
            table.insert(lines, `  {index}. {line}`)
        end
        local text = table.concat(lines, "\n           ")
        if crash then error(text, 0) end
        Expect.holds(false, text)
    end)
end

-- The double itself ---------------------------------------------------

local function counted(into: { string }, label: string): (Player?, buffer, any) -> ()
    return function(_: Player?, bytes: buffer)
        table.insert(into, `{label}:{buffer.tostring(bytes)}`)
    end
end

return {
    -- The wire's own promises, so a failure below is about the library and not the double.
    Harness.case("stateful.faithful", function()
        local roster = Doubles.roster()
        local wire = Faithful.new({ draw = Rng.new(1), roster = roster, shared = true })
        local server = wire:server()
        server:open()
        local one = roster:join("one")
        local client = wire:client(one)
        client:open()
        local heard = {}

        -- A frame fired at a side with no listener waits for one.
        server:fire("reliable", one, buffer.fromstring("a"))
        Expect.equal(wire:settle(), 0)
        client:onReceive("reliable", counted(heard, "r"))
        client:onReceive("handshake", counted(heard, "h"))
        server:fire("handshake", one, buffer.fromstring("b"))
        server:fire("reliable", one, buffer.fromstring("c"))
        Expect.equal(wire:settle(), 3)
        Expect.equal(heard, { "r:a", "h:b", "r:c" })

        -- A broadcast reaches whoever is in the game when it goes, and a departure ends delivery.
        local two = roster:join("two")
        local other = {}
        local second = wire:client(two)
        second:onReceive("reliable", counted(other, "r"))
        server:fire("reliable", nil, buffer.fromstring("d"))
        roster:leave(one)
        server:fire("reliable", nil, buffer.fromstring("e"))
        wire:settle()
        Expect.equal(heard, { "r:a", "h:b", "r:c" })
        Expect.equal(other, { "r:d", "r:e" })

        -- The lossy lane refuses past its cap, and a client's frame carries who sent it.
        second:onReceive("unreliable", counted(other, "u"))
        server:fire("unreliable", two, buffer.create(Faithful.CAP + 1))
        server:fire("unreliable", two, buffer.fromstring("f"))
        local from: Player? = nil
        server:onReceive("reliable", function(sender: Player?)
            from = sender
        end)
        wire:inject(two, "reliable", "anything", { { 1 } })
        wire:settle()
        Expect.equal(other, { "r:d", "r:e", "u:f" })
        Expect.equal(from, two)
        Expect.equal(wire:frames()[#wire:frames() - 2].fate, "oversize")
    end),

    game("stateful.sets.remote", "sets", false),
    game("stateful.sets.shared", "sets", true),
    game("stateful.traffic.remote", "traffic", false),
    game("stateful.traffic.shared", "traffic", true),
}
