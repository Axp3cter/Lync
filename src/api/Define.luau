--!strict
--!optimize 2
-- A namespace declared: the names under it, and where a handle finds what it was bound to.

local Handles = require ("@src/runtime/Handles")
local Legality = require ("@src/shape/Legality")
local Log = require ("@src/kernel/Log")
local Order = require ("@src/shape/Order")
local Session = require ("@src/runtime/Session")
local Types = require ("@src/Types")

local Define = {}

-- Types ---------------------------------------------------------------

--[[
    The binding a handle carries, named here because this is where a caller's half of it is
    written. A session fills the other half, so the record itself is not declared here.
]]
export type Live = Handles.Live

-- One namespace as declared, before anything has been compiled from it.
export type Space = {
    read name: string,
    read defs: Types.Definitions,
    read names: { string },
}

-- State ---------------------------------------------------------------

--[[
    Every namespace declared here, the order they were declared in, and whether start has closed
    the list to any more.
]]
local spaces: { [string]: Space } = {}
local order: { string } = {}
local sealed = false

-- Private -------------------------------------------------------------

local function refuse (said: string, name: string): never
    return Log.error (said, { definition = name })
end

-- What a message calls a definition. Both halves, since either alone names several.
local function called (of: Live): string return `{of.space}.{of.name}` end

-- Public --------------------------------------------------------------

Define.spaces = spaces
Define.order = order
Define.refuse = refuse

-- The space and the name where the handle has one, and only the call's own where it does not.
function Define.naming (of: Live, said: string): string
    if of.space == nil then return said end
    return called (of)
end

-- A modifier, refused once the namespace it is in has been started.
function Define.declaring (of: Live, said: string)
    if of.session == nil then return end

    refuse (
        `{said} was called after {of.space} started, and a declaration is not a setting`,
        called (of)
    )
end

--[[
    The session a handle talks through, refused where there is none yet, where one has closed, and
    where the call is the other machine's. A side is a question about the place rather than about
    the session, so it is asked here beside the rest: a wrapper apiece would pay a second call to
    reach what this already holds, on every fire and every update a place makes.
]]
function Define.reach (of: Live, said: string, server: boolean): Session.Session
    local session = of.session
    if session == nil then
        if of.space == nil then
            refuse (`{said} before it was named in a namespace, which define is for`, said)
        end
        refuse (`{said} before {of.space} was started`, called (of))
    end

    local held = session :: Session.Session
    if held.closed then
        refuse (`{said} after {of.space} was closed, and close lets its remotes go`, called (of))
    end

    if of.isServer ~= server then
        local whose = if server then "the server's" else "a client's"
        local here = if server then "a client" else "the server"

        refuse (`{said} is {whose} call, and this is {here}`, called (of))
    end

    return held
end

-- Closes the list. A namespace declared after this has nothing left to open it.
function Define.seal () sealed = true end

--[[
    A namespace, as the definitions a caller wrote and the name both machines require it under. The
    table handed over is the one handed back, frozen, so a caller who edited it afterwards cannot
    leave the two machines agreeing at different times. A name already defined refuses.
]]
function Define.define <T>(name: string, defs: T & Types.Definitions): T
    if sealed then
        refuse (`{name} was defined after start, and start opens what there is`, name)
    end
    if spaces[name] ~= nil then refuse (`{name} has already been defined`, name) end

    local why = Legality.named (name)
    if why ~= nil then refuse (`{name} {why}`, name) end
    if name == "" then refuse ("a namespace with no name cannot be required by anybody", name) end

    local names = Order.names (defs)
    for _, under in names do
        --[[
            Read through a check that the value is a table at all. A caller who wrote a number
            against a name has made the typo this refusal is for, and reaching into it first turns
            that into an index of a number, which says nothing about what they got wrong.
        ]]
        local one = defs[under] :: any
        local live = if typeof (one) == "table" then one.live :: Live? else nil
        if live == nil then refuse (`{name}.{under} is not a packet, a query or a set`, name) end

        local held = live :: Live
        if held.space ~= nil then
            refuse (`{name}.{under} is already named in {held.space}`, name)
        end

        held.space = name
        held.name = under
    end

    spaces[name] = table.freeze ({ name = name, defs = defs, names = table.freeze (names) })
    table.insert (order, name)

    --[[
        Frozen where it is not already. A caller who froze their own table handed over one that is
        as unwritable as this asks for, and freezing a frozen table raises rather than agreeing.
    ]]
    return if table.isfrozen (defs) then defs else table.freeze (defs)
end

return table.freeze (Define)
