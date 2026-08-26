--!strict
--!optimize 2
-- What a handle is bound to, and what it was asked to do before there was anything to bind it to.

local Types = require ("@src/Types")

local Handles = {}

-- Types ---------------------------------------------------------------

-- What a handle knows about where it ended up, which is nothing until it is told.
export type Live = {
    space: string?,
    name: string?,
    id: number?,
    def: any,
    session: any,
    isServer: boolean,
    waiting: { (any) -> () },
}

-- An attachment made before there was anything to attach to.
export type Waiting = {
    connected: boolean,
    held: Types.Connection?,
}

-- Private -------------------------------------------------------------

--[[
    A connection to something that does not exist yet, ended the same way as one that does.

    A metatable rather than a closure per attachment, because a handle may be listened to as often
    as a caller likes and the pair of fields is the whole of what one of these is.
]]
local Attached = {}
Attached.__index = Attached

function Attached.disconnect (self: Waiting)
    self.connected = false

    local held = self.held
    if held ~= nil then held:disconnect () end
end

-- Public --------------------------------------------------------------

--[[
    A fresh binding, which every handle is made holding one of.

    Made by the handle rather than here, and typed here, because what fills it is the calls below
    and nothing a caller can reach.
]]
function Handles.live (): Live
    return {
        space = nil,
        name = nil,
        id = nil,
        def = nil,
        session = nil,
        isServer = false,
        waiting = {},
    }
end

--[[
    Something to do to this handle once there is a session to do it with.

    Run now where there is one and held where there is not, so a caller who attaches before a
    namespace opens and one who attaches after are asking for the same thing and get it.
]]
function Handles.waiting (of: Live, run: (any) -> ())
    local session = of.session
    if session ~= nil then
        run (session)
        return
    end

    table.insert (of.waiting, run)
end

-- A listener attached whenever the caller liked, and the connection that ends it either way.
function Handles.later (of: Live, bind: (any) -> Types.Connection): Types.Connection
    local session = of.session
    if session ~= nil then return bind (session) end

    local held: Waiting = setmetatable ({ connected = true, held = nil }, Attached) :: any
    table.insert (of.waiting, function (opened: any)
        if not held.connected then return end
        held.held = bind (opened)
    end)

    return (held :: any) :: Types.Connection
end

--[[
    A handle, bound to what its namespace compiled it into, and everything it was owed since.

    The binding is written before anything waiting runs, because what waits is listeners and
    responders and both of them reach back through the handle for the id they attach under.
]]
function Handles.opened (of: Live, def: any, session: any, isServer: boolean)
    of.id = def.id
    of.def = def
    of.session = session
    of.isServer = isServer

    for _, run in of.waiting do
        run (session)
    end
    table.clear (of.waiting)
end

return table.freeze (Handles)
