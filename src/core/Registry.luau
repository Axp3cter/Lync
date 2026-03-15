--!strict
--!optimize 2
-- Registry.luau — Deterministic ID assignment for packets and queries.

local Types = require (script.Parent.Parent.Types)

type Codec<T> = Types.Codec<T>
type Registration = Types.Registration
type RateLimitConfig = Types.RateLimitConfig

-- Constants --------------------------------------------------------------

local VALID_RELIABILITY = table.freeze ({ reliable = true, unreliable = true })
local VALID_KIND = table.freeze ({ packet = true, request = true, response = true })

-- State ------------------------------------------------------------------

local _entries = {} :: { Registration }
local _names = {} :: { [string]: number }
local _nextId = 1

-- Private ----------------------------------------------------------------

local function assign (
    name: string,
    baseName: string,
    codec: Codec<any>,
    reliability: string,
    kind: string,
    signal: any,
    rateLimit: RateLimitConfig?,
    validate: ((data: any, player: Player) -> (boolean, string?))?
): Registration
    if _names[name] then
        error (`[Lync] Already registered: {name}`)
    end
    if not VALID_RELIABILITY[reliability] then
        error (`[Lync] Invalid reliability: {reliability}`)
    end
    if not VALID_KIND[kind] then
        error (`[Lync] Invalid kind: {kind}`)
    end

    if rateLimit then
        if rateLimit.maxPerSecond <= 0 then
            error (`[Lync] "{name}" rateLimit.maxPerSecond must be positive`)
        end
        if rateLimit.burstAllowance and rateLimit.burstAllowance <= 0 then
            error (`[Lync] "{name}" rateLimit.burstAllowance must be positive`)
        end
    end

    local id = _nextId
    _nextId += 1

    local reg: Registration = {
        id = id,
        name = name,
        baseName = baseName,
        codec = codec,
        reliability = reliability :: "reliable" | "unreliable",
        kind = kind :: "packet" | "request" | "response",
        partner = nil,
        signal = signal,
        rateLimit = rateLimit,
        validate = validate,
    }

    _entries[id] = reg
    _names[name] = id
    return reg
end

-- Public -----------------------------------------------------------------

local Registry = {}

function Registry.register (
    name: string,
    codec: Codec<any>,
    reliability: string,
    signal: any,
    rateLimit: RateLimitConfig?,
    validate: ((data: any, player: Player) -> (boolean, string?))?
): Registration
    return assign (name, name, codec, reliability, "packet", signal, rateLimit, validate)
end

function Registry.registerQueryPair (
    name: string,
    requestCodec: Codec<any>,
    responseCodec: Codec<any>,
    requestSignal: any,
    responseSignal: any
): (Registration, Registration)
    local req =
        assign (`{name}:req`, name, requestCodec, "reliable", "request", requestSignal, nil, nil)
    local resp = assign (
        `{name}:resp`,
        name,
        responseCodec,
        "reliable",
        "response",
        responseSignal,
        nil,
        nil
    )

    req.partner = resp.id
    resp.partner = req.id
    return req, resp
end

function Registry.get (id: number): Registration?
    return _entries[id]
end

function Registry.getByName (name: string): Registration?
    local id = _names[name]
    return if id then _entries[id] else nil
end

return table.freeze (Registry)
