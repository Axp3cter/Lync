--!strict
--!optimize 2
-- Ordered intercept chains for send and receive.

-- State ------------------------------------------------------------------

type Handler = (data: any, name: string, player: Player?) -> any?

type Chain = {
    handlers: { Handler },
    snapshot: { Handler }?,
}

local _send: Chain = { handlers = {}, snapshot = nil }
local _receive: Chain = { handlers = {}, snapshot = nil }

-- Private ----------------------------------------------------------------

local function runChain (chain: { Handler }, data: any, name: string, player: Player?): any?
    local current = data
    for i = 1, #chain do
        local result = chain[i] (current, name, player)
        if result == nil then
            return nil
        end
        current = result
    end
    return current
end

local function run (chain: Chain, label: string, data: any, name: string, player: Player?): any?
    local handlers = chain.handlers
    if #handlers == 0 then
        return data
    end

    local snapshot = chain.snapshot
    if not snapshot then
        snapshot = table.clone (handlers)
        chain.snapshot = snapshot
    end

    local ok, result = pcall (runChain, snapshot, data, name, player)
    if not ok then
        warn (`[Lync] {label} middleware error on "{name}": {result}`)
        return nil
    end

    return result
end

local function addTo (chain: Chain, fn: Handler): () -> ()
    table.insert (chain.handlers, fn)
    chain.snapshot = nil

    return function (): ()
        local pos = table.find (chain.handlers, fn)
        if pos then
            table.remove (chain.handlers, pos)
            chain.snapshot = nil
        end
    end
end

-- Public -----------------------------------------------------------------

local Middleware = {}

function Middleware.addSend (fn: Handler): () -> ()
    return addTo (_send, fn)
end

function Middleware.addReceive (fn: Handler): () -> ()
    return addTo (_receive, fn)
end

function Middleware.runSend (data: any, name: string, player: Player?): any?
    return run (_send, "Send", data, name, player)
end

function Middleware.runReceive (data: any, name: string, player: Player?): any?
    return run (_receive, "Receive", data, name, player)
end

return table.freeze (Middleware)
