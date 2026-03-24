--!strict
--!optimize 2
-- Ordered intercept chains returning Connection objects.

local Types  = require(script.Parent.Parent.Types)
local Signal = require(script.Parent.Parent.api.Signal)

-- State ---------------------------------------------------------------

local _sendSignal = Signal.create()
local _receiveSignal = Signal.create()
local _dropSignal = Signal.create()

-- Public --------------------------------------------------------------

local Middleware = {}

function Middleware.onSend(fn: (data: any, name: string, player: Player?) -> any): Types.Connection
    return _sendSignal:connect(fn)
end

function Middleware.onReceive(fn: (data: any, name: string, player: Player?) -> any): Types.Connection
    return _receiveSignal:connect(fn)
end

function Middleware.onDrop(fn: (player: Player, reason: string, name: string, data: any?) -> ()): Types.Connection
    return _dropSignal:connect(fn)
end

--[[
    Runs send middleware chain. Returns transformed data, or DROP sentinel.
    If no hooks, returns data unchanged (zero overhead).
]]
function Middleware.runSend(data: any, name: string, player: Player?): any
    local count = _sendSignal._count[1]
    if count == 0 then return data end

    local entries = _sendSignal._entries
    local result = data

    for i = 1, count do
        local entry = entries[i]
        if entry._state ~= 0 then -- not disconnected
            local returned = entry.fn(result, name, player)
            if returned ~= nil then
                result = returned
            end
        end
    end

    return result
end

function Middleware.runReceive(data: any, name: string, player: Player?): any
    local count = _receiveSignal._count[1]
    if count == 0 then return data end

    local entries = _receiveSignal._entries
    local result = data

    for i = 1, count do
        local entry = entries[i]
        if entry._state ~= 0 then
            local returned = entry.fn(result, name, player)
            if returned ~= nil then
                result = returned
            end
        end
    end

    return result
end

function Middleware.fireDrop(player: Player, reason: string, name: string, data: any?): ()
    _dropSignal:fireSync(player, reason, name, data)
end

function Middleware.hasSendHooks(): boolean
    return _sendSignal._count[1] > 0
end

function Middleware.hasReceiveHooks(): boolean
    return _receiveSignal._count[1] > 0
end

return table.freeze(Middleware)
