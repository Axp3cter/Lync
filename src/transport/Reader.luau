--!strict
--!optimize 2
-- Deserializes incoming buffers with MSB batch dispatch.

local Types      = require(script.Parent.Parent.Types)
local Registry   = require(script.Parent.Parent.internal.Registry)
local Channel    = require(script.Parent.Parent.internal.Channel)
local Baseline   = require(script.Parent.Parent.internal.Baseline)
local Gate       = require(script.Parent.Parent.transport.Gate)
local Middleware = require(script.Parent.Parent.internal.Middleware)
local Varint     = require(script.Parent.Parent.codec.primitive.Varint)

-- Constants -----------------------------------------------------------

local KIND_PACKET   = Registry.KIND_PACKET
local KIND_REQUEST  = Registry.KIND_REQUEST
local KIND_RESPONSE = Registry.KIND_RESPONSE

-- Private -------------------------------------------------------------

local band   = bit32.band
local readu8 = buffer.readu8

-- Public --------------------------------------------------------------

local Reader = {}

function Reader.decodeIncoming(data: any): buffer?
    if typeof(data) ~= "buffer" then return nil end
    local b = data :: buffer
    local len = buffer.len(b)
    if len == 0 or len > 65536 then return nil end
    return b
end

function Reader.process(
    incoming: buffer,
    incomingLen: number,
    refs: { Instance }?,
    player: Player?,
    isServer: boolean
): ()
    -- Set baseline read key for delta codecs
    if Baseline.hasDelta() then
        Baseline.setReadKey(player or false)
    end

    local statsEnabled    = Channel.statsEnabled()
    local hasRecvHooks   = Middleware.hasReceiveHooks()
    local pos = 0

    while pos < incomingLen do
        local raw = readu8(incoming, pos)
        pos += 1

        local msb = band(raw, 0x80) ~= 0
        local id = band(raw, 0x7F)

        local reg = Registry.get(id)
        if not reg then
            warn(`[Lync] Reader: unknown packet ID {id} at byte {pos - 1}`)
            break
        end

        if reg.kind == KIND_PACKET then
            local count: number

            if msb then
                count = 1
            else
                count = buffer.readu16(incoming, pos)
                pos += 2
            end

            -- Read timestamp if this packet has one configured
            local tsMode = reg.timestampMode
            local tsValue: any = nil

            if tsMode == Channel.TS_FRAME then
                tsValue = readu8(incoming, pos)
                pos += 1
            elseif tsMode == Channel.TS_OFFSET then
                tsValue = buffer.readu16(incoming, pos)
                pos += 2
            elseif tsMode == Channel.TS_FULL then
                tsValue = buffer.readf64(incoming, pos)
                pos += 8
            end

            -- Prevent a malicious count from reading past the buffer
            if reg.codec._size then
                local maxItems = (incomingLen - pos) // (reg.codec._size :: number)
                if count > maxItems then count = maxItems end
            end

            for _ = 1, count do
                local value, consumed = reg.codec.read(incoming, pos, refs)
                pos += consumed

                if isServer and reg.needsGate then
                    if player and not Gate.checkGlobalRateLimit(player) then
                        if statsEnabled then reg.drops += 1 end
                        Middleware.fireDrop(player :: Player, "rate", reg.name, value)
                        continue
                    end

                    if player and not Gate.checkRateLimit(reg, player) then
                        if statsEnabled then reg.drops += 1 end
                        Middleware.fireDrop(player :: Player, "rate", reg.name, value)
                        continue
                    end

                    local ok, reason = Gate.validate(value, reg.codec)
                    if not ok then
                        if statsEnabled then reg.drops += 1 end
                        if player then
                            Middleware.fireDrop(player, "validation", reg.name, value)
                        end
                        continue
                    end

                    if reg.validate then
                        local valid, validReason = reg.validate(value, player :: Player)
                        if not valid then
                            if statsEnabled then reg.drops += 1 end
                            Middleware.fireDrop(player :: Player, validReason or "validate", reg.name, value)
                            continue
                        end
                    end
                end

                if hasRecvHooks then
                    value = Middleware.runReceive(value, reg.name, player)
                end

                if statsEnabled then reg.recvFires += 1 end

                if tsValue ~= nil then
                    reg.signal:fire(value, player, tsValue)
                else
                    reg.signal:fire(value, player)
                end
            end

            if statsEnabled then
                -- Approximate: counts all bytes consumed in this frame, not just payload
                reg.bytesReceived += pos
            end

        elseif reg.kind == KIND_REQUEST or reg.kind == KIND_RESPONSE then
            -- MSB distinguishes nil responses (no payload) from data responses
            local corrId, corrBytes = Varint.read(incoming, pos)
            pos += corrBytes

            if msb then
                if statsEnabled then reg.recvFires += 1 end
                reg.signal:fire(nil, player, corrId)
            else
                local value, consumed = reg.codec.read(incoming, pos, refs)
                pos += consumed

                if isServer and reg.needsGate and reg.kind == KIND_REQUEST then
                    if player and not Gate.checkRateLimit(reg, player) then
                        if statsEnabled then reg.drops += 1 end
                        Middleware.fireDrop(player :: Player, "rate", reg.name, value)
                        continue
                    end

                    local ok, reason = Gate.validate(value, reg.codec)
                    if not ok then
                        if statsEnabled then reg.drops += 1 end
                        if player then
                            Middleware.fireDrop(player, "validation", reg.name, value)
                        end
                        continue
                    end

                    if reg.validate then
                        local valid, validReason = reg.validate(value, player :: Player)
                        if not valid then
                            if statsEnabled then reg.drops += 1 end
                            Middleware.fireDrop(player :: Player, validReason or "validate", reg.name, value)
                            continue
                        end
                    end
                end

                if hasRecvHooks then
                    value = Middleware.runReceive(value, reg.name, player)
                end

                if statsEnabled then reg.recvFires += 1 end
                reg.signal:fire(value, player, corrId)
            end
        end
    end
end

return table.freeze(Reader)
