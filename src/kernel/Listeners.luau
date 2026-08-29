--!strict
--!optimize 2
-- The connection a registration hands back, and the fan that reaches every one still live.

local Listeners = {}

-- Types ---------------------------------------------------------------

--[[
    `connected` and `disconnect` are exactly what `Types.Connection` names, so a link is handed back
    as the connection itself and the two cannot drift apart.
]]
export type Link<A...> = {
    connected: boolean,
    disconnect: (self: any) -> (),
    fn: (A...) -> (),
}

-- How a listener is reached, which is the one thing about a fan that is not this module's.
export type Run<A...> = (fn: (A...) -> (), A...) -> ()

-- The same, over a run of payloads rather than one, which only a list of blocks is given.
export type Walk = (fn: (...any) -> (), count: number, values: { any }, ...any) -> ()

-- The same again, over three arrays that move together, which only a list of records is given.
export type Beside = (
    fn: (...any) -> (),
    count: number,
    ones: { any },
    twos: { any },
    threes: { any }
) -> ()

export type List<A...> = {
    links: { Link<A...> },
    live: number,
    fanning: number,
    run: Run<A...>,
    walk: Walk?,
    beside: Beside?,
}

-- Private -------------------------------------------------------------

-- The links that are no longer connected, taken out in place, once nothing is walking them.
local function swept (of: List<...any>)
    local links = of.links
    local held = #links
    if of.fanning > 0 or held == of.live then return end

    local at = 1
    for index = 1, held do
        local link = links[index]
        if link.connected then
            links[at] = link
            at += 1
        end
    end
    for index = held, at, -1 do
        links[index] = nil
    end
end

-- Public --------------------------------------------------------------

--[[
    Every listener handed a block's payloads, one thread apiece rather than one a payload. Only a
    list built with a walker takes this, since what it hands over is a run of values where an
    ordinary fan hands over one, and a list of one value a call has no run to give it.
]]
function Listeners.fanned <A...>(of: List<A...>, count: number, values: { any }, ...: any)
    local walk = of.walk
    if walk == nil then return end

    local links = of.links
    local held = #links
    if held == 0 then return end

    of.fanning += 1
    for index = 1, held do
        local link = links[index]
        if link.connected then walk (link.fn :: any, count, values, ...) end
    end
    of.fanning -= 1

    swept (of)
end

function Listeners.list <A...>(run: Run<A...>, walk: Walk?, beside: Beside?): List<A...>
    return { links = {}, live = 0, fanning = 0, run = run, walk = walk, beside = beside }
end

-- At the end of the order, which is the order a fan walks.
function Listeners.connect <A...>(of: List<A...>, fn: (A...) -> ()): Link<A...>
    local link: Link<A...> = {
        connected = true,
        fn = fn,
        disconnect = function (self: any)
            if not self.connected then return end
            self.connected = false

            of.live -= 1
            swept (of)
        end,
    }

    table.insert (of.links, link)
    of.live += 1
    return link
end

--[[
    Whether anything is still listening, which is what decides whether the answer is worth working
    out. Counted rather than measured, since a link disconnected mid-fan is still in the list and
    is exactly the one a walk of it would count and a fan of it would skip.
]]
function Listeners.any <A...>(of: List<A...>): boolean return of.live > 0 end

--[[
    Every listener handed a settle's records, one thread apiece rather than one a record. Three
    arrays that move together, since what a set says of a record is an id, the record and what it
    was, and a list without a walker for them takes nothing.
]]
function Listeners.beside <A...>(
    of: List<A...>,
    count: number,
    ones: { any },
    twos: { any },
    threes: { any }
)
    local beside = of.beside
    if beside == nil then return end

    local links = of.links
    local held = #links
    if held == 0 then return end

    of.fanning += 1
    for index = 1, held do
        local link = links[index]
        if link.connected then beside (link.fn :: any, count, ones, twos, threes) end
    end
    of.fanning -= 1

    swept (of)
end

--[[
    Everything still listening, in the order it was registered, each on a thread of its own.

    The count is read once before the walk, so a listener attached by a listener is reached by the
    next fan and not this one. A walk over a list still growing would have no end it could name.
]]
function Listeners.fan <A...>(of: List<A...>, ...: A...)
    local links, run = of.links, of.run
    local held = #links

    of.fanning += 1
    for index = 1, held do
        local link = links[index]
        if link.connected then run (link.fn, ...) end
    end
    of.fanning -= 1

    swept (of)
end

return table.freeze (Listeners)
