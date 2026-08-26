--!strict
--!optimize 2
--[[
    A request that does not come back the ordinary way: the counterparty gone, the answer refused,
    and too many of them at once.
]]

local Lync = require ("@src")
local Protocol = require ("@src/wire/Protocol")
local Types = require ("@src/Types")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Records = require ("@test/harness/Records")
local Replica = require ("@test/harness/Replica")

-- Constants -----------------------------------------------------------

--[[
    Two namespaces, because one of the three claims is that a ceiling belongs to a namespace rather
    than to the library. The second is opened only by the check that needs it.
]]
const SPACE = "requests"
const BESIDE = "alongside"

-- The one client, which is the counterparty every request here is addressed to.
const SENDER = "alice"

--[[
    Two queries, and the second exists for its response codec. A reply outside what the schema owns
    is a mistake a responder makes and nothing else here can produce, so the codec is narrow enough
    to step outside on purpose.
]]
const PLAIN = "plain"
const NARROW = "narrow"

--[[
    A third, whose responder does not answer because it comes apart instead.

    Its own definition rather than a responder swapped onto one of the others, because a responder
    is sealed at the start and the two above are what every other check here asks through.
]]
const ANGRY = "angry"

-- What it raises, in words nothing else in the tree spells, so a trace carrying them is this one.
const BROKEN = "the responder came apart"

-- What a request resolves as when its responder never answered.
const UNANSWERED: Types.OutcomeCode = "unanswered"

const TOP = 10

-- Wide enough that a burst can give every question of it a number of its own.
const WIDE = 99
const BEYOND = 99
const CARRIED = true

-- The one a client asks, so its responder is the side that is told who asked.
const ASKED = "asked"

-- A request no boundary will take, and what the guard turning it away says.
const TURNED = "turned"
const REFUSED = "the guard turned this request away"

-- Types ---------------------------------------------------------------

-- One completion: whether it answered, what it answered, and the facts under a refusal.
type Done = { read ok: boolean, read code: unknown, read data: Types.OutcomeData? }

type Run = Replica.Paired

-- Private -------------------------------------------------------------

--[[
    Three queries, and what each is for is its ending: one that answers, one whose response codec
    is narrow enough for a responder to step outside, and one whose responder comes apart.
]]
local function defined (): any
    return {
        [PLAIN] = Lync.query (Lync.bool (), Lync.bool ()),
        [NARROW] = Lync.query (Lync.bool (), Lync.int (0, TOP)),
        [ANGRY] = Lync.query (Lync.bool (), Lync.bool ()),
        [ASKED] = Lync.query (Lync.bool (), Lync.int (0, TOP)),
        [TURNED] = Lync.query (
            Lync.bool ():validate (function (): string? return REFUSED end),
            Lync.bool ()
        ),
    }
end

--[[
    Two machines on one lane, with both responders on the client, because the server is the side
    that asks here.
]]
local function opened (space: string): Run
    return Replica.paired ({
        space = space,
        defined = defined,
        label = SENDER,
        wires = function (defs: any, side: string)
            if side == "server" then return end

            defs[PLAIN]:onClient (function (): boolean return CARRIED end)
            defs[NARROW]:onClient (function (): number return BEYOND end)
            defs[ANGRY]:onClient (function (): boolean return error (BROKEN, 0) end)
            defs[TURNED]:onClient (function (): boolean return CARRIED end)
        end,
    })
end

--[[
    A request the server makes and does not wait for, and the list its completion writes to. Never
    yields, so whatever the check does next happens while the request is still in flight.
]]
local function asking (of: Run, name: string): { Done }
    local done: { Done } = {}

    of.server.defs[name]:request (
        of.player,
        CARRIED,
        function (ok: boolean, code: unknown, data: Types.OutcomeData?)
            table.insert (done, { ok = ok, code = code, data = data })
        end
    )
    return done
end

--[[
    One query carrying a number each way, and a responder on either side. Its own definition rather
    than one of those above, because a burst has to tell its answers apart and a bool cannot.
]]
const COUNTED = "counted"

local function counting (): any
    return { [COUNTED] = Lync.query (Lync.int (0, WIDE), Lync.int (0, WIDE)) }
end

local function counts (): Run
    return Replica.paired ({
        space = BESIDE,
        defined = counting,
        label = SENDER,
        wires = function (defs: any, side: string)
            --[[
                One responder, counting or coming apart, so a burst of answers carries both endings.
                Zero is what it comes apart on, every other number being answered by climbing, and
                it is registered on whichever side is the one that answers.
            ]]
            local function answer (value: number): number
                if value == 0 then error (REFUSED, 0) end

                return value + 1
            end

            if side == "server" then
                defs[COUNTED]:onServer (answer)
            else
                defs[COUNTED]:onClient (answer)
            end
        end,
    })
end

--[[
    One query whose answer is wide enough that a run of them cannot all fit one block. What that
    reaches is the other half of a run's sealing: it closes on the room left as well as on the
    count, and a run held to a width that is not its own would write past the buffer it is in.
]]
const HEAVY = "heavy"
const SPELLED = 200
const ASKS = 20

local function weighty (): any
    return { [HEAVY] = Lync.query (Lync.int (0, ASKS), Lync.str (0, SPELLED)) }
end

local function weighs (): Run
    return Replica.paired ({
        space = BESIDE,
        defined = weighty,
        label = SENDER,
        wires = function (defs: any, side: string)
            if side == "server" then return end

            defs[HEAVY]:onClient (
                function (value: number): string return string.rep ("x", SPELLED - value) end
            )
        end,
    })
end

-- Public --------------------------------------------------------------

return {
    --[[
        A responder that raises instead of answering, read from both ends, because the two are told
        different things. The machine it ran on keeps the fault and keeps the trace rather than the
        message, since a line reading only what was raised names the thing that went wrong and not
        the body it went wrong in.
    ]]
    Harness.case ("query.responder-throws", function ()
        local of = opened (SPACE)

        local done
        local held = Records.made (function ()
            done = asking (of, ANGRY)

            of.server.session:flush ()
            of.wire:settle ()

            -- The answer is the client's to send, and a request is only resolved once it lands.
            of.client.session:flush ()
            of.wire:settle ()
        end)

        local faults = {}
        for _, one in held do
            if one.kind == "error" then table.insert (faults, one.message) end
        end
        Expect.equal (#faults, 1)

        local said = faults[1]
        Expect.holds (string.find (said, BROKEN, 1, true) ~= nil, `the record reads {said}`)
        Expect.holds (#said > #BROKEN, "the record carries what was raised and no stack under it")

        Expect.equal (#(done :: any), 1)

        local back = (done :: any)[1]
        Expect.equal (back.ok, false)
        Expect.equal (back.code, UNANSWERED)
    end),

    --[[
        The counterparty leaving while a request is in flight. A request resolves exactly once, and
        left alone this one would sit until its deadline, holding a completion open past the moment
        the answer became impossible and firing into a session the caller already cleaned up.
    ]]
    Harness.case ("query.leave", function ()
        local of = opened (SPACE)
        local done = asking (of, PLAIN)

        Expect.equal (#done, 0)
        of.roster:leave (of.player)

        Expect.equal (#done, 1)
        Expect.equal (done[1].ok, false)
        Expect.equal (done[1].code, "leave")
        Expect.equal ((done[1].data :: Types.OutcomeData).definition, PLAIN)
    end),

    --[[
        A responder answering with a value its own response codec does not own, which is a
        programmer error rather than hostile input. A payload from the other machine is never
        trusted and never thrown for, but a reply is code on this machine returning what its own
        schema cannot carry.
    ]]
    Harness.case ("query.reply-out-of-range", function ()
        local of = opened (SPACE)
        local done = asking (of, NARROW)

        of.server.session:flush ()
        Expect.throws (function () of.wire:settle () end)

        pcall (function () of.wire:settle () end)
        Expect.equal (#done, 0)
    end),

    --[[
        A second responder wired onto one query through the session. The handle refuses this
        first, which is the refusal a caller meets. The session's own guard is the one under it,
        reached by whoever wires a namespace rather than declares one.
    ]]
    Harness.case ("query.one-responder-wired", function ()
        local of = opened (SPACE)
        local id = (of.client.defs[PLAIN] :: any).live.def.id

        Expect.throws (function ()
            of.client.session:respond (id, PLAIN, function (): boolean return CARRIED end)
        end, "already has a responder")
    end),

    --[[
        The client's call made on the server. A completion is the server form's third argument and
        the client form has no third, so the arity is what says which call was written and the side
        is what the machine already knew.
    ]]
    Harness.case ("query.wrong-side-server", function ()
        local of = opened (SPACE)

        Expect.throws (
            function () of.server.defs[PLAIN]:request (CARRIED) end,
            "is a client's call, and this is the server"
        )
    end),

    --[[
        And the server's call made on a client, the same reading the other way round. Both used to
        be answered by whatever stopped making sense first: the server took the completion for its
        response value and said its codec wanted a bool and got a function, which names neither the
        call that was made nor the machine it was made on.
    ]]
    Harness.case ("query.wrong-side-client", function ()
        local of = opened (SPACE)

        Expect.throws (function ()
            of.client.defs[PLAIN]:request (of.player, CARRIED, function () end)
        end, "is the server's call, and this is a client")
    end),

    --[[
        More requests in flight at once than the id space has room for. Ids are sixteen bits and the
        allocator advances past any still live, so past half the space it would have to reuse an id
        somebody is waiting on or walk forever looking for one.
    ]]
    Harness.case ("query.cap", function ()
        local of = opened (SPACE)
        local plain = of.server.defs[PLAIN]

        -- The completion nobody reads, because nothing here is ever answered.
        local function answered () end

        for _ = 1, Protocol.QUERY_CAP do
            plain:request (of.player, CARRIED, answered)
        end
        Expect.throws (
            function () plain:request (of.player, CARRIED, answered) end,
            "requests in flight"
        )

        local beside = opened (BESIDE)
        local other = beside.server.defs[PLAIN]

        local held, why = pcall (function () other:request (beside.player, CARRIED, answered) end)
        Expect.holds (held, `a second namespace refused a request: {tostring (why)}`)
    end),

    --[[
        A request the boundary turned away, which no responder is run for. A guard refusing the
        payload is this machine deciding the request said something the schema does not allow, so
        a responder run for it is one asked a question that never legally arrived, and whatever it
        answered would go back as though the request had been good.
    ]]
    Harness.case ("query.turned-away-runs-no-responder", function ()
        local asked = 0
        local of = Replica.paired ({
            space = SPACE,
            defined = defined,
            label = SENDER,
            wires = function (defs: any, side: string)
                if side == "server" then return end

                defs[TURNED]:onClient (function (): boolean
                    asked += 1
                    return CARRIED
                end)
                defs[PLAIN]:onClient (function (): boolean return CARRIED end)
            end,
        })

        Records.made (function ()
            asking (of, PLAIN)

            of.server.session:flush ()
            of.wire:settle ()
            of.client.session:flush ()
            of.wire:settle ()
        end)
        Expect.equal (asked, 0)

        Records.made (function ()
            asking (of, TURNED)

            of.server.session:flush ()
            of.wire:settle ()
            of.client.session:flush ()
            of.wire:settle ()
        end)
        Expect.equal (asked, 0)
    end),

    --[[
        A request answered, read from the end that asked. Every other check here is about a way one
        fails, and a library resolving each of those correctly while resolving none of the good ones
        would pass all of them. The responder is the server's, so it is told the value and then who
        asked, which is the pair the surface states and the only order a caller can rely on.
    ]]
    Harness.case ("query.answered", function ()
        local whose: { Player } = {}
        local of = Replica.paired ({
            space = SPACE,
            defined = defined,
            label = SENDER,
            wires = function (defs: any, side: string)
                if side ~= "server" then return end

                defs[ASKED]:onServer (function (value: boolean, who: Player): number
                    table.insert (whose, who)
                    Expect.equal (value, CARRIED)
                    return TOP
                end)
            end,
        })

        -- The client's form answers where it was called, so it is asked on a thread of its own.
        local held: any = nil
        local asking = coroutine.create (
            function () held = table.pack (of.client.defs[ASKED]:request (CARRIED)) end
        )
        coroutine.resume (asking)

        of.client.session:flush ()
        of.wire:settle ()
        of.server.session:flush ()
        of.wire:settle ()

        Expect.holds (held ~= nil, "a request the responder answered came back to nobody")
        Expect.equal (held[1], true)
        Expect.equal (held[2], TOP)
        Expect.equal (whose, { of.player })
    end),
    --[[
        A burst of questions asked in one flush. A run of them spells one header and then one id a
        question, and the answers come back the same way, so what this holds is that every question
        is answered, and answered under its own id rather than under the first one's.
    ]]
    Harness.case ("query.burst-of-questions", function ()
        const MANY = 7

        local of = counts ()
        local done: { boolean } = {}

        for index = 1, MANY do
            of.server.defs[COUNTED]:request (
                of.player,
                index,
                function (ok: boolean, held: unknown) done[index] = ok and held == index + 1 end
            )
        end

        of.server.session:flush ()
        of.wire:settle ()
        of.client.session:flush ()
        of.wire:settle ()

        for index = 1, MANY do
            Expect.holds (done[index], `the {index} of {MANY} was not answered with its own`)
        end
    end),

    --[[
        Questions and answers over the one definition in the one flush, which a client does when the
        server asked it something and it has something to ask back. Both are aimed at the server and
        both are that one query, so what keeps them from sharing a header is only what they are.
    ]]
    Harness.case ("query.asking-while-answering", function ()
        const MINE = 4
        const THEIRS = 9

        local of = counts ()
        local theirs, mine = nil :: any, nil :: any

        --[[
            The server asks first and the client answers where the question is taken, so the answer
            is already waiting on the client's lane when the client opens a question of its own. A
            client asks by yielding, so its call is put on a thread and left parked.
        ]]
        of.server.defs[COUNTED]:request (
            of.player,
            THEIRS,
            function (_ok: boolean, held: unknown) theirs = held end
        )
        of.server.session:flush ()
        of.wire:settle ()

        task.spawn (function () mine = select (2, of.client.defs[COUNTED]:request (MINE)) end)

        of.client.session:flush ()
        of.wire:settle ()
        of.server.session:flush ()
        of.wire:settle ()

        Expect.equal (theirs, THEIRS + 1)
        Expect.equal (mine, MINE + 1)
    end),
    --[[
        A burst where some questions are answered and some come apart. Every answer of a run says
        which question it answers by the step from the last, with the bit saying which ending it
        had folded into that step, so an ending read off the wrong one is an ending told to the
        wrong caller.
    ]]
    Harness.case ("query.burst-of-mixed-answers", function ()
        const MANY = 6

        local of = counts ()
        local done: { boolean } = {}

        --[[
            Every other one asks nothing, which is what the responder comes apart on. The answers
            alternate, so a run carrying one bit for all of them cannot pass by accident.
        ]]
        for index = 1, MANY do
            local asks = if index % 2 == 0 then 0 else index

            of.server.defs[COUNTED]:request (
                of.player,
                asks,
                function (ok: boolean, held: unknown)
                    done[index] = if asks == 0 then not ok else ok and held == index + 1
                end
            )
        end

        of.server.session:flush ()
        of.wire:settle ()
        of.client.session:flush ()
        of.wire:settle ()

        for index = 1, MANY do
            Expect.holds (done[index], `the {index} of {MANY} was told the wrong ending`)
        end
    end),
    --[[
        A run of answers too wide to share one block. A run seals on the room it has left as well
        as on how many it holds, and the width it measures against has to be its own: a run of
        answers held to a fire's or to nothing would keep writing into a buffer already full.
    ]]
    Harness.case ("query.answers-seal-on-the-room-left", function ()
        local of = weighs ()
        local done: { string } = {}

        for index = 1, ASKS do
            of.server.defs[HEAVY]:request (of.player, index, function (ok: boolean, held: unknown)
                if ok then done[index] = held :: string end
            end)
        end

        of.server.session:flush ()
        of.wire:settle ()
        of.client.session:flush ()
        of.wire:settle ()

        for index = 1, ASKS do
            local said = done[index]
            Expect.holds (said ~= nil, `the {index} of {ASKS} was never answered`)
            Expect.equal (#said, SPELLED - index)
        end
    end),
}
