--!strict
--!native
-- Inbound buffer parser. Returns false on malformed wire so the transport can drop its XOR baseline.

local Baseline = require(script.Parent.Parent.internal.Baseline)
local Channel = require(script.Parent.Parent.internal.Channel)
local Constants = require(script.Parent.Parent.util.Constants)
local Gate = require(script.Parent.Parent.transport.Gate)
local Log = require(script.Parent.Parent.util.Log)
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

local FRAME_MSB = Constants.FRAME_MSB
local FRAME_ID_MASK = Constants.FRAME_ID_MASK

-- Private ----------------------------------------------------------------

local band = bit32.band
local readu8 = buffer.readu8
local readu16 = buffer.readu16
local readf64 = buffer.readf64
local registryGet = Registry.get
local checkGlobal = Gate.checkGlobalRateLimit
local checkRate = Gate.checkRateLimit
local validateGate = Gate.validate
local fireDrop = Middleware.fireDrop
local runReceive = Middleware.runReceive
local varintRead = Varint.read

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
        fireDrop(player, reason, reg.name, value)
    end
end

--[[
    Server gate pipeline. Returns true to deliver, false on rate-limit,
    schema-validate, or custom-validate rejection. `runGlobal` lets the
    response path skip the global per-player limit.
]]
local function gateValue(
    reg: Types.Registration,
    regCodec: Types.InternalCodec<any>,
    value: any,
    player: Player,
    statsEnabled: boolean,
    runGlobal: boolean
): boolean
    -- Both global and per-packet drops use the "rate" reason; collapsed into one branch.
    if (runGlobal and not checkGlobal(player)) or not checkRate(reg, player) then
        recordDrop(reg, statsEnabled, player, "rate", value)
        return false
    end

    local validateReason = validateGate(value, regCodec)
    if validateReason then
        recordDrop(reg, statsEnabled, player, `validation: {validateReason}`, value)
        return false
    end

    if reg.validate then
        local valid, validReason = reg.validate(value, player)
        if not valid then
            recordDrop(
                reg,
                statsEnabled,
                player,
                if validReason then `validate: {validReason}` else "validate",
                value
            )
            return false
        end
    end
    return true
end

-- Public -----------------------------------------------------------------

local Reader = {}

--[[
    Sanity-check an inbound payload. Size cap is delegated to Roblox's ~1MB
    RemoteEvent ceiling: the receiver may not have called Lync.configure
    with the same channelMaxSize as the sender (independent VMs, independent
    module state), so a local cap here would reject legitimate frames.
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

--[[
    Returns true on full success, false if a malformed frame aborted the
    parse. Transport callers use this to decide whether to keep the per-peer
    XOR baseline: false means the buffer is suspect and would permanently
    desync the channel if reused as the next XOR mask.
]]
function Reader.process(
    incoming: buffer,
    incomingLen: number,
    refs: { Instance }?,
    player: Player?,
    isServer: boolean
): boolean
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

        local msb = band(raw, FRAME_MSB) ~= 0
        local id = band(raw, FRAME_ID_MASK)

        local reg = registryGet(id)
        if not reg then
            Log.warn(`unknown packet ID {id} at byte {pos - 1}`)
            return false
        end

        local kind = reg.kind
        if kind == KIND_PACKET then
            local count: number
            if msb then
                count = 1
            else
                if pos + 2 > incomingLen then
                    Log.warn("truncated multi-frame header")
                    return false
                end
                count = readu16(incoming, pos)
                pos += 2
            end

            local tsMode = reg.timestampMode
            local tsValue: number? = nil
            if tsMode == TS_FRAME then
                if pos + 1 > incomingLen then
                    Log.warn("truncated timestamp")
                    return false
                end
                tsValue = readu8(incoming, pos)
                pos += 1
            elseif tsMode == TS_OFFSET then
                if pos + 2 > incomingLen then
                    Log.warn("truncated timestamp")
                    return false
                end
                tsValue = readu16(incoming, pos)
                pos += 2
            elseif tsMode == TS_FULL then
                if pos + 8 > incomingLen then
                    Log.warn("truncated timestamp")
                    return false
                end
                tsValue = readf64(incoming, pos)
                pos += 8
            end

            --[[
                Fixed-size codec: a count exceeding remaining bytes is
                unambiguously corrupt. Abort to keep the cursor on a frame
                boundary so the transport can reset cleanly.
            ]]
            local regCodec = reg.codec
            local sizeMeta = regCodec._size
            if sizeMeta and count * sizeMeta > incomingLen - pos then
                Log.warn(`"{reg.name}" count {count} exceeds remaining bytes; aborting`)
                return false
            end

            local maxPayload = reg.maxPayloadBytes
            local payloadStart = pos
            local doGate = isServer and reg.needsGate and player ~= nil
            local regSignal = reg.signal
            local regName = reg.name
            -- Lync.nothing reads zero bytes; bypass the pos/consumed gates that assume forward progress.
            local isZeroSize = sizeMeta == 0
            local accepted = 0

            for _ = 1, count do
                if not isZeroSize and pos >= incomingLen then
                    Log.warn(`codec for "{regName}" ran past frame end; aborting`)
                    return false
                end
                local value, consumed = regCodec.read(incoming, pos, refs)
                if not isZeroSize and consumed == 0 then
                    Log.warn(`codec for "{regName}" reported 0 bytes; aborting`)
                    return false
                end
                -- Fixed-size codecs MUST report consumed == _size or `pos` desyncs silently.
                if sizeMeta and consumed ~= sizeMeta then
                    Log.warn(
                        `codec for "{regName}" consumed {consumed} bytes, expected {sizeMeta}; aborting`
                    )
                    return false
                end
                pos += consumed
                if pos > incomingLen then
                    Log.warn(`codec for "{regName}" overran frame end; aborting`)
                    return false
                end

                if maxPayload and (pos - payloadStart) > maxPayload then
                    recordDrop(reg, statsEnabled, player, "maxPayloadBytes", value)
                    return false
                end

                if
                    doGate
                    and not gateValue(reg, regCodec, value, player :: Player, statsEnabled, true)
                then
                    continue
                end

                if hasRecvHooks then
                    value = runReceive(value, regName, player)
                end

                accepted += 1

                -- tsValue is nil when mode == TS_NONE; pass through to skip a per-item branch.
                regSignal:fire(value, player, tsValue)
            end

            if statsEnabled then
                reg.recvFires += accepted
                reg.bytesReceived += (pos - frameStart)
            end
        elseif kind == KIND_REQUEST or kind == KIND_RESPONSE then
            local corrId, corrBytes = varintRead(incoming, pos)
            if corrBytes == 0 then
                Log.warn(`truncated correlation id for "{reg.name}"; aborting`)
                return false
            end
            pos += corrBytes

            if msb then
                if statsEnabled then
                    reg.recvFires += 1
                    reg.bytesReceived += (pos - frameStart)
                end
                reg.signal:fire(nil, player, corrId)
            else
                local regCodec = reg.codec
                -- Mirror the packet path: 0-byte response codecs (Lync.nothing) bypass the gates.
                local qIsZeroSize = regCodec._size == 0
                if not qIsZeroSize and pos >= incomingLen then
                    Log.warn(`query "{reg.name}" body missing; aborting`)
                    return false
                end
                local value, consumed = regCodec.read(incoming, pos, refs)
                if not qIsZeroSize and consumed == 0 then
                    Log.warn(`query codec for "{reg.name}" reported 0 bytes; aborting`)
                    return false
                end
                pos += consumed
                if pos > incomingLen then
                    Log.warn(`query "{reg.name}" overran frame end; aborting`)
                    return false
                end

                --[[
                    Server gates REQUEST and RESPONSE frames opted into
                    needsGate so a malicious client can't bypass via the
                    response channel.
                ]]
                if
                    isServer
                    and reg.needsGate
                    and player
                    and not gateValue(reg, regCodec, value, player, statsEnabled, false)
                then
                    if statsEnabled then
                        reg.bytesReceived += (pos - frameStart)
                    end
                    continue
                end

                if hasRecvHooks then
                    value = runReceive(value, reg.name, player)
                end

                if statsEnabled then
                    reg.recvFires += 1
                    reg.bytesReceived += (pos - frameStart)
                end
                reg.signal:fire(value, player, corrId)
            end
        end
    end
    return true
end

Reader.setSilent = Log.setSilent
Reader.reset = Log.reset

return table.freeze(Reader)
