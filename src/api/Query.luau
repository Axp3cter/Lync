--!strict
--!optimize 2
-- The query handle: one responder a side, and a request that answers rather than throws or hangs.

local Base = require ("@src/codec/Base")
local Define = require ("@src/api/Define")
local Handles = require ("@src/runtime/Handles")
local Serial = require ("@src/shape/Serial")
local Types = require ("@src/Types")

local Query = {}
Query.__index = Query

-- Private -------------------------------------------------------------

-- The one responder this side gets, held until there is a dispatch to hand it to.
local function answers (self: any, said: string, fn: (...any) -> any)
    local live = self.live
    local under = Define.naming (live, said)

    local session = live.session
    if session ~= nil and session.started then
        Define.refuse (`{said} after {under} started, and start seals responders`, under)
    end

    if self.answering ~= nil then
        Define.refuse (`{under} already has a responder, and a query has one`, under)
    end

    self.answering = fn
    Handles.waiting (live, function (session) session:respond (live.id :: number, under, fn) end)
end

--[[
    A client's request, which yields until it is answered or told why it will not be. A third
    argument is the server form's completion and the client form has no third, so a call carrying
    one is the server's made on the wrong machine. The lookup below cannot refuse, the caller
    having branched on the side it tests, and what it is called for is the session.
]]
local function asked (
    self: any,
    value: any,
    timeout: number?,
    complete: any
): (boolean, any, Types.OutcomeData?)
    local session = Define.reach (self.live, "request", false)
    if complete ~= nil then
        Define.refuse (
            "request with a completion is the server's call, and this is a client",
            Define.naming (self.live, "request")
        )
    end

    local settled = false
    local parked: thread? = nil

    local ok: boolean
    local result: any
    local data: Types.OutcomeData?

    session:ask (self.live.def, nil, value, timeout, function (answered, gave, about)
        ok, result, data = answered, gave, about
        settled = true

        local held = parked
        if held ~= nil then task.spawn (held) end
    end)

    if not settled then
        parked = coroutine.running ()
        coroutine.yield ()
    end

    return ok, result, data
end

-- Public --------------------------------------------------------------

--[[
    Two builds and one handle, because a request and its reply are one agreement between two
    machines, and they share one definition and two consecutive ids.
]]
function Query.new <Q, R>(of: Types.Codec<Q>, reply: Types.Codec<R>): Types.Query<Q, R>
    --[[
        Level two is the caller rather than this frame, so a schema refused at start points at the
        declaration instead of the start that caught it.
    ]]
    local file, line = debug.info (2, "sl")
    local self = {
        kind = "query" :: "query",
        of = of,
        reply = reply,
        at = { file = file, line = line },
        live = Handles.live (),
        answering = nil :: ((...any) -> any)?,
    }

    return (setmetatable (self, Query) :: any) :: Types.Query<Q, R>
end

--[[
    The responder, on whichever side is answering.

    Two names for one registration, because what a responder is handed differs between the sides
    and what it is registered as does not.
]]
function Query.onServer (self: any, fn: (any, Player) -> any) answers (self, "onServer", fn) end

function Query.onClient (self: any, fn: (any) -> any) answers (self, "onClient", fn) end

--[[
    One request, in whichever of its two forms this machine has. Which form comes off the machine
    and never off the arguments, so a call before start names the namespace that has not opened
    rather than an argument. What the arguments say afterwards is whether the caller made the other
    side's call, which is the one mistake here that used to answer with somebody else's error.
]]
function Query.request (self: any, first: any, second: any, third: any, fourth: any): ...any
    if self.live.isServer then
        --[[
            The server form carries a completion and the client form has no third argument, so a
            call reaching here without one is the client's. The lookup below cannot refuse, the
            branch above having settled the side before it is asked, and what it is called for is
            the session and the namespace it names when there is none.
        ]]
        local session = Define.reach (self.live, "request", true)
        if typeof (third) ~= "function" then
            Define.refuse (
                "request without a completion is a client's call, and this is the server",
                Define.naming (self.live, "request")
            )
        end

        session:ask (self.live.def, first, second, fourth, third)
        return
    end

    return asked (self, first, second, third)
end

-- The schema as text, which is the wording a refused request is answered with.
function Query.describe (self: any): string
    return Serial.frame ({
        kind = "query",
        of = { cell = Base.cell (self.of) },
        reply = { cell = Base.cell (self.reply) },
    })
end

return table.freeze (Query)
