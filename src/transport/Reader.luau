--!strict
--!optimize 2
-- Reader.luau — Deserializes incoming buffers and routes by registration kind.

local Baseline = require (script.Parent.Parent.core.Baseline)
local Gate = require (script.Parent.Gate)
local Middleware = require (script.Parent.Parent.core.Middleware)
local Registry = require (script.Parent.Parent.core.Registry)

local registryGet = Registry.get

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

    if Baseline.hasDelta then
        Baseline.setReadKey (player or false)
    end

    -- Cache middleware flag once per frame-buffer, not per packet
    local hasReceiveMiddleware = Middleware.hasReceive
    local isServer = player ~= nil

    while pos < length do
        local id = buffer.readu8 (incoming, pos)
        pos += 1

        local reg = registryGet (id)
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

            -- Hot path: no gate, no middleware — straight decode → fire
            if not (isServer and reg.needsGate) and not hasReceiveMiddleware then
                for _ = 1, count do
                    if pos >= length then
                        break
                    end

                    local value, consumed = codec.read (incoming, pos, refs)
                    pos += consumed
                    signal:fire (value, player)
                end
            else
                -- Cold path: gate and/or middleware active
                local baseName = reg.baseName
                local needsGate = isServer and reg.needsGate

                for _ = 1, count do
                    if pos >= length then
                        break
                    end

                    local value, consumed = codec.read (incoming, pos, refs)
                    pos += consumed

                    if needsGate and not Gate.check (value, reg, player :: Player) then
                        return
                    end

                    if hasReceiveMiddleware then
                        local final = Middleware.runReceive (value, baseName, player)
                        if final == nil then
                            continue
                        end
                        signal:fire (final, player)
                    else
                        signal:fire (value, player)
                    end
                end
            end
        else
            -- Query frame: id(u8, already read) + correlationId(u16) + status(u8) = 3 more bytes
            if pos + 2 >= length then
                break
            end

            local queryCodec = reg.codec
            local querySignal = reg.signal

            local correlationId = buffer.readu16 (incoming, pos)
            local status = buffer.readu8 (incoming, pos + 2)
            pos += 3

            if status == 1 then
                if kind == KIND_REQUEST then
                    querySignal:fire (nil, player, correlationId)
                else
                    querySignal:fire (nil, correlationId)
                end
                continue
            end

            local value, consumed = queryCodec.read (incoming, pos, refs)
            pos += consumed

            if isServer and reg.needsGate and not Gate.check (value, reg, player :: Player) then
                return
            end

            local final: any
            if hasReceiveMiddleware then
                final = Middleware.runReceive (value, reg.baseName, player)
                if final == nil then
                    continue
                end
            else
                final = value
            end

            if kind == KIND_REQUEST then
                querySignal:fire (final, player, correlationId)
            else
                querySignal:fire (final, correlationId)
            end
        end
    end
end

return table.freeze (Reader)
