--!strict
--!optimize 2
-- Ordered intercept chains for send and receive.

type Handler = (data: any, name: string, player: Player?) -> any?

type Chain = {
    handlers: { Handler },
    snapshot: { Handler }?,
}

-- Constants ----------------------------------------------------------

local DROP = table.freeze ({ _tag = "drop" })

-- State --------------------------------------------------------------

local _send: Chain = { handlers = {}, snapshot = nil }
local _receive: Chain = { handlers = {}, snapshot = nil }

-- Private ------------------------------------------------------------

local function runChain (chain: { Handler }, data: any, name: string, player: Player?): any?
    local current = data
    for i = 1, #chain do
        local result = chain[i] (current, name, player)
        if result == nil or result == DROP then
            return nil
        end
        current = result
    end
    return current
end

local function run (chain: Chain, data: any, name: string, player: Player?): any?
    local handlers = chain.handlers
    local count = #handlers
    if count == 0 then
        return data
    end

    local snapshot = chain.snapshot
    if not snapshot then
        snapshot = table.clone (handlers)
        chain.snapshot = snapshot
    end

    local ok: boolean
    local result: any

    if count == 1 then
        ok, result = pcall (snapshot[1], data, name, player)
    else
        ok, result = pcall (runChain, snapshot, data, name, player)
    end

    if not ok then
        warn (`[Lync] Middleware error on "{name}": {result}`)
        return nil
    end

    if result == DROP then
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

-- Public -------------------------------------------------------------

local Middleware = {}

Middleware.hasSend = false
Middleware.hasReceive = false
Middleware.DROP = DROP

function Middleware.addSend (fn: Handler): () -> ()
    local remover = addTo (_send, fn)
    Middleware.hasSend = true

    return function (): ()
        remover ()
        Middleware.hasSend = #_send.handlers > 0
    end
end

function Middleware.addReceive (fn: Handler): () -> ()
    local remover = addTo (_receive, fn)
    Middleware.hasReceive = true

    return function (): ()
        remover ()
        Middleware.hasReceive = #_receive.handlers > 0
    end
end

function Middleware.runSend (data: any, name: string, player: Player?): any?
    return run (_send, data, name, player)
end

function Middleware.runReceive (data: any, name: string, player: Player?): any?
    return run (_receive, data, name, player)
end

-- Not frozen: hasSend and hasReceive are mutated at runtime.
return Middleware
