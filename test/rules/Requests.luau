--!strict
--!optimize 2
-- A request that does not come back the ordinary way: the counterparty gone, the answer refused,
-- and too many of them at once.

local Codecs = require("@src/codec")
local Packet = require("@src/api/Packet")
local Protocol = require("@src/wire/Protocol")
local Query = require("@src/api/Query")
local Types = require("@src/Types")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Records = require("@test/harness/Records")
local Replica = require("@test/harness/Replica")

-- Two namespaces, because one claim is that a ceiling belongs to a namespace rather than to the
-- library. The second is opened only by the checks that need it.
local SPACE = "requests"
local BESIDE = "alongside"

-- The one client, which is the counterparty every request here is addressed to.
local SENDER = "alice"

-- Two queries, the second for its response codec, narrow enough for a responder to step outside
-- on purpose. A third whose responder comes apart instead of answering. A fourth a client asks,
-- so its responder is the side that is told who asked. A fifth no boundary will take.
local PLAIN = "plain"
local NARROW = "narrow"
local ANGRY = "angry"
local ASKED = "asked"
local TURNED = "turned"

-- What the angry responder raises, in words nothing else in the tree spells, and what the guard
-- turning a request away says.
local BROKEN = "the responder came apart"
local REFUSED = "the guard turned this request away"

-- What a request resolves as when its responder never answered.
local UNANSWERED: Types.OutcomeCode = "unanswered"

local TOP = 10
local BEYOND = 99
local CARRIED = true

-- One query carrying a number each way, wide enough that a burst can give every question a number
-- of its own, with a responder on either side that climbs, or comes apart on zero.
local COUNTED = "counted"
local WIDE = 99
local BREAKS = 0

-- One query whose answer is wide enough that a run of them cannot all fit one block.
local HEAVY = "heavy"
local SPELLED = 200
local ASKS = 20

-- Sizes of the bursts a check asks in one flush, and the two numbers asked both ways at once.
local MANY = 7
local MIXED = 6
local MINE = 4
local THEIRS = 9

-- One completion: whether it answered, what it answered, and the facts under a refusal.
type Done = { read ok: boolean, read code: unknown, read data: Types.OutcomeData? }

type Run = Replica.Paired

-- Private -------------------------------------------------------------

local function flag(): Types.Codec<boolean>
    return Codecs.bool()
end

-- Every query this file asks through, each for a situation none of the others produces.
local function defined(): any
    local guarded = flag():validate(function(): string?
        return REFUSED
    end)
    return {
        [PLAIN] = Query.new(flag(), flag()),
        [NARROW] = Query.new(flag(), Codecs.int(0, TOP)),
        [ANGRY] = Query.new(flag(), flag()),
        [ASKED] = Query.new(flag(), Codecs.int(0, TOP)),
        [TURNED] = Query.new(guarded, flag()),
    }
end

-- The client's responders, since the server is the side that asks here.
local function answering(defs: any, side: string)
    if side == "server" then return end
    defs[PLAIN]:onClient(function(): boolean
        return CARRIED
    end)
    defs[NARROW]:onClient(function(): number
        return BEYOND
    end)
    defs[ANGRY]:onClient(function(): boolean
        return error(BROKEN, 0)
    end)
    defs[TURNED]:onClient(function(): boolean
        return CARRIED
    end)
end

local function opened(space: string): Run
    return Replica.paired({ space = space, defined = defined, label = SENDER, wires = answering })
end

-- A request the server makes and does not wait for, and the list its completion writes to.
local function asking(of: Run, name: string): { Done }
    local done: { Done } = {}
    local function completed(ok: boolean, code: unknown, data: Types.OutcomeData?)
        table.insert(done, { ok = ok, code = code, data = data })
    end
    of.server.defs[name]:request(of.player, CARRIED, completed)
    return done
end

-- A question across and its answer back, which takes a flush from each machine.
local function exchanged(of: Run)
    of.server.session:flush()
    of.wire:settle()
    of.client.session:flush()
    of.wire:settle()
end

local function counts(): Run
    local function answer(value: number): number
        if value == BREAKS then error(REFUSED, 0) end
        return value + 1
    end
    return Replica.paired({
        space = BESIDE,
        defined = function(): any
            return { [COUNTED] = Query.new(Codecs.int(0, WIDE), Codecs.int(0, WIDE)) }
        end,
        label = SENDER,
        wires = function(defs: any, side: string)
            if side == "server" then
                defs[COUNTED]:onServer(answer)
            else
                defs[COUNTED]:onClient(answer)
            end
        end,
    })
end

local function weighs(): Run
    return Replica.paired({
        space = BESIDE,
        defined = function(): any
            return { [HEAVY] = Query.new(Codecs.int(0, ASKS), Codecs.str(0, SPELLED)) }
        end,
        label = SENDER,
        wires = function(defs: any, side: string)
            if side == "server" then return end
            defs[HEAVY]:onClient(function(value: number): string
                return string.rep("x", SPELLED - value)
            end)
        end,
    })
end

-- Public --------------------------------------------------------------

return {
    -- A responder that raises instead of answering, read from both ends. The machine it ran on
    -- keeps the fault with its trace, and the asker is told nobody answered.
    Harness.case("query.responder-throws", function()
        local of = opened(SPACE)
        local done: { Done } = {}
        local held = Records.made(function()
            done = asking(of, ANGRY)
            exchanged(of)
        end)

        local faults = {}
        for _, one in held do
            if one.kind == "error" then table.insert(faults, one.message) end
        end
        Expect.equal(#faults, 1)
        local said = faults[1]
        Expect.holds(string.find(said, BROKEN, 1, true) ~= nil, `the record reads {said}`)
        Expect.holds(#said > #BROKEN, "the record carries what was raised and no stack under it")

        Expect.equal(#done, 1)
        Expect.equal(done[1].ok, false)
        Expect.equal(done[1].code, UNANSWERED)
    end),

    -- The counterparty leaving while a request is in flight resolves it at once.
    Harness.case("query.leave", function()
        local of = opened(SPACE)
        local done = asking(of, PLAIN)
        Expect.equal(#done, 0)

        of.roster:leave(of.player)
        Expect.equal(#done, 1)
        Expect.equal(done[1].ok, false)
        Expect.equal(done[1].code, "leave")
        Expect.equal((done[1].data :: Types.OutcomeData).definition, PLAIN)
    end),

    -- A responder answering with a value its own response codec does not own is the responder's
    -- fault: reported with its trace on the machine that answered, and the request ends
    -- unanswered rather than waiting out its deadline.
    Harness.case("query.reply-out-of-range", function()
        local of = opened(SPACE)
        local done = asking(of, NARROW)
        of.server.session:flush()
        local held = Records.made(function()
            of.wire:settle()
        end)
        Expect.holds(#held > 0, "the refused reply was not reported")
        Expect.equal(held[1].kind, "error")
        Expect.holds(
            string.find(held[1].message, "expected", 1, true) ~= nil,
            `the report does not name the codec: {held[1].message}`
        )
        Expect.equal(#done, 0)
        exchanged(of)
        Expect.equal(#done, 1)
        Expect.equal(done[1].ok, false)
        Expect.equal(done[1].code, UNANSWERED)
    end),

    -- A second responder wired onto one query through the session's own guard.
    Harness.case("query.one-responder-wired", function()
        local of = opened(SPACE)
        local id = (of.client.defs[PLAIN] :: any).live.def.id
        Expect.throws(function()
            of.client.session:respond(id, PLAIN, function(): boolean
                return CARRIED
            end)
        end, "already has a responder")
    end),

    -- The client's call made on the server, and the server's call made on a client. The arity
    -- says which call was written and the side is what the machine already knew.
    Harness.case("query.wrong-side-server", function()
        local of = opened(SPACE)
        Expect.throws(function()
            of.server.defs[PLAIN]:request(CARRIED)
        end, "is a client's call, and this is the server")
    end),

    Harness.case("query.wrong-side-client", function()
        local of = opened(SPACE)
        Expect.throws(function()
            of.client.defs[PLAIN]:request(of.player, CARRIED, function() end)
        end, "is the server's call, and this is a client")
    end),

    -- More requests in flight at once than the id space has room for, and the ceiling belonging
    -- to the namespace rather than the library.
    Harness.case("query.cap", function()
        local of = opened(SPACE)
        local plain = of.server.defs[PLAIN]
        local function answered() end
        for _ = 1, Protocol.QUERY_CAP do
            plain:request(of.player, CARRIED, answered)
        end
        Expect.throws(function()
            plain:request(of.player, CARRIED, answered)
        end, "requests in flight")

        local beside = opened(BESIDE)
        local ok, why = pcall(function()
            beside.server.defs[PLAIN]:request(beside.player, CARRIED, answered)
        end)
        Expect.holds(ok, `a second namespace refused a request: {tostring(why)}`)
    end),

    -- A request the boundary turned away, which no responder is run for.
    Harness.case("query.turned-away-runs-no-responder", function()
        local asked = 0
        local of = Replica.paired({
            space = SPACE,
            defined = defined,
            label = SENDER,
            wires = function(defs: any, side: string)
                if side == "server" then return end
                defs[TURNED]:onClient(function(): boolean
                    asked += 1
                    return CARRIED
                end)
                defs[PLAIN]:onClient(function(): boolean
                    return CARRIED
                end)
            end,
        })

        for _, name in { PLAIN, TURNED } do
            Records.made(function()
                asking(of, name)
                exchanged(of)
            end)
            Expect.equal(asked, 0)
        end
    end),

    -- A request answered, read from the end that asked. The responder is the server's, so it is
    -- told the value and then who asked.
    Harness.case("query.answered", function()
        local whose: { Player } = {}
        local of = Replica.paired({
            space = SPACE,
            defined = defined,
            label = SENDER,
            wires = function(defs: any, side: string)
                if side ~= "server" then return end
                defs[ASKED]:onServer(function(value: boolean, who: Player): number
                    table.insert(whose, who)
                    Expect.equal(value, CARRIED)
                    return TOP
                end)
            end,
        })

        -- The client's form answers where it was called, so it is asked on a thread of its own.
        local held: any = nil
        coroutine.resume(coroutine.create(function()
            held = table.pack(of.client.defs[ASKED]:request(CARRIED))
        end))
        of.client.session:flush()
        of.wire:settle()
        of.server.session:flush()
        of.wire:settle()

        Expect.holds(held ~= nil, "a request the responder answered came back to nobody")
        Expect.equal(held[1], true)
        Expect.equal(held[2], TOP)
        Expect.equal(whose, { of.player })
    end),

    -- A burst of questions asked in one flush: every question is answered under its own id.
    Harness.case("query.burst-of-questions", function()
        local of = counts()
        local done: { boolean } = {}
        for index = 1, MANY do
            of.server.defs[COUNTED]:request(of.player, index, function(ok: boolean, held: unknown)
                done[index] = ok and held == index + 1
            end)
        end
        exchanged(of)
        for index = 1, MANY do
            Expect.holds(done[index], `the {index} of {MANY} was not answered with its own`)
        end
    end),

    -- Questions and answers over the one definition in the one flush, both aimed at the server.
    Harness.case("query.asking-while-answering", function()
        local of = counts()
        local theirs, mine = nil :: any, nil :: any
        of.server.defs[COUNTED]:request(of.player, THEIRS, function(_ok: boolean, held: unknown)
            theirs = held
        end)
        of.server.session:flush()
        of.wire:settle()

        -- A client asks by yielding, so its call is put on a thread and left parked.
        task.spawn(function()
            mine = select(2, of.client.defs[COUNTED]:request(MINE))
        end)
        of.client.session:flush()
        of.wire:settle()
        of.server.session:flush()
        of.wire:settle()

        Expect.equal(theirs, THEIRS + 1)
        Expect.equal(mine, MINE + 1)
    end),

    -- A responder that yields runs on a thread of its own: what the frame carried after its
    -- request is read at once, and its answer lands when it returns, behind answers to requests
    -- asked after it.
    Harness.case("query.yielding-responder-stalls-nothing", function()
        local heard: { number } = {}
        local of = Replica.paired({
            space = BESIDE,
            defined = function(): any
                return {
                    [COUNTED] = Query.new(Codecs.int(0, WIDE), Codecs.int(0, WIDE)),
                    [PLAIN] = Packet.new(Codecs.int(0, WIDE)),
                }
            end,
            label = SENDER,
            wires = function(defs: any, side: string)
                if side ~= "server" then return end
                defs[COUNTED]:onServer(function(value: number): number
                    if value % 2 == 1 then task.wait(0.03) end
                    return value + 1
                end)
                defs[PLAIN]:onServer(function(value: number)
                    table.insert(heard, value)
                end)
            end,
        })

        local answers: { [number]: number } = {}
        for value = 1, 4 do
            task.spawn(function()
                answers[value] = select(2, of.client.defs[COUNTED]:request(value))
            end)
        end
        of.client.defs[PLAIN]:fireServer(9)
        of.client.session:flush()
        of.wire:settle()

        -- The packet behind four requests, two of them parked, was heard in the same settle.
        Expect.equal(heard, { 9 })
        of.server.session:flush()
        of.wire:settle()
        Expect.equal(answers, { [2] = 3, [4] = 5 })

        task.wait(0.06)
        of.server.session:flush()
        of.wire:settle()
        Expect.equal(answers, { [1] = 2, [2] = 3, [3] = 4, [4] = 5 })
    end),

    -- A burst where every other question comes apart, so a run carrying one bit for all of its
    -- endings cannot pass by accident.
    Harness.case("query.burst-of-mixed-answers", function()
        local of = counts()
        local done: { boolean } = {}
        for index = 1, MIXED do
            local asks = if index % 2 == 0 then BREAKS else index
            of.server.defs[COUNTED]:request(of.player, asks, function(ok: boolean, held: unknown)
                done[index] = if asks == BREAKS then not ok else ok and held == index + 1
            end)
        end
        exchanged(of)
        for index = 1, MIXED do
            Expect.holds(done[index], `the {index} of {MIXED} was told the wrong ending`)
        end
    end),

    -- A run of answers too wide to share one block seals on the room it has left.
    Harness.case("query.answers-seal-on-the-room-left", function()
        local of = weighs()
        local done: { string } = {}
        for index = 1, ASKS do
            of.server.defs[HEAVY]:request(of.player, index, function(ok: boolean, held: unknown)
                if ok then done[index] = held :: string end
            end)
        end
        exchanged(of)
        for index = 1, ASKS do
            local said = done[index]
            Expect.holds(said ~= nil, `the {index} of {ASKS} was never answered`)
            Expect.equal(#said, SPELLED - index)
        end
    end),
}
