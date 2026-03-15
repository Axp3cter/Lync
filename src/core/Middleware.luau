--!strict
--!optimize 2
-- Middleware.luau — Ordered intercept chains for send and receive.

-- State ------------------------------------------------------------------

type Handler = (data: any, name: string, player: Player?) -> any?

local _send    = {} :: { Handler }
local _receive = {} :: { Handler }
local _nSend   = 0
local _nRecv   = 0

-- Private ----------------------------------------------------------------

local function run(chain: { Handler }, count: number, data: any, name: string, player: Player?): any?
    if count == 0 then return data end

    local current = data
    for i = 1, count do
        local ok, result = pcall(chain[i], current, name, player)
        if not ok then
            warn(`[Lync] Middleware error: {result}`)
            return nil
        end
        if result == nil then return nil end
        current = result
    end

    return current
end

-- Public -----------------------------------------------------------------

local Middleware = {}

function Middleware.addSend(fn: Handler): () -> ()
    _nSend += 1
    _send[_nSend] = fn

    return function(): ()
        local pos = table.find(_send, fn)
        if not pos then return end
        table.remove(_send, pos)
        _nSend -= 1
    end
end

function Middleware.addReceive(fn: Handler): () -> ()
    _nRecv += 1
    _receive[_nRecv] = fn

    return function(): ()
        local pos = table.find(_receive, fn)
        if not pos then return end
        table.remove(_receive, pos)
        _nRecv -= 1
    end
end

function Middleware.runSend(data: any, name: string, player: Player?): any?
    return run(_send, _nSend, data, name, player)
end

function Middleware.runReceive(data: any, name: string, player: Player?): any?
    return run(_receive, _nRecv, data, name, player)
end

return table.freeze(Middleware)
