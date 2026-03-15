--!strict
--!optimize 2
-- Middleware.luau — Ordered intercept chains for send and receive.

-- State ------------------------------------------------------------------

type Handler = (data: any, name: string, player: Player?) -> any?

local _send    = {} :: { Handler }
local _receive = {} :: { Handler }

-- Private ----------------------------------------------------------------

local function runChain(chain: { Handler }, data: any, name: string, player: Player?): any?
    local current = data
    for i = 1, #chain do
        local result = chain[i](current, name, player)
        if result == nil then return nil end
        current = result
    end
    return current
end

local function run(chain: { Handler }, data: any, name: string, player: Player?): any?
    local count = #chain
    if count == 0 then return data end

    -- Fast path: single handler, skip snapshot
    if count == 1 then
        local ok, result = pcall(chain[1], data, name, player)
        if not ok then
            warn(`[Lync] Middleware error: {result}`)
            return nil
        end
        return result
    end

    -- Multiple handlers: snapshot + single pcall around chain
    local snapshot = table.create(count)
    for i = 1, count do
        snapshot[i] = chain[i]
    end

    local ok, result = pcall(runChain, snapshot, data, name, player)
    if not ok then
        warn(`[Lync] Middleware error: {result}`)
        return nil
    end

    return result
end

local function addTo(chain: { Handler }, fn: Handler): () -> ()
    table.insert(chain, fn)

    return function(): ()
        local pos = table.find(chain, fn)
        if pos then
            table.remove(chain, pos)
        end
    end
end

-- Public -----------------------------------------------------------------

local Middleware = {}

function Middleware.addSend(fn: Handler): () -> ()
    return addTo(_send, fn)
end

function Middleware.addReceive(fn: Handler): () -> ()
    return addTo(_receive, fn)
end

function Middleware.runSend(data: any, name: string, player: Player?): any?
    return run(_send, data, name, player)
end

function Middleware.runReceive(data: any, name: string, player: Player?): any?
    return run(_receive, data, name, player)
end

return table.freeze(Middleware)
