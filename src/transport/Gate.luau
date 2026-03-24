--!strict
--!native
-- Schema-aware validation and rate limiting.

local Types      = require(script.Parent.Parent.Types)
local Registry   = require(script.Parent.Parent.internal.Registry)
local Middleware = require(script.Parent.Parent.internal.Middleware)

-- Constants -----------------------------------------------------------

local DEFAULT_DEPTH = 16

-- State ---------------------------------------------------------------

local _depth = DEFAULT_DEPTH
local _rateLimits: { [number]: { [Player]: Types.RateLimitState } } = {}
local _globalLimits: { [Player]: Types.RateLimitState } = {}
local _globalMaxPerSecond: number? = nil
local _bandwidthSoftLimit: number? = nil
local _bandwidthMaxStrikes: number? = nil
local _bandwidthStrikes: { [Player]: number } = {}

-- Private -------------------------------------------------------------

local isfinite = math.isfinite
local floor    = math.floor
local abs      = math.abs
local clock    = os.clock

--[[
    Checks a number value for NaN/inf and optionally range + integrality.
    Returns true if the value passes all checks.
]]
local function validateNumber(
    value: number,
    isInteger: boolean?,
    minVal: number?,
    maxVal: number?
): boolean
    if not isfinite(value) then return false end

    if isInteger and floor(value) ~= value then
        return false
    end

    if minVal and value < minVal then return false end
    if maxVal and value > maxVal then return false end

    return true
end

--[[
    Recursive NaN/inf scan for values without schema metadata.
    Used as fallback for f32, f64, auto, and Roblox types.
]]
local function scanValue(value: any, depth: number): boolean
    if depth <= 0 then return true end

    local t = typeof(value)

    if t == "number" then
        return isfinite(value)
    end

    if t == "Vector2" then
        return isfinite(value.X) and isfinite(value.Y)
    end

    if t == "Vector3" then
        return isfinite(value.X) and isfinite(value.Y) and isfinite(value.Z)
    end

    if t == "CFrame" then
        local pos = value.Position
        if not isfinite(pos.X) or not isfinite(pos.Y) or not isfinite(pos.Z) then
            return false
        end
        local rx, ry, rz = value:ToEulerAnglesXYZ()
        return isfinite(rx) and isfinite(ry) and isfinite(rz)
    end

    if t == "UDim" then
        return isfinite(value.Scale) and isfinite(value.Offset)
    end

    if t == "UDim2" then
        return isfinite(value.X.Scale) and isfinite(value.X.Offset)
            and isfinite(value.Y.Scale) and isfinite(value.Y.Offset)
    end

    if t == "Color3" then
        return isfinite(value.R) and isfinite(value.G) and isfinite(value.B)
    end

    if t == "NumberRange" then
        return isfinite(value.Min) and isfinite(value.Max)
    end

    if t == "Rect" then
        return isfinite(value.Min.X) and isfinite(value.Min.Y)
            and isfinite(value.Max.X) and isfinite(value.Max.Y)
    end

    if t == "Ray" then
        local o = value.Origin
        local d = value.Direction
        return isfinite(o.X) and isfinite(o.Y) and isfinite(o.Z)
            and isfinite(d.X) and isfinite(d.Y) and isfinite(d.Z)
    end

    if t == "table" then
        local nextDepth = depth - 1
        for _, v in value do
            if not scanValue(v, nextDepth) then
                return false
            end
        end
        return true
    end

    -- string, boolean, nil, buffer, Instance, etc. are always clean
    return true
end

--[[
    Schema-aware validation. Dispatches based on codec metadata.
    Returns true if valid, false + reason if not.
]]
local function validateWithCodec(
    value: any,
    codec: Types.InternalCodec<any>,
    depth: number
): (boolean, string?)
    if depth <= 0 then return true, nil end

    local codecAny = codec :: any

    -- Type check
    local typeCheck = codecAny._typeCheck
    if typeCheck then
        if typeof(value) ~= typeCheck then
            return false, `expected {typeCheck}, got {typeof(value)}`
        end
    end

    -- Boolean: typeof check is sufficient
    if codecAny._isBool then
        return true, nil
    end

    -- Integer + range
    if codecAny._isInteger then
        if not isfinite(value) then return false, "non-finite" end
        if floor(value) ~= value then return false, "non-integer" end
        local minV = codecAny._min
        local maxV = codecAny._max
        if minV and value < minV then return false, `below min {minV}` end
        if maxV and value > maxV then return false, `above max {maxV}` end
        return true, nil
    end

    -- Float with range (quantized float)
    if codecAny._min ~= nil and codecAny._max ~= nil and not codecAny._isInteger then
        if not isfinite(value) then return false, "non-finite" end
        return true, nil
    end

    -- Struct schema: recursive per-field validation
    if codecAny._schema then
        if typeof(value) ~= "table" then
            return false, "expected table for struct"
        end

        local schema = codecAny._schema
        for key, fieldCodec in schema do
            local fieldVal = value[key]
            if fieldVal == nil and not (fieldCodec :: any)._isBool then
                return false, `missing field "{key}"`
            end
            local ok, reason = validateWithCodec(fieldVal, fieldCodec, depth - 1)
            if not ok then
                return false, `field "{key}": {reason}`
            end
        end
        return true, nil
    end

    -- Fallback: generic NaN scan for f32, f64, auto, and Roblox types
    if not scanValue(value, depth) then
        return false, "NaN/inf detected"
    end

    return true, nil
end

-- Public --------------------------------------------------------------

local Gate = {}

function Gate.setDepth(depth: number): ()
    _depth = depth
end

function Gate.validate(
    value: any,
    codec: Types.InternalCodec<any>
): (boolean, string?)
    return validateWithCodec(value, codec, _depth)
end

function Gate.scan(value: any): boolean
    return scanValue(value, _depth)
end

-- Rate limiting -------------------------------------------------------

function Gate.checkRateLimit(reg: Types.Registration, player: Player): boolean
    local config = reg.rateLimit
    if not config then return true end

    local now = clock()

    -- Get or create per-player state
    local perPacket = _rateLimits[reg.id]
    if not perPacket then
        perPacket = {}
        _rateLimits[reg.id] = perPacket
    end

    local state = perPacket[player]
    if not state then
        state = {
            tokens = config.burst or 1,
            lastRefill = now,
            lastAccepted = 0,
        }
        perPacket[player] = state
    end

    -- Cooldown mode
    if config.cooldown then
        if now - state.lastAccepted < config.cooldown then
            return false
        end
        state.lastAccepted = now
        return true
    end

    -- Token bucket mode
    local maxPerSecond = config.maxPerSecond
    if not maxPerSecond then return true end

    local elapsed = now - state.lastRefill
    state.lastRefill = now

    local burst = config.burst or 1
    state.tokens = math.min(burst, state.tokens + elapsed * maxPerSecond)

    if state.tokens >= 1 then
        state.tokens -= 1
        state.lastAccepted = now
        return true
    end

    return false
end

function Gate.checkGlobalRateLimit(player: Player): boolean
    local maxPS = _globalMaxPerSecond
    if not maxPS then return true end

    local now = clock()
    local state = _globalLimits[player]
    if not state then
        state = { tokens = maxPS, lastRefill = now, lastAccepted = 0 }
        _globalLimits[player] = state
    end

    local elapsed = now - state.lastRefill
    state.lastRefill = now
    state.tokens = math.min(maxPS, state.tokens + elapsed * maxPS)

    if state.tokens >= 1 then
        state.tokens -= 1
        return true
    end

    return false
end

function Gate.checkBandwidth(player: Player, bytes: number): boolean
    if not _bandwidthSoftLimit then return true end

    if bytes <= _bandwidthSoftLimit then
        local strikes = _bandwidthStrikes[player]
        if strikes and strikes > 0 then
            _bandwidthStrikes[player] = strikes - 1
        end
        return true
    end

    local current = _bandwidthStrikes[player]
    local strikes = (if current then current else 0) + 1
    _bandwidthStrikes[player] = strikes

    local maxStrikes = if _bandwidthMaxStrikes then _bandwidthMaxStrikes else 10
    return strikes <= maxStrikes
end

-- Configuration -------------------------------------------------------

function Gate.configureGlobalRateLimit(maxPerSecond: number): ()
    _globalMaxPerSecond = maxPerSecond
end

function Gate.configureBandwidth(softLimit: number, maxStrikes: number): ()
    _bandwidthSoftLimit = softLimit
    _bandwidthMaxStrikes = maxStrikes
end

function Gate.clearPlayer(player: Player): ()
    _globalLimits[player] = nil
    _bandwidthStrikes[player] = nil

    for _, perPacket in _rateLimits do
        perPacket[player] = nil
    end
end

return table.freeze(Gate)
