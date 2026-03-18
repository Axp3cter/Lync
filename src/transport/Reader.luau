--!strict
--!optimize 2
-- Deserializes incoming buffers and routes by registration kind.

local Baseline = require(script.Parent.Parent.internal.Baseline)
local Channel = require(script.Parent.Parent.internal.Channel)
local Gate = require(script.Parent.Gate)
local Middleware = require(script.Parent.Parent.internal.Middleware)
local Registry = require(script.Parent.Parent.internal.Registry)
local Varint = require(script.Parent.Parent.codec.primitive.Varint)

local registryGet = Registry.get
local gateCheck = Gate.check
local gateReportDrop = Gate.reportDrop

-- Constants -----------------------------------------------------------

local KIND_PACKET = Registry.KIND_PACKET
local KIND_REQUEST = Registry.KIND_REQUEST

local TS_NONE = Channel.TS_NONE
local TS_FRAME = Channel.TS_FRAME
local TS_OFFSET = Channel.TS_OFFSET
local TS_FULL = Channel.TS_FULL

local MAX_INCOMING = 65536

local floor = math.floor

-- Public --------------------------------------------------------------

local Reader = {}

-- Shared incoming-data validation used by both Client and Server receive.
function Reader.decodeIncoming(data: any): buffer?
    if typeof(data) ~= "buffer" then
        return nil
    end
    if buffer.len(data) > MAX_INCOMING then
        return nil
    end
    return data
end

-- Callers wrap this in pcall. Any throw aborts the entire buffer from this source.
function Reader.process(
    incoming: buffer,
    refs: { Instance }?,
    player: Player?,
    startOffset: number
): ()
    local length = buffer.len(incoming)
    local pos = startOffset

    if Baseline.hasDelta then
        Baseline.setReadKey(player or false)
    end

    -- Cache flags once per frame-buffer, not per packet
    local hasReceiveMiddleware = Middleware.hasReceive
    local isServer = player ~= nil

    while pos < length do
        local id = buffer.readu8(incoming, pos)
        pos += 1

        local reg = registryGet(id)
        if not reg then
            warn(`[Lync] Unknown packet ID {id}`)
            break
        end

        local kind = reg.kind

        if kind == KIND_PACKET then
            if pos + 1 > length then
                break
            end

            local count = buffer.readu8(incoming, pos)
            pos += 1

            if count == 0 then
                continue
            end

            local codec = reg.codec
            local signal = reg.signal
            local batchStart = pos
            local maxBytes = reg.maxPayloadBytes
            local tsMode = reg.timestampMode

            -- Cap count for fixed-size codecs to prevent wasted iterations
            local fixedSize = (codec :: any)._size
            if fixedSize and fixedSize > 0 then
                local maxItems = floor((length - pos) / fixedSize)
                if count > maxItems then
                    count = maxItems
                end
            end

            -- Hot path: no gate, no middleware, no byte budget
            if not (isServer and reg.needsGate) and not hasReceiveMiddleware and not maxBytes then
                for _ = 1, count do
                    if pos >= length then
                        break
                    end

                    local timestamp: number? = nil
                    if tsMode == TS_FRAME then
                        timestamp = buffer.readu8(incoming, pos)
                        pos += 1
                    elseif tsMode == TS_OFFSET then
                        timestamp = buffer.readu16(incoming, pos)
                        pos += 2
                    elseif tsMode == TS_FULL then
                        timestamp = buffer.readf64(incoming, pos)
                        pos += 8
                    end

                    local value, consumed = codec.read(incoming, pos, refs)
                    pos += consumed
                    reg.bytesReceived += consumed
                    reg.recvFires += 1
                    signal:fire(value, player, timestamp)
                end
            else
                -- Cold path: gate and/or middleware and/or byte budget active
                local baseName = reg.baseName
                local needsGate = isServer and reg.needsGate

                for _ = 1, count do
                    if pos >= length then
                        break
                    end

                    if maxBytes and (pos - batchStart) > maxBytes then
                        gateReportDrop(player, "size", reg.name, nil)
                        break
                    end

                    local timestamp: number? = nil
                    if tsMode == TS_FRAME then
                        timestamp = buffer.readu8(incoming, pos)
                        pos += 1
                    elseif tsMode == TS_OFFSET then
                        timestamp = buffer.readu16(incoming, pos)
                        pos += 2
                    elseif tsMode == TS_FULL then
                        timestamp = buffer.readf64(incoming, pos)
                        pos += 8
                    end

                    local value, consumed = codec.read(incoming, pos, refs)
                    pos += consumed
                    reg.bytesReceived += consumed
                    reg.recvFires += 1

                    if needsGate and not gateCheck(value, reg, player :: Player) then
                        continue
                    end

                    if hasReceiveMiddleware then
                        local final = Middleware.runReceive(value, baseName, player)
                        if final == nil then
                            continue
                        end
                        signal:fire(final, player, timestamp)
                    else
                        signal:fire(value, player, timestamp)
                    end
                end
            end
        else
            -- Query frame: id(u8, already read) + correlationId(varint) + status(u8)
            if pos + 2 > length then
                break
            end

            local queryCodec = reg.codec
            local querySignal = reg.signal

            local correlationId, corrBytes = Varint.read(incoming, pos)
            pos += corrBytes
            local status = buffer.readu8(incoming, pos)
            pos += 1

            if status == 1 then
                if kind == KIND_REQUEST then
                    querySignal:fire(nil, player, correlationId)
                else
                    querySignal:fire(nil, player, correlationId)
                end
                continue
            end

            local value, consumed = queryCodec.read(incoming, pos, refs)
            pos += consumed

            if isServer and reg.needsGate and not gateCheck(value, reg, player :: Player) then
                continue
            end

            local final: any
            if hasReceiveMiddleware then
                final = Middleware.runReceive(value, reg.baseName, player)
                if final == nil then
                    continue
                end
            else
                final = value
            end

            if kind == KIND_REQUEST then
                querySignal:fire(final, player, correlationId)
            else
                querySignal:fire(final, player, correlationId)
            end
        end
    end
end

return table.freeze(Reader)
