--!strict
--!optimize 2
-- Gate.luau — Post-deserialization security: NaN/inf, rate limiting, custom validate.

local Types = require (script.Parent.Parent.Types)

type Registration = Types.Registration
type RateLimitConfig = Types.RateLimitConfig

-- Constants --------------------------------------------------------------

local MAX_DEPTH = 8

local huge = math.huge
local min = math.min
local clock = os.clock

-- State ------------------------------------------------------------------

type Bucket = {
    tokens: number,
    cap: number,
    rate: number,
    lastRef: number,
}

local _buckets = {} :: { [Player]: { [number]: Bucket } }
local _callback = nil :: ((player: Player, reason: string, packetName: string, data: any?) -> ())?

-- Private ----------------------------------------------------------------

local function isFinite (value: number): boolean
    return value == value and value ~= huge and value ~= -huge
end

local function isClean (value: any, depth: number): boolean
    if depth > MAX_DEPTH then
        return true
    end

    local t = typeof (value)

    if t == "number" then
        return isFinite (value)
    elseif t == "Vector2" then
        return isFinite (value.X) and isFinite (value.Y)
    elseif t == "Vector3" then
        return isFinite (value.X) and isFinite (value.Y) and isFinite (value.Z)
    elseif t == "CFrame" then
        local position = value.Position
        if not isFinite (position.X) or not isFinite (position.Y) or not isFinite (position.Z) then
            return false
        end
        local _, angle = value:ToAxisAngle ()
        return isFinite (angle)
    elseif t == "table" then
        local deeper = depth + 1
        for k, v in value do
            if not isClean (k, deeper) then
                return false
            end
            if not isClean (v, deeper) then
                return false
            end
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
    local bucket = playerBuckets[id]
    local now = clock ()

    if not bucket then
        local cap = cfg.burstAllowance or cfg.maxPerSecond
        playerBuckets[id] = {
            tokens = cap - 1,
            cap = cap,
            rate = cfg.maxPerSecond,
            lastRef = now,
        }
        return true
    end

    local elapsed = now - bucket.lastRef
    bucket.tokens = min (bucket.cap, bucket.tokens + elapsed * bucket.rate)
    bucket.lastRef = now

    if bucket.tokens >= 1 then
        bucket.tokens -= 1
        return true
    end

    return false
end

local function drop (player: Player, reason: string, name: string, data: any?): ()
    if _callback then
        _callback (player, reason, name, data)
    end
end

-- Public -----------------------------------------------------------------

local Gate = {}

function Gate.check (value: any, reg: Registration, player: Player): boolean
    if not isClean (value, 1) then
        drop (player, "nan", reg.name, value)
        return false
    end

    if not checkRate (player, reg) then
        drop (player, "rate", reg.name, nil)
        return false
    end

    local validate = reg.validate
    if validate then
        local ok, reason = validate (value, player)
        if not ok then
            drop (player, reason or "validate", reg.name, value)
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
