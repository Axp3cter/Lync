--!strict
--!optimize 2
-- Deserializes incoming buffers and routes by registration kind.

local Baseline = require (script.Parent.Parent.core.Baseline)
local Gate = require (script.Parent.Gate)
local Middleware = require (script.Parent.Parent.core.Middleware)
local Registry = require (script.Parent.Parent.core.Registry)

-- Constants --------------------------------------------------------------

local KIND_PACKET = Registry.KIND_PACKET
local KIND_REQUEST = Registry.KIND_REQUEST

local MAX_INCOMING = 65536

-- Public -----------------------------------------------------------------

local Reader = {}

-- Shared incoming-data validation used by both Client and Server receive.
function Reader.decodeIncoming (data: any): buffer?
    if typeof (data) ~= "buffer" then
        return nil
    end
    if buffer.len (data) > MAX_INCOMING then
        return nil
    end
    return data
end

--[[
    Callers (Server/Client receive) already wrap this in pcall.
    Any codec.read throw propagates up and aborts the entire buffer
    from this source, which is the correct security behavior.
]]
function Reader.process (
    incoming: buffer,
    refs: { Instance }?,
    player: Player?,
    startOffset: number
): ()
    local length = buffer.len (incoming)
    local pos = startOffset

    Baseline.setReadKey (player or false)

    while pos < length do
        local id = buffer.readu8 (incoming, pos)
        pos += 1

        local reg = Registry.get (id)
        if not reg then
            warn (`[Lync] Unknown packet ID {id}`)
            break
        end

        local kind = reg.kind

        if kind == KIND_PACKET then
            if pos + 2 > length then
                break
            end

            local count = buffer.readu16 (incoming, pos)
            pos += 2

            if count == 0 then
                continue
            end

            local codec = reg.codec
            local signal = reg.signal
            local baseName = reg.baseName

            for _ = 1, count do
                if pos >= length then
                    break
                end

                local value, consumed = codec.read (incoming, pos, refs)
                pos += consumed

                if player and not Gate.check (value, reg, player) then
                    return
                end

                local final = Middleware.runReceive (value, baseName, player)
                if final == nil then
                    continue
                end

                signal:fire (final, player)
            end
        else
            if pos >= length then
                break
            end

            local correlationId = buffer.readu8 (incoming, pos)
            pos += 1

            local value, consumed = reg.codec.read (incoming, pos, refs)
            pos += consumed

            if player and not Gate.check (value, reg, player) then
                return
            end

            local final = Middleware.runReceive (value, reg.baseName, player)
            if final == nil then
                continue
            end

            if kind == KIND_REQUEST then
                reg.signal:fire (final, player, correlationId)
            else
                reg.signal:fire (final, correlationId)
            end
        end
    end
end

return table.freeze (Reader)
