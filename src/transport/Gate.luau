--!strict
--!native
-- Schema-aware validation and rate limiting.

local Types = require(script.Parent.Parent.Types)

-- Constants --------------------------------------------------------------

local DEFAULT_DEPTH = 16
local STRIKE_DECAY_SEC = 5

-- State ------------------------------------------------------------------

local _depth = DEFAULT_DEPTH
local _globalMaxPerSecond: number? = nil
local _bandwidthSoftLimit: number? = nil
local _bandwidthMaxStrikes = 10
local _rateLimits: { [number]: { [Player]: Types.RateLimitState } } = {}
local _globalLimits: { [Player]: Types.RateLimitState } = {}
local _bandwidthStrikes: { [Player]: number } = {}
local _bandwidthLastSeen: { [Player]: number } = {}

-- Private ----------------------------------------------------------------

local isfinite = math.isfinite
local floor = math.floor
local clock = os.clock
local minN = math.min

local function checkScalarBounds(value: number, minV: number?, maxV: number?): (boolean, string?)
    if not isfinite(value) then
        return false, "non-finite"
    end
    if minV and value < minV then
        return false, `below min {minV}`
    end
    if maxV and value > maxV then
        return false, `above max {maxV}`
    end
    return true, nil
end

local function checkVectorComponents(
    value: any,
    components: { string },
    minV: number,
    maxV: number
): (boolean, string?)
    for _, axis in components do
        local v = value[axis]
        if not isfinite(v) then
            return false, `component {axis} non-finite`
        end
        if v < minV or v > maxV then
            return false, `component {axis} ({v}) out of [{minV}, {maxV}]`
        end
    end
    return true, nil
end

local VEC2_AXES = table.freeze({ "X", "Y" })
local VEC3_AXES = table.freeze({ "X", "Y", "Z" })

local function scanValue(value: any, depth: number): boolean
    if depth <= 0 then
        return true
    end

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
        if not (isfinite(pos.X) and isfinite(pos.Y) and isfinite(pos.Z)) then
            return false
        end
        local rx, ry, rz = value:ToEulerAnglesXYZ()
        return isfinite(rx) and isfinite(ry) and isfinite(rz)
    end
    if t == "UDim" then
        return isfinite(value.Scale) and isfinite(value.Offset)
    end
    if t == "UDim2" then
        return isfinite(value.X.Scale)
            and isfinite(value.X.Offset)
            and isfinite(value.Y.Scale)
            and isfinite(value.Y.Offset)
    end
    if t == "Color3" then
        return isfinite(value.R) and isfinite(value.G) and isfinite(value.B)
    end
    if t == "NumberRange" then
        return isfinite(value.Min) and isfinite(value.Max)
    end
    if t == "Rect" then
        return isfinite(value.Min.X)
            and isfinite(value.Min.Y)
            and isfinite(value.Max.X)
            and isfinite(value.Max.Y)
    end
    if t == "Ray" then
        local o, d = value.Origin, value.Direction
        return isfinite(o.X)
            and isfinite(o.Y)
            and isfinite(o.Z)
            and isfinite(d.X)
            and isfinite(d.Y)
            and isfinite(d.Z)
    end
    if t == "table" then
        local nextDepth = depth - 1
        for _, v in value do
            if not scanValue(v, nextDepth) then
                return false
            end
        end
    end
    return true
end

local function validateWithCodec(
    value: any,
    codec: Types.InternalCodec<any>,
    depth: number
): (boolean, string?)
    if depth <= 0 then
        return true, nil
    end

    -- Optional: branch on nil before any other check.
    if codec._isOptional then
        if value == nil then
            return true, nil
        end
        local inner = codec._inner :: Types.InternalCodec<any>
        return validateWithCodec(value, inner, depth - 1)
    end

    -- typeCheck (cheap fail-fast for non-composite codecs).
    local typeCheck = codec._typeCheck
    if typeCheck and typeof(value) ~= typeCheck then
        return false, `expected {typeCheck}, got {typeof(value)}`
    end

    if codec._isBool then
        return true, nil
    end

    -- Enum: value is a string (typeCheck already validated typeof);
    -- decoded enums are guaranteed to be in the value set, but on
    -- send-side a caller may pass an arbitrary string.
    if codec._isEnum then
        local valid = codec._enumValues
        if valid and valid[value] == nil then
            return false, `not a valid enum value: "{value}"`
        end
        return true, nil
    end

    if codec._isInteger then
        if not isfinite(value) then
            return false, "non-finite"
        end
        if floor(value) ~= value then
            return false, "non-integer"
        end
        return checkScalarBounds(value, codec._min, codec._max)
    end

    -- Vector quantized: per-component range check.
    if (typeCheck == "Vector2" or typeCheck == "Vector3") and codec._min and codec._max then
        local axes = if typeCheck == "Vector2" then VEC2_AXES else VEC3_AXES
        return checkVectorComponents(value, axes, codec._min, codec._max)
    end

    -- Scalar quantized float (number with explicit range).
    if typeCheck == "number" and codec._min ~= nil and codec._max ~= nil then
        return checkScalarBounds(value, codec._min, codec._max)
    end

    if codec._isTagged then
        if typeof(value) ~= "table" then
            return false, "expected table for tagged variant"
        end
        local tagField = codec._tagField :: string
        local tagName = value[tagField]
        if tagName == nil then
            return false, `missing tagField "{tagField}"`
        end
        local variants = codec._variants :: { [string]: Types.InternalCodec<any> }
        local variant = variants[tagName]
        if not variant then
            return false, `unknown variant "{tagName}"`
        end
        return validateWithCodec(value, variant, depth - 1)
    end

    if codec._isArray then
        if typeof(value) ~= "table" then
            return false, "expected array"
        end
        local maxCount = codec._maxCount
        local len = #value
        if maxCount and len > maxCount then
            return false, `array length {len} exceeds max {maxCount}`
        end
        local element = codec._element :: Types.InternalCodec<any>
        local nextDepth = depth - 1
        for i = 1, len do
            local ok, reason = validateWithCodec(value[i], element, nextDepth)
            if not ok then
                return false, `[{i}]: {reason}`
            end
        end
        return true, nil
    end

    if codec._isMap then
        if typeof(value) ~= "table" then
            return false, "expected map"
        end
        local maxCount = codec._maxCount
        local keyCodec = codec._keyCodec :: Types.InternalCodec<any>
        local valCodec = codec._valueCodec :: Types.InternalCodec<any>
        local nextDepth = depth - 1
        local count = 0
        for k, v in value do
            count += 1
            if maxCount and count > maxCount then
                return false, `map size exceeds max {maxCount}`
            end
            local ok, reason = validateWithCodec(k, keyCodec, nextDepth)
            if not ok then
                return false, `key: {reason}`
            end
            ok, reason = validateWithCodec(v, valCodec, nextDepth)
            if not ok then
                return false, `value at key "{tostring(k)}": {reason}`
            end
        end
        return true, nil
    end

    if codec._isTuple then
        if typeof(value) ~= "table" then
            return false, "expected tuple"
        end
        local elements = codec._elements :: { Types.InternalCodec<any> }
        local nextDepth = depth - 1
        for i = 1, #elements do
            local ok, reason = validateWithCodec(value[i], elements[i], nextDepth)
            if not ok then
                return false, `[{i}]: {reason}`
            end
        end
        return true, nil
    end

    if codec._schema then
        if typeof(value) ~= "table" then
            return false, "expected table for struct"
        end
        local nextDepth = depth - 1
        for key, fieldCodec in codec._schema do
            local fieldVal = value[key]
            if fieldVal == nil and not fieldCodec._isBool then
                return false, `missing field "{key}"`
            end
            local ok, reason = validateWithCodec(fieldVal, fieldCodec, nextDepth)
            if not ok then
                return false, `field "{key}": {reason}`
            end
        end
        return true, nil
    end

    -- Fallback: NaN/inf scan for codecs without specific metadata
    -- (raw f32/f64, untagged Roblox types, buffer, etc.).
    if not scanValue(value, depth) then
        return false, "NaN/inf detected"
    end
    return true, nil
end

-- Public -----------------------------------------------------------------

local Gate = {}

function Gate.setDepth(depth: number): ()
    if depth < 1 then
        error(`[Lync] Gate.setDepth: depth must be >= 1, got {depth}`)
    end
    _depth = depth
end

function Gate.validate(value: any, codec: Types.InternalCodec<any>): (boolean, string?)
    return validateWithCodec(value, codec, _depth)
end

function Gate.scan(value: any): boolean
    return scanValue(value, _depth)
end

function Gate.checkRateLimit(reg: Types.Registration, player: Player): boolean
    local config = reg.rateLimit
    if not config then
        return true
    end

    local now = clock()

    local perPacket = _rateLimits[reg.id]
    if not perPacket then
        perPacket = {}
        _rateLimits[reg.id] = perPacket
    end

    local state = perPacket[player]
    if not state then
        state = { tokens = config.burst or 1, lastRefill = now, lastAccepted = 0 }
        perPacket[player] = state
    end

    if config.cooldown then
        if now - state.lastAccepted < config.cooldown then
            return false
        end
        state.lastAccepted = now
        return true
    end

    local maxPerSecond = config.maxPerSecond
    if not maxPerSecond then
        return true
    end

    local elapsed = now - state.lastRefill
    state.lastRefill = now
    state.tokens = minN(config.burst or 1, state.tokens + elapsed * maxPerSecond)

    if state.tokens >= 1 then
        state.tokens -= 1
        state.lastAccepted = now
        return true
    end
    return false
end

function Gate.checkGlobalRateLimit(player: Player): boolean
    local maxPS = _globalMaxPerSecond
    if not maxPS then
        return true
    end

    local now = clock()
    local state = _globalLimits[player]
    if not state then
        state = { tokens = maxPS, lastRefill = now, lastAccepted = 0 }
        _globalLimits[player] = state
    end

    local elapsed = now - state.lastRefill
    state.lastRefill = now
    state.tokens = minN(maxPS, state.tokens + elapsed * maxPS)

    if state.tokens >= 1 then
        state.tokens -= 1
        return true
    end
    return false
end

--[[
    Bandwidth check: frames at or below softLimit refund a strike;
    over-soft frames add one. Strikes also decay with idle time so a
    quiet player isn't penalized indefinitely.
]]
function Gate.checkBandwidth(player: Player, bytes: number): boolean
    if not _bandwidthSoftLimit then
        return true
    end

    local now = clock()
    local last = _bandwidthLastSeen[player]
    local strikes = _bandwidthStrikes[player] or 0

    if last then
        local decay = floor((now - last) / STRIKE_DECAY_SEC)
        if decay > 0 then
            strikes = if decay >= strikes then 0 else strikes - decay
        end
    end
    _bandwidthLastSeen[player] = now

    if bytes <= _bandwidthSoftLimit then
        if strikes > 0 then
            strikes -= 1
        end
        _bandwidthStrikes[player] = strikes
        return true
    end

    strikes += 1
    _bandwidthStrikes[player] = strikes
    return strikes <= _bandwidthMaxStrikes
end

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
    _bandwidthLastSeen[player] = nil
    for _, perPacket in _rateLimits do
        perPacket[player] = nil
    end
end

return table.freeze(Gate)
