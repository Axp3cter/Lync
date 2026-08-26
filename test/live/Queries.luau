--!strict
--!optimize 2
-- Both directions of a request, and every way one ends that two machines can arrange.

local Players = game:GetService ("Players")
local RunService = game:GetService ("RunService")

local Lync = require ("@src")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

const NAMESPACE = "queries"

--[[
    How long a check holds the floor. Long enough for a round trip, a deadline short enough to sit
    inside one, and a few frames either side, and no longer: a span is spent whether the check fills
    it or not, and there are ten of them here.
]]
const SPAN = 3
const WAITED = 15

-- The deadline a caller passes here, and the one the surface uses when nobody does.
const SHORTER = 1
const DEFAULT = 10

--[[
    How long a half waits inside its span for something the other machine owes. Short of the span,
    so a reply that never comes reports itself rather than running the clock out and reading as a
    check that did nothing.
]]
const PATIENCE = 2

-- What a responder doubles, and the request that reaches it.
const ASKED = 21
const ANSWERED = 42

-- The one request the picky query turns away, which is how a drop is arranged.
const REFUSED = 99

--[[
    A request the responder side refuses on arrival. A validate is a decode-time check, so the value
    encodes and travels and is turned away at the far end, which is the only way a suite can make a
    request that is received and never answered.
]]
const PICKY = Lync.int (0, 100):validate (
    function (value: number): string? return if value == REFUSED then "not that one" else nil end
)

-- A reply carrying a refusal of its own, which is a value in the codec and not an outcome.
const VERDICT = table.freeze ({ denied = true, amount = 0 })

--[[
    One query per outcome. A responder is registered once for the life of the library, so the query
    that answers cannot be the query nobody answers, and a suite sharing one between two checks
    would be a suite whose second check depends on what its first one did.
]]
const DEFINITIONS = table.freeze ({
    answers = Lync.query (Lync.int (0, 100), Lync.int (0, 200)),
    asks = Lync.query (Lync.int (0, 100), Lync.int (0, 200)),
    silent = Lync.query (Lync.int (0, 100), Lync.int (0, 200)),
    nobody = Lync.query (Lync.int (0, 100), Lync.int (0, 200)),
    picky = Lync.query (PICKY, Lync.int (0, 200)),
    fails = Lync.query (
        Lync.int (0, 100),
        Lync.struct ({ denied = Lync.bool (), amount = Lync.int (0, 200) })
    ),
})

-- Every query above, for the two checks whose claim is about all of them at once.
const EVERY = table.freeze ({ "answers", "asks", "silent", "nobody", "picky", "fails" })

-- The responders ------------------------------------------------------

--[[
    A responder belongs to the handle and not to an occasion, so every check below reads a library
    wired the way a caller would have wired it. The surface requires them before `start`, which a
    module body is, and the runner starts once for everything.
]]
if RunService:IsServer () then
    DEFINITIONS.answers:onServer (function (value: number): number return value * 2 end)

    DEFINITIONS.silent:onServer (function (): number
        while true do
            task.wait (1)
        end
    end)

    DEFINITIONS.picky:onServer (function (value: number): number return value * 2 end)
    DEFINITIONS.fails:onServer (function (): any return VERDICT end)
else
    DEFINITIONS.asks:onClient (function (value: number): number return value * 2 end)

    DEFINITIONS.silent:onClient (function (): number
        while true do
            task.wait (1)
        end
    end)
end

-- Private -------------------------------------------------------------

local function handle (name: string): any return (DEFINITIONS :: any)[name] end

-- A request asked on a thread of its own, and a reader for what it answered.
local function asking (name: string, value: any, timeout: number?): () -> any?
    local held: any = nil
    task.spawn (function () held = table.pack (handle (name):request (value, timeout)) end)
    return function () return held end
end

-- What a request answered, once it has, with the moment it was asked.
local function answered (what: string, of: () -> any?, patience: number): (any, number)
    local from = os.clock ()
    Harness.awaits (what, function () return of () ~= nil end, patience)
    return of () :: any, os.clock () - from
end

-- A half with nothing of its own to do, which is every server half that only has to serve.
local function serving (seconds: number): () -> ()
    return function ()
        Harness.together (seconds, NAMESPACE, function () end)
    end
end

-- Public --------------------------------------------------------------

return {
    Harness.opens (NAMESPACE, DEFINITIONS :: any),

    --[[
        A request from the client, answered by the server. The plainest thing a query does, and the
        one every other check here is a departure from: the call yields where it was made and comes
        back with the reply beside a true, rather than with a code a caller has to read.
    ]]
    Harness.pair ("query.client-yields", serving (SPAN), function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local held = answered ("the reply", asking ("answers", ASKED), PATIENCE)

            Expect.equal (held[1], true)
            Expect.equal (held[2], ANSWERED)
        end)
    end),

    --[[
        A request from the server, answered by the client. The server never yields, so the reply
        arrives at a callback instead, and the claim is that it runs once and carries what the far
        side returned.
    ]]
    Harness.pair ("query.server-callback", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local players = Players:GetPlayers ()
            local ran, wrong = 0, {}

            for _, player in players do
                DEFINITIONS.asks:request (player, ASKED, function (ok: boolean, res: any)
                    ran += 1
                    if ok and res == ANSWERED then return end
                    table.insert (wrong, `{player.Name} got {tostring (ok)} {tostring (res)}`)
                end)
            end

            Harness.awaits ("every reply", function () return ran >= #players end, PATIENCE)
            Expect.holds (#wrong == 0, table.concat (wrong, ", "))
            Expect.equal (ran, #players)
        end)
    end, serving (SPAN)),

    --[[
        A responder that never returns, and the deadline that ends the wait for it. The outcome is a
        code and a record rather than a raise, which is what lets a caller branch on it, and the
        record names the definition so a caller with twenty of them knows which one went quiet.
    ]]
    Harness.pair ("query.timeout", serving (SPAN), function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local held = answered ("the deadline", asking ("silent", ASKED, SHORTER), PATIENCE)

            Expect.equal (held[1], false)
            Expect.equal (held[2], "timeout")
            Expect.equal (held[3].definition, "silent")
            Expect.holds (held[3].elapsed >= SHORTER, `elapsed reads {held[3].elapsed}`)
        end)
    end),

    --[[
        The deadline nobody passed, which the surface sets at ten seconds. Worth the span it costs:
        it is the number every caller who never thinks about timeouts is relying on, and a library
        that quietly shortened it would turn a slow responder into a failure the caller never asked
        to see.
    ]]
    Harness.pair ("query.timeout-default", serving (WAITED), function ()
        Harness.together (WAITED, NAMESPACE, function ()
            local of = asking ("silent", ASKED)
            local held, spent = answered ("the default deadline", of, DEFAULT + PATIENCE)

            Expect.equal (held[1], false)
            Expect.equal (held[2], "timeout")
            Expect.holds (spent >= DEFAULT, `the default deadline passed after {spent} s`)
        end)
    end),

    --[[
        The deadline a caller passed instead. Held from both ends: it has to have passed, so a
        library ignoring the argument and answering at once fails, and it has to have passed well
        short of the default, so one ignoring it the other way fails too.
    ]]
    Harness.pair ("query.timeout-override", serving (SPAN), function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local of = asking ("silent", ASKED, SHORTER)
            local held, spent = answered ("the passed deadline", of, PATIENCE)

            Expect.equal (held[2], "timeout")
            Expect.holds (spent >= SHORTER, `the deadline passed after {spent} s`)
            Expect.holds (spent < DEFAULT, `the deadline passed after {spent} s, not {SHORTER}`)
        end)
    end),

    --[[
        A query the other side registered no responder for. The one failure a requester cannot
        infer, and the reason it earns a code of its own: every other silence is indistinguishable
        from a slow answer, and this one is a wiring mistake the far side can see immediately.
    ]]
    Harness.pair ("query.unanswered", serving (SPAN), function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local of = asking ("nobody", ASKED)
            local held, spent = answered ("the refusal", of, PATIENCE)

            Expect.equal (held[1], false)
            Expect.equal (held[2], "unanswered")
            Expect.equal (held[3].definition, "nobody")
            Expect.holds (
                spent < DEFAULT,
                `it took {spent} s, which is the deadline and not at once`
            )
        end)
    end),

    --[[
        A request the far side turns away. Nothing is sent back, and that is the point rather than
        an omission: answering would confirm receipt of hostile input to whoever sent it, so a drop
        looks to the requester exactly like a responder that never answered.
    ]]
    Harness.pair ("query.drop-is-silent", serving (SPAN), function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local of = asking ("picky", REFUSED, SHORTER)
            local held = answered ("the deadline", of, PATIENCE)

            Expect.equal (held[1], false)
            Expect.equal (held[2], "timeout")
        end)
    end),

    --[[
        A responder that answers a refusal. The reply is a value in the response codec, so it
        arrives beside a true and a caller reads their own field rather than a code: insufficient
        funds is a thing their game decided, and an outcome code is a thing the transport decided.
    ]]
    Harness.pair ("query.domain-failure", serving (SPAN), function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local held = answered ("the refusal", asking ("fails", ASKED), PATIENCE)

            Expect.equal (held[1], true)
            Expect.equal (held[2], VERDICT)
        end)
    end),

    --[[
        Every query in the file, asked at once, and none of them raises. This is the promise that
        lets a caller write `request` without a pcall around it, and it holds across every ending
        the others take one at a time: a reply, a deadline, a query nobody answers, a request turned
        away.
    ]]
    Harness.pair ("query.never-throws", serving (SPAN), function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local raised = {}

            for _, name in EVERY do
                task.spawn (function ()
                    local ok, thrown = pcall (handle (name).request, handle (name), ASKED, SHORTER)
                    if ok then return end
                    table.insert (raised, `{name}: {tostring (thrown)}`)
                end)
            end

            task.wait (SHORTER + 1)
            Expect.holds (#raised == 0, table.concat (raised, ", "))
        end)
    end),

    --[[
        Every query in the file, asked from the side that does not yield, and every one resolves
        exactly once. The callback is where a resolution can be counted, since a second resume of a
        thread that already returned is an error rather than an observation.
    ]]
    Harness.pair ("query.never-hangs", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local players = Players:GetPlayers ()
            local ran: { [string]: number } = {}

            for _, name in EVERY do
                ran[name] = 0
                for _, player in players do
                    handle (name):request (player, ASKED, function ()
                        ran[name] += 1
                    end, SHORTER)
                end
            end

            task.wait (SHORTER + 1)

            local wrong = {}
            for _, name in EVERY do
                if ran[name] == #players then continue end
                table.insert (wrong, `{name} resolved {ran[name]} of {#players}`)
            end
            Expect.holds (#wrong == 0, table.concat (wrong, ", "))
        end)
    end, serving (SPAN)),
}
