--!strict
--!optimize 2
-- Deserializes incoming buffers with MSB batch dispatch.

local Baseline = require(script.Parent.Parent.internal.Baseline)
local Channel = require(script.Parent.Parent.internal.Channel)
local Gate = require(script.Parent.Parent.transport.Gate)
local Middleware = require(script.Parent.Parent.internal.Middleware)
local Registry = require(script.Parent.Parent.internal.Registry)
local Types = require(script.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.codec.primitive.Varint)

-- Constants --------------------------------------------------------------

local KIND_PACKET = Registry.KIND_PACKET
local KIND_REQUEST = Registry.KIND_REQUEST
local KIND_RESPONSE = Registry.KIND_RESPONSE

local TS_FRAME = Channel.TS_FRAME
local TS_OFFSET = Channel.TS_OFFSET
local TS_FULL = Channel.TS_FULL

local MAX_ITEMS_PER_FRAME = 0xFFFF

-- Private ----------------------------------------------------------------

local band = bit32.band
local readu8 = buffer.readu8

local function recordDrop(
    reg: Types.Registration,
    statsEnabled: boolean,
    player: Player?,
    reason: string,
    value: any
): ()
    if statsEnabled then
        reg.drops += 1
    end
    if player then
        Middleware.fireDrop(player, reason, reg.name, value)
    end
end

-- Public -----------------------------------------------------------------

local Reader = {}

--[[
    Sanity-check an inbound RemoteEvent payload. The size cap MUST NOT be
    tied to the local `Channel.maxSize()` — sender and receiver run in
    separate Lua VMs with independent module state, so the receiver may
    not have called Lync.configure with the same channelMaxSize. Coupling
    them caused server frames larger than the receiver's local default to
    be silently dropped, which permanently desynced the XOR baseline.

    Roblox enforces a per-RemoteEvent payload ceiling around 1MB; if the
    payload reached us at all, it's already within Roblox's limit. Trust
    that and accept anything non-empty.
]]
function Reader.decodeIncoming(data: any): buffer?
    if typeof(data) ~= "buffer" then
        return nil
    end
    local b = data :: buffer
    if buffer.len(b) == 0 then
        return nil
    end
    return b
end

function Reader.process(
    incoming: buffer,
    incomingLen: number,
    refs: { Instance }?,
    player: Player?,
    isServer: boolean
): ()
    if Baseline.hasDelta() then
        Baseline.setReadKey(player or false)
    end

    local statsEnabled = Channel.statsEnabled()
    local hasRecvHooks = Middleware.hasReceiveHooks()
    local pos = 0

    while pos < incomingLen do
        local frameStart = pos
        local raw = readu8(incoming, pos)
        pos += 1

        local msb = band(raw, 0x80) ~= 0
        local id = band(raw, 0x7F)

        local reg = Registry.get(id)
        if not reg then
            warn(`[Lync] Reader.process: unknown packet ID {id} at byte {pos - 1}`)
            return
        end

        if reg.kind == KIND_PACKET then
            local count: number
            if msb then
                count = 1
            else
                if pos + 2 > incomingLen then
                    warn("[Lync] Reader.process: truncated multi-frame header")
                    return
                end
                count = buffer.readu16(incoming, pos)
                pos += 2
            end

            local tsMode = reg.timestampMode
            local tsValue: number? = nil
            if tsMode == TS_FRAME then
                tsValue = readu8(incoming, pos)
                pos += 1
            elseif tsMode == TS_OFFSET then
                tsValue = buffer.readu16(incoming, pos)
                pos += 2
            elseif tsMode == TS_FULL then
                tsValue = buffer.readf64(incoming, pos)
                pos += 8
            end

            if count > MAX_ITEMS_PER_FRAME then
                count = MAX_ITEMS_PER_FRAME
            end
            local sizeMeta = reg.codec._size
            if sizeMeta then
                local maxBySize = (incomingLen - pos) // sizeMeta
                if count > maxBySize then
                    count = maxBySize
                end
            end

            local maxPayload = reg.maxPayloadBytes
            local payloadStart = pos

            for _ = 1, count do
                local value, consumed = reg.codec.read(incoming, pos, refs)
                if consumed == 0 then
                    warn(
                        `[Lync] Reader.process: codec for "{reg.name}" reported 0 bytes; aborting frame`
                    )
                    return
                end
                pos += consumed

                if maxPayload and (pos - payloadStart) > maxPayload then
                    recordDrop(reg, statsEnabled, player, "maxPayloadBytes", value)
                    return
                end

                if isServer and reg.needsGate then
                    if player and not Gate.checkGlobalRateLimit(player) then
                        recordDrop(reg, statsEnabled, player, "rate", value)
                        continue
                    end
                    if player and not Gate.checkRateLimit(reg, player) then
                        recordDrop(reg, statsEnabled, player, "rate", value)
                        continue
                    end

                    local ok = Gate.validate(value, reg.codec)
                    if not ok then
                        recordDrop(reg, statsEnabled, player, "validation", value)
                        continue
                    end

                    if reg.validate and player then
                        local valid, validReason = reg.validate(value, player)
                        if not valid then
                            recordDrop(reg, statsEnabled, player, validReason or "validate", value)
                            continue
                        end
                    end
                end

                if hasRecvHooks then
                    value = Middleware.runReceive(value, reg.name, player)
                end

                if statsEnabled then
                    reg.recvFires += 1
                end

                if tsValue ~= nil then
                    reg.signal:fire(value, player, tsValue)
                else
                    reg.signal:fire(value, player)
                end
            end

            if statsEnabled then
                reg.bytesReceived += (pos - frameStart)
            end
        elseif reg.kind == KIND_REQUEST or reg.kind == KIND_RESPONSE then
            local corrId, corrBytes = Varint.read(incoming, pos)
            pos += corrBytes

            if msb then
                if statsEnabled then
                    reg.recvFires += 1
                    reg.bytesReceived += (pos - frameStart)
                end
                reg.signal:fire(nil, player, corrId)
            else
                local value, consumed = reg.codec.read(incoming, pos, refs)
                if consumed == 0 then
                    warn(
                        `[Lync] Reader.process: query codec for "{reg.name}" reported 0 bytes; aborting frame`
                    )
                    return
                end
                pos += consumed

                if isServer and reg.needsGate and reg.kind == KIND_REQUEST then
                    if player and not Gate.checkRateLimit(reg, player) then
                        recordDrop(reg, statsEnabled, player, "rate", value)
                        if statsEnabled then
                            reg.bytesReceived += (pos - frameStart)
                        end
                        continue
                    end

                    local ok = Gate.validate(value, reg.codec)
                    if not ok then
                        recordDrop(reg, statsEnabled, player, "validation", value)
                        if statsEnabled then
                            reg.bytesReceived += (pos - frameStart)
                        end
                        continue
                    end

                    if reg.validate and player then
                        local valid, validReason = reg.validate(value, player)
                        if not valid then
                            recordDrop(reg, statsEnabled, player, validReason or "validate", value)
                            if statsEnabled then
                                reg.bytesReceived += (pos - frameStart)
                            end
                            continue
                        end
                    end
                end

                if hasRecvHooks then
                    value = Middleware.runReceive(value, reg.name, player)
                end

                if statsEnabled then
                    reg.recvFires += 1
                    reg.bytesReceived += (pos - frameStart)
                end
                reg.signal:fire(value, player, corrId)
            end
        end
    end
end

return table.freeze(Reader)
