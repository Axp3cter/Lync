--!strict
--!optimize 2
-- Post-deserialization security: NaN/inf, rate limiting, custom validate.

local Types = require (script.Parent.Parent.Types)

type Registration = Types.Registration
type RateLimitConfig = Types.RateLimitConfig

-- Constants --------------------------------------------------------------

local MAX_DEPTH = 8

local isfinite = math.isfinite
local min = math.min
local clock = os.clock

-- State ------------------------------------------------------------------

type Bucket = {
    tokens: number,
    lastRef: number,
}

local _buckets = {} :: { [Player]: { [number]: Bucket } }
local _callback = nil :: ((player: Player, reason: string, packetName: string, data: any?) -> ())?

-- Private ----------------------------------------------------------------

local function isClean (value: any, depth: number): boolean
    if depth > MAX_DEPTH then
        return false
    end

    local t = type (value)

    if t == "number" then
        return isfinite (value)
    elseif t == "table" then
        local deeper = depth + 1
        for k, v in value do
            if not isClean (k, deeper) or not isClean (v, deeper) then
                return false
            end
        end
        return true
    elseif t == "vector" then
        return isfinite (value.X) and isfinite (value.Y) and isfinite (value.Z)
    elseif t == "userdata" then
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

-- Public -----------------------------------------------------------------

local Gate = {}

function Gate.check (value: any, reg: Registration, player: Player): boolean
    if not checkRate (player, reg) then
        if _callback then
            _callback (player, "rate", reg.name, nil)
        end
        return false
    end

    if not isClean (value, 1) then
        if _callback then
            _callback (player, "nan", reg.name, value)
        end
        return false
    end

    local validate = reg.validate
    if validate then
        local ok, reason = validate (value, player)
        if not ok then
            if _callback then
                _callback (player, reason or "validate", reg.name, value)
            end
            return false
        end
    end

    return true
end

function Gate.onDrop (
    callback: (player: Player, reason: string, packetName: string, data: any?) -> ()
): ()
    _callback = callback
end

function Gate.onPlayerAdded (player: Player): ()
    _buckets[player] = {}
end

function Gate.onPlayerRemoved (player: Player): ()
    _buckets[player] = nil
end

return table.freeze (Gate)
