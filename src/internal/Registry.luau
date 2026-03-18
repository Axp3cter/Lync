--!strict
--!optimize 2
-- Deterministic ID assignment for packets and queries.

local Types = require(script.Parent.Parent.Types)

type Codec<T> = Types.Codec<T>
type Registration = Types.Registration
type RateLimitConfig = Types.RateLimitConfig

-- Constants -----------------------------------------------------------

local KIND_PACKET = 0
local KIND_REQUEST = 1
local KIND_RESPONSE = 2
local MAX_PACKETS = 255

-- State ---------------------------------------------------------------

local _entries = {} :: { Registration }
local _names = {} :: { [string]: number }
local _nextId = 1

-- Private -------------------------------------------------------------

local function assign(
    name: string,
    baseName: string,
    codec: Codec<any>,
    isUnreliable: boolean,
    kind: number,
    signal: any,
    rateLimit: RateLimitConfig?,
    validate: ((data: any, player: Player) -> (boolean, string?))?,
    maxPayloadBytes: number?,
    timestampMode: number?
): Registration
    if _names[name] then
        error(`[Lync] Duplicate registration: "{name}"`)
    end
    if _nextId > MAX_PACKETS then
        error(`[Lync] Registration limit reached: {MAX_PACKETS} max`)
    end

    if rateLimit then
        if rateLimit.maxPerSecond <= 0 then
            error(`[Lync] maxPerSecond must be positive: "{name}"`)
        end
        if rateLimit.burstAllowance and rateLimit.burstAllowance <= 0 then
            error(`[Lync] burstAllowance must be positive: "{name}"`)
        end
    end

    if maxPayloadBytes and maxPayloadBytes <= 0 then
        error(`[Lync] maxPayloadBytes must be positive: "{name}"`)
    end

    local id = _nextId
    _nextId += 1

    local reg: Registration = {
        id = id,
        name = name,
        baseName = baseName,
        codec = codec,
        isUnreliable = isUnreliable,
        kind = kind,
        partner = nil,
        signal = signal,
        rateLimit = rateLimit,
        validate = validate,
        needsGate = rateLimit ~= nil or validate ~= nil,
        maxPayloadBytes = maxPayloadBytes,
        timestampMode = timestampMode or 0,
        _openFn = nil :: any, -- set by Packet.define via Channel.resolveOpenFn
        bytesSent = 0,
        bytesReceived = 0,
        fires = 0,
        recvFires = 0,
        drops = 0,
    }

    _entries[id] = reg
    _names[name] = id
    return reg
end

-- Public --------------------------------------------------------------

local Registry = {
    KIND_PACKET = KIND_PACKET,
    KIND_REQUEST = KIND_REQUEST,
    KIND_RESPONSE = KIND_RESPONSE,
}

function Registry.register(
    name: string,
    codec: Codec<any>,
    isUnreliable: boolean,
    signal: any,
    rateLimit: RateLimitConfig?,
    validate: ((data: any, player: Player) -> (boolean, string?))?,
    maxPayloadBytes: number?,
    timestampMode: number?
): Registration
    return assign(
        name,
        name,
        codec,
        isUnreliable,
        KIND_PACKET,
        signal,
        rateLimit,
        validate,
        maxPayloadBytes,
        timestampMode
    )
end

function Registry.registerQueryPair(
    name: string,
    requestCodec: Codec<any>,
    responseCodec: Codec<any>,
    requestSignal: any,
    responseSignal: any,
    rateLimit: RateLimitConfig?,
    validate: ((data: any, player: Player) -> (boolean, string?))?
): (Registration, Registration)
    local req = assign(
        `{name}:req`,
        name,
        requestCodec,
        false,
        KIND_REQUEST,
        requestSignal,
        rateLimit,
        validate
    )
    local resp =
        assign(`{name}:resp`, name, responseCodec, false, KIND_RESPONSE, responseSignal, nil, nil)

    req.partner = resp.id
    resp.partner = req.id
    return req, resp
end

function Registry.get(id: number): Registration?
    return _entries[id]
end

function Registry.getByName(name: string): Registration?
    local id = _names[name]
    return if id then _entries[id] else nil
end

function Registry.forEach(fn: (reg: Registration) -> ()): ()
    for _, reg in _entries do
        fn(reg)
    end
end

return table.freeze(Registry)
