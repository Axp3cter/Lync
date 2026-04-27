--!strict
--!optimize 2
-- Ordered intercept chains for send/receive/drop hooks.

local Signal = require(script.Parent.Parent.api.Signal)
local Types = require(script.Parent.Parent.Types)

-- State ------------------------------------------------------------------

local _sendSignal = Signal.create()
local _receiveSignal = Signal.create()
local _dropSignal = Signal.create()

-- Private ----------------------------------------------------------------

--[[
    Walk a transform chain in order. Each callback returns a transformed
    value or nil to keep the previous value. A fresh snapshot guards
    against disconnect-during-fire reentry.
]]
local function runChain(signal: any, value: any, name: string, player: Player?): any
    local count = signal._count[1]
    if count == 0 then
        return value
    end

    local entries = signal._entries
    local snapshot = table.create(count)
    table.move(entries, 1, count, 1, snapshot)

    local result = value
    for i = 1, count do
        local entry = snapshot[i]
        if entry._state ~= 0 then
            local returned = entry.fn(result, name, player)
            if returned ~= nil then
                result = returned
            end
        end
    end
    return result
end

-- Public -----------------------------------------------------------------

local Middleware = {}

function Middleware.onSend(fn: (data: any, name: string, player: Player?) -> any): Types.Connection
    return _sendSignal:connect(fn)
end

function Middleware.onReceive(
    fn: (data: any, name: string, player: Player?) -> any
): Types.Connection
    return _receiveSignal:connect(fn)
end

function Middleware.onDrop(
    fn: (player: Player, reason: string, name: string, data: any?) -> ()
): Types.Connection
    return _dropSignal:connect(fn)
end

function Middleware.runSend(data: any, name: string, player: Player?): any
    return runChain(_sendSignal, data, name, player)
end

function Middleware.runReceive(data: any, name: string, player: Player?): any
    return runChain(_receiveSignal, data, name, player)
end

function Middleware.fireDrop(player: Player, reason: string, name: string, data: any?): ()
    _dropSignal:fireSync(player, reason, name, data)
end

function Middleware.hasSendHooks(): boolean
    return _sendSignal:hasListeners()
end

function Middleware.hasReceiveHooks(): boolean
    return _receiveSignal:hasListeners()
end

return table.freeze(Middleware)
