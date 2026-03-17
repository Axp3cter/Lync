--!strict
--!optimize 2
-- Post-deserialization security: NaN/inf, rate limiting, custom validate.

local Types = require (script.Parent.Parent.Types)

type Registration = Types.Registration
type RateLimitConfig = Types.RateLimitConfig

-- Constants ----------------------------------------------------------

local DEFAULT_MAX_DEPTH = 16

local isfinite = math.isfinite
local min = math.min
local clock = os.clock

-- State --------------------------------------------------------------

type Bucket = {
    tokens: number,
    lastRef: number,
}

local _maxDepth = DEFAULT_MAX_DEPTH
local _buckets = {} :: { [Player]: { [number]: Bucket } }
local _dropHandlers =
    {} :: { (player: Player, reason: string, packetName: string, data: any?) -> () }

-- Private ------------------------------------------------------------

local function fireDrop (player: Player, reason: string, packetName: string, data: any?): ()
    for _, handler in _dropHandlers do
        handler (player, reason, packetName, data)
    end
end

@native
local function isClean (value: any, depth: number): boolean
    if depth > _maxDepth then
        return false
    end

    local t = type (value)

    if t == "number" then
        return isfinite (value)
    end

    -- String, boolean, nil are always clean. Exit before table/vector/userdata checks.
    if t == "string" or t == "boolean" or t == "nil" then
        return true
    end

    if t == "table" then
        local deeper = depth + 1
        for k, v in value do
            if not isClean (k, deeper) or not isClean (v, deeper) then
                return false
            end
        end
        return true
    end

    if t == "vector" then
        return isfinite (value.X) and isfinite (value.Y) and isfinite (value.Z)
    end

    if t == "userdata" then
        local ut = typeof (value)

        if ut == "Vector2" then
            return isfinite (value.X) and isfinite (value.Y)
        elseif ut == "Color3" then
            return isfinite (value.R) and isfinite (value.G) and isfinite (value.B)
        elseif ut == "CFrame" then
            local position = value.Position
            if
                not isfinite (position.X)
                or not isfinite (position.Y)
                or not isfinite (position.Z)
            then
                return false
            end
            local axis, angle = value:ToAxisAngle ()
            return isfinite (angle)
                and isfinite (axis.X)
                and isfinite (axis.Y)
                and isfinite (axis.Z)
        elseif ut == "UDim" then
            return isfinite (value.Scale)
        elseif ut == "UDim2" then
            return isfinite (value.X.Scale) and isfinite (value.Y.Scale)
        elseif ut == "NumberRange" then
            return isfinite (value.Min) and isfinite (value.Max)
        elseif ut == "Rect" then
            return isfinite (value.Min.X)
                and isfinite (value.Min.Y)
                and isfinite (value.Max.X)
                and isfinite (value.Max.Y)
        elseif ut == "Ray" then
            local origin = value.Origin
            local direction = value.Direction
            return isfinite (origin.X)
                and isfinite (origin.Y)
                and isfinite (origin.Z)
                and isfinite (direction.X)
                and isfinite (direction.Y)
                and isfinite (direction.Z)
        elseif ut == "Region3" then
            local position = value.CFrame.Position
            return isfinite (position.X) and isfinite (position.Y) and isfinite (position.Z)
        end
    end

    return true
end

local function checkRate (player: Player, reg: Registration): boolean
    local cfg = reg.rateLimit
    if not cfg then
        return true
    end

    local playerBuckets = _buckets[player]
    if not playerBuckets then
        return true
    end

    local id = reg.id
    local now = clock ()
    local cap = cfg.burstAllowance or cfg.maxPerSecond
    local bucket = playerBuckets[id]

    if not bucket then
        playerBuckets[id] = {
            tokens = cap - 1,
            lastRef = now,
        }
        return true
    end

    local elapsed = now - bucket.lastRef
    bucket.tokens = min (cap, bucket.tokens + elapsed * cfg.maxPerSecond)
    bucket.lastRef = now

    if bucket.tokens >= 1 then
        bucket.tokens -= 1
        return true
    end

    return false
end

-- Public -------------------------------------------------------------

local Gate = {}

-- Override the max recursion depth for NaN/inf scanning. Default 16. Range: 4–32.
function Gate.setMaxDepth (depth: number): ()
    if depth < 4 or depth > 32 then
        error (`[Lync] Gate max depth must be 4–32, got {depth}`)
    end
    _maxDepth = depth
end

function Gate.getMaxDepth (): number
    return _maxDepth
end

function Gate.check (value: any, reg: Registration, player: Player): boolean
    if not checkRate (player, reg) then
        fireDrop (player, "rate", reg.name, nil)
        return false
    end

    if not isClean (value, 1) then
        fireDrop (player, "nan", reg.name, value)
        return false
    end

    local validate = reg.validate
    if validate then
        local ok, reason = validate (value, player)
        if not ok then
            fireDrop (player, reason or "validate", reg.name, value)
            return false
        end
    end

    return true
end

function Gate.onDrop (
    callback: (player: Player, reason: string, packetName: string, data: any?) -> ()
): () -> ()
    table.insert (_dropHandlers, callback)

    return function (): ()
        local idx = table.find (_dropHandlers, callback)
        if idx then
            table.remove (_dropHandlers, idx)
        end
    end
end

-- Fires drop handlers without validation. Used by Reader for byte-budget violations.
function Gate.reportDrop (player: Player?, reason: string, packetName: string, data: any?): ()
    if player and #_dropHandlers > 0 then
        fireDrop (player, reason, packetName, data)
    end
end

function Gate.onPlayerAdded (player: Player): ()
    _buckets[player] = {}
end

function Gate.onPlayerRemoved (player: Player): ()
    _buckets[player] = nil
end

return table.freeze (Gate)
