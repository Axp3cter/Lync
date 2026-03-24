--!strict
--!optimize 2
-- Deterministic packet/query ID assignment. Sequential 7-bit IDs.

local Types  = require(script.Parent.Parent.Types)
local Signal = require(script.Parent.Parent.api.Signal)

-- Constants -----------------------------------------------------------

local KIND_PACKET   = 0
local KIND_REQUEST  = 1
local KIND_RESPONSE = 2
local MAX_ID        = 127

-- State ---------------------------------------------------------------

local _nextId = 0
local _byId: { [number]: Types.Registration } = {}
local _byName: { [string]: Types.Registration } = {}

-- Public --------------------------------------------------------------

local Registry = {}

Registry.KIND_PACKET   = KIND_PACKET
Registry.KIND_REQUEST  = KIND_REQUEST
Registry.KIND_RESPONSE = KIND_RESPONSE

function Registry.register(
    name: string,
    kind: number,
    codec: Types.InternalCodec<any>,
    isUnreliable: boolean,
    partner: number?,
    needsGate: boolean,
    headerSize: number,
    timestampMode: number,
    openFn: (ch: Types.ChannelState, id: number) -> (),
    rateLimit: Types.RateLimitConfig?,
    validate: ((data: any, player: Player) -> (boolean, string?))?,
    maxPayloadBytes: number?
): Types.Registration
    _nextId += 1
    local id = _nextId

    if id > MAX_ID then
        error(`[Lync] Registry: ID limit exceeded ({MAX_ID}), too many packets/queries`)
    end

    if _byName[name] and kind ~= KIND_RESPONSE then
        error(`[Lync] Registry: duplicate name "{name}"`)
    end

    local reg: Types.Registration = {
        id = id,
        name = name,
        kind = kind,
        codec = codec,
        isUnreliable = isUnreliable,
        partner = partner,
        signal = Signal.create(),
        rateLimit = rateLimit,
        validate = validate,
        needsGate = needsGate,
        maxPayloadBytes = maxPayloadBytes,
        timestampMode = timestampMode,
        headerSize = headerSize,
        _openFn = openFn,
        bytesSent = 0,
        bytesReceived = 0,
        fires = 0,
        recvFires = 0,
        drops = 0,
    }

    _byId[id] = reg
    if kind ~= KIND_RESPONSE then
        _byName[name] = reg
    end

    return reg
end

function Registry.get(id: number): Types.Registration?
    return _byId[id]
end

function Registry.getByName(name: string): Types.Registration?
    return _byName[name]
end

function Registry.count(): number
    return _nextId
end

function Registry.all(): { Types.Registration }
    local result = table.create(_nextId)
    for i = 1, _nextId do
        if _byId[i] then
            table.insert(result, _byId[i])
        end
    end
    return result
end

return table.freeze(Registry)
