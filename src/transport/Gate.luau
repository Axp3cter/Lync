--!strict
--!native
-- Schema-aware validation and rate limiting.

local Log = require(script.Parent.Parent.util.Log)
local Types = require(script.Parent.Parent.Types)

-- Constants --------------------------------------------------------------

local DEFAULT_DEPTH = 16
local STRIKE_DECAY_SEC = 5

local VEC2_AXES = table.freeze({ "X", "Y" })
local VEC3_AXES = table.freeze({ "X", "Y", "Z" })

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

-- Validators return string?: nil = accepted, non-nil = rejection reason.
local validateWithCodec -- forward decl (recursive)

local function checkScalarBounds(value: number, minV: number?, maxV: number?): string?
    if not isfinite(value) then
        return "non-finite"
    end
    if minV and value < minV then
        return `below min {minV}`
    end
    if maxV and value > maxV then
        return `above max {maxV}`
    end
    return nil
end

local function checkVectorComponents(
    value: any,
    components: { string },
    minV: number,
    maxV: number
): string?
    for _, axis in components do
        local v = value[axis]
        if not isfinite(v) then
            return `component {axis} non-finite`
        end
        if v < minV or v > maxV then
            return `component {axis} ({v}) out of [{minV}, {maxV}]`
        end
    end
    return nil
end

--[[
    Untyped fallback NaN/inf scan. Used when a codec lacks specific metadata
    (e.g. user custom codec) and as the last step of validateWithCodec.
    Bounded by `depth` so a self-referential table can't recurse forever.
]]
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

local function validateString(value: any, codec: Types.InternalCodec<any>): string?
    local maxLen = codec._maxStringLength
    if maxLen and #(value :: string) > maxLen then
        return `string length {#value} exceeds max {maxLen}`
    end
    return nil
end

local function validateEnum(value: any, codec: Types.InternalCodec<any>): string?
    local valid = codec._enumValues
    if valid and valid[value] == nil then
        return `not a valid enum value: "{value}"`
    end
    return nil
end

local function validateInteger(value: any, codec: Types.InternalCodec<any>): string?
    if not isfinite(value) then
        return "non-finite"
    end
    if floor(value) ~= value then
        return "non-integer"
    end
    return checkScalarBounds(value, codec._min, codec._max)
end

local function validateTagged(value: any, codec: Types.InternalCodec<any>, depth: number): string?
    if typeof(value) ~= "table" then
        return "expected table for tagged variant"
    end
    local tagField = codec._tagField :: string
    local tagName = value[tagField]
    if tagName == nil then
        return `missing tagField "{tagField}"`
    end
    local variants = codec._variants :: { [string]: Types.InternalCodec<any> }
    local variant = variants[tagName]
    if not variant then
        return `unknown variant "{tagName}"`
    end
    return validateWithCodec(value, variant, depth - 1)
end

local function validateArray(value: any, codec: Types.InternalCodec<any>, depth: number): string?
    if typeof(value) ~= "table" then
        return "expected array"
    end
    local maxCount = codec._maxCount
    local len = #value
    if maxCount and len > maxCount then
        return `array length {len} exceeds max {maxCount}`
    end
    local element = codec._element :: Types.InternalCodec<any>
    local nextDepth = depth - 1
    for i = 1, len do
        local reason = validateWithCodec(value[i], element, nextDepth)
        if reason then
            return `[{i}]: {reason}`
        end
    end
    return nil
end

local function validateMap(value: any, codec: Types.InternalCodec<any>, depth: number): string?
    if typeof(value) ~= "table" then
        return "expected map"
    end
    local maxCount = codec._maxCount
    local keyCodec = codec._keyCodec :: Types.InternalCodec<any>
    local valCodec = codec._valueCodec :: Types.InternalCodec<any>
    local nextDepth = depth - 1
    local count = 0
    for k, v in value do
        count += 1
        if maxCount and count > maxCount then
            return `map size exceeds max {maxCount}`
        end
        local reason = validateWithCodec(k, keyCodec, nextDepth)
        if reason then
            return `key: {reason}`
        end
        reason = validateWithCodec(v, valCodec, nextDepth)
        if reason then
            return `value at key "{tostring(k)}": {reason}`
        end
    end
    return nil
end

local function validateTuple(value: any, codec: Types.InternalCodec<any>, depth: number): string?
    if typeof(value) ~= "table" then
        return "expected tuple"
    end
    local elements = codec._elements :: { Types.InternalCodec<any> }
    local nextDepth = depth - 1
    for i = 1, #elements do
        local reason = validateWithCodec(value[i], elements[i], nextDepth)
        if reason then
            return `[{i}]: {reason}`
        end
    end
    return nil
end

local function validateStruct(value: any, codec: Types.InternalCodec<any>, depth: number): string?
    if typeof(value) ~= "table" then
        return "expected table for struct"
    end
    local nextDepth = depth - 1
    for key, fieldCodec in codec._schema :: { [string]: Types.InternalCodec<any> } do
        local fieldVal = value[key]
        -- Bool fields default to false when missing; everything else must be present.
        if fieldVal == nil and not fieldCodec._isBool then
            return `missing field "{key}"`
        end
        local reason = validateWithCodec(fieldVal, fieldCodec, nextDepth)
        if reason then
            return `field "{key}": {reason}`
        end
    end
    return nil
end

function validateWithCodec(value: any, codec: Types.InternalCodec<any>, depth: number): string?
    -- Peel Optional layers in a loop so optional(optional(X)) chains stay flat.
    while codec._isOptional do
        if depth <= 0 then
            return nil
        end
        if value == nil then
            return nil
        end
        codec = codec._inner :: Types.InternalCodec<any>
        depth -= 1
    end
    if depth <= 0 then
        return nil
    end

    local typeCheck = codec._typeCheck
    if typeCheck and typeof(value) ~= typeCheck then
        return `expected {typeCheck}, got {typeof(value)}`
    end

    if typeCheck == "string" then
        local reason = validateString(value, codec)
        if reason then
            return reason
        end
    end

    if codec._isBool then
        return nil
    end
    if codec._isEnum then
        return validateEnum(value, codec)
    end
    if codec._isInteger then
        return validateInteger(value, codec)
    end

    if (typeCheck == "Vector2" or typeCheck == "Vector3") and codec._min and codec._max then
        local axes = if typeCheck == "Vector2" then VEC2_AXES else VEC3_AXES
        return checkVectorComponents(value, axes, codec._min, codec._max)
    end
    if typeCheck == "number" and codec._min ~= nil and codec._max ~= nil then
        return checkScalarBounds(value, codec._min, codec._max)
    end

    if codec._isTagged then
        return validateTagged(value, codec, depth)
    end
    if codec._isArray then
        return validateArray(value, codec, depth)
    end
    if codec._isMap then
        return validateMap(value, codec, depth)
    end
    if codec._isTuple then
        return validateTuple(value, codec, depth)
    end
    if codec._schema then
        return validateStruct(value, codec, depth)
    end

    -- No specific metadata: fall back to a depth-bounded NaN/inf scan.
    if not scanValue(value, depth) then
        return "NaN/inf detected"
    end
    return nil
end

local function getOrCreateBucket(
    map: { [Player]: Types.RateLimitState },
    player: Player,
    burst: number,
    now: number
): Types.RateLimitState
    local state = map[player]
    if not state then
        state = { tokens = burst, lastRefill = now, lastAccepted = 0 }
        map[player] = state
    end
    return state
end

local function consumeToken(
    state: Types.RateLimitState,
    now: number,
    capacity: number,
    rate: number
): boolean
    local elapsed = now - state.lastRefill
    state.lastRefill = now
    state.tokens = minN(capacity, state.tokens + elapsed * rate)

    if state.tokens >= 1 then
        state.tokens -= 1
        state.lastAccepted = now
        return true
    end
    return false
end

-- Public -----------------------------------------------------------------

local Gate = {}

function Gate.setDepth(depth: number): ()
    if depth < 1 then
        Log.error(`depth must be >= 1, got {depth}`)
    end
    _depth = depth
end

function Gate.validate(value: any, codec: Types.InternalCodec<any>): string?
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

    local burst = config.burst or 1
    local state = getOrCreateBucket(perPacket, player, burst, now)

    -- Cooldown form: reject anything within `cooldown` seconds of the last accept.
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
    return consumeToken(state, now, burst, maxPerSecond)
end

function Gate.checkGlobalRateLimit(player: Player): boolean
    local maxPS = _globalMaxPerSecond
    if not maxPS then
        return true
    end

    local now = clock()
    local state = getOrCreateBucket(_globalLimits, player, maxPS, now)
    return consumeToken(state, now, maxPS, maxPS)
end

--[[
    Bandwidth check. Frames at or below softLimit refund a strike; frames
    above add one. Strikes decay with idle time so a quiet player isn't
    penalized indefinitely after a noisy burst.
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

function Gate.reset(): ()
    _depth = DEFAULT_DEPTH
    _globalMaxPerSecond = nil
    _bandwidthSoftLimit = nil
    _bandwidthMaxStrikes = 10
    table.clear(_rateLimits)
    table.clear(_globalLimits)
    table.clear(_bandwidthStrikes)
    table.clear(_bandwidthLastSeen)
end

return table.freeze(Gate)
