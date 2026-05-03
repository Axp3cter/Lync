--!strict
--!native
-- Delta scalars: zigzag-varint diff against previous frame for ints, floats, vec3, CFrame.

local Base = require(script.Parent.Parent.Base)
local Baseline = require(script.Parent.Parent.Parent.internal.Baseline)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Quantize = require(script.Parent.Parent.Parent.util.Quantize)
local Quat = require(script.Parent.Parent.Parent.util.Quat)
local Shared = require(script.Parent.Parent.composite.Shared)
local Types = require(script.Parent.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.primitive.Varint)
local Zint = require(script.Parent.Parent.primitive.Zint)

-- Constants --------------------------------------------------------------

local I32_MIN = -0x80000000
local I32_MAX = 0x7FFFFFFF

-- deltaCFrame header bits: which components changed since the last frame.
local CF_X = 0x01
local CF_Y = 0x02
local CF_Z = 0x04
local CF_ROT = 0x08
local CF_ALL = 0x0F

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local allocDeltaId = Shared.allocDeltaId
local floor = math.floor
local clamp = math.clamp
local round = math.round
local band = bit32.band
local bor = bit32.bor
local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local readu32 = buffer.readu32
local writeu32 = buffer.writeu32
local bufLen = buffer.len
local varintWrite = Varint.write
local varintRead = Varint.read
local zigzagEncode = Zint.encode
local zigzagDecode = Zint.decode
local quatPack = Quat.pack
local quatUnpack = Quat.unpack
local quatFromCFrame = Quat.fromCFrame

local function ensure(ch: Types.ChannelState, n: number): ()
    if ch.cursor + n > ch.size then
        alloc(ch, n)
    end
end

-- Public -----------------------------------------------------------------

local DeltaScalar = {}

--[[
    Variable-length integer that emits zigzag varint of (current - previous).
    First frame uses `min` as the implicit prev so the initial value encodes
    as (value - min). Reliable transport only — a dropped frame desyncs prev.

    Wire: 1 byte for unchanged or [-96, 95] mutations; up to 5 bytes for full i32.
]]
function DeltaScalar.deltaInt(min: number, max: number): Types.InternalCodec<number>
    if min > max then
        Log.error(`min ({min}) must be <= max ({max})`)
    end
    if floor(min) ~= min or floor(max) ~= max then
        Log.error("bounds must be integers")
    end
    if max - min > I32_MAX then
        Log.error(`range too wide; (max - min) must fit in i32, got {max - min}`)
    end

    local deltaId = allocDeltaId()

    return table.freeze({
        _isDelta = true,
        _typeCheck = "number",
        _isInteger = true,
        _min = min,
        _max = max,

        write = function(ch: Types.ChannelState, value: number): ()
            if value < min or value > max then
                Log.error(`value {value} out of range [{min}, {max}]`)
            end
            if floor(value) ~= value then
                Log.error(`value {value} must be an integer`)
            end

            local cache = ch.deltas[deltaId] :: any
            local prev = if cache then cache.scalar :: number else min
            varintWrite(ch, zigzagEncode(value - prev))

            if cache then
                cache.scalar = value
            else
                ch.deltas[deltaId] = { scalar = value } :: any
            end
        end,

        read = function(src: buffer, pos: number, _refs: { Instance }?): (number, number)
            local raw, consumed = varintRead(src, pos)
            if consumed == 0 then
                Log.error("truncated deltaInt")
            end

            local cached = Baseline.getCache(deltaId)
            local prev = if cached ~= nil then cached :: number else min
            local value = prev + zigzagDecode(raw)
            if value < min or value > max then
                Log.error(`deltaInt decoded value {value} out of range [{min}, {max}]`)
            end
            Baseline.setCache(deltaId, value)
            return value, consumed
        end,
    }) :: Types.InternalCodec<number>
end

--[[
    Quantized float with diffs in integer wire space (post-quantize). Storing
    the quantized representative — not the float — across frames means
    accumulating diffs over thousands of frames cannot drift past the grid.
]]
function DeltaScalar.deltaFloat(
    min: number,
    max: number,
    precision: number
): Types.InternalCodec<number>
    if max - min == 0 then
        return Base.constant(min)
    end

    local _, _, _, scale, invScale, delta = Quantize.setup("Lync.deltaFloat", min, max, precision)
    local deltaId = allocDeltaId()

    return table.freeze({
        _isDelta = true,
        _typeCheck = "number",
        _min = min,
        _max = max,

        write = function(ch: Types.ChannelState, value: number): ()
            local q = round(clamp(value - min, 0, delta) * scale)
            local cache = ch.deltas[deltaId] :: any
            local prev = if cache then cache.scalar :: number else 0
            varintWrite(ch, zigzagEncode(q - prev))

            if cache then
                cache.scalar = q
            else
                ch.deltas[deltaId] = { scalar = q } :: any
            end
        end,

        read = function(src: buffer, pos: number, _refs: { Instance }?): (number, number)
            local raw, consumed = varintRead(src, pos)
            if consumed == 0 then
                Log.error("truncated deltaFloat")
            end

            local cached = Baseline.getCache(deltaId)
            local prev = if cached ~= nil then cached :: number else 0
            local q = prev + zigzagDecode(raw)
            Baseline.setCache(deltaId, q)
            return q * invScale + min, consumed
        end,
    }) :: Types.InternalCodec<number>
end

--[[
    Quantized Vector3 with per-axis zigzag varint diffs. Static value: 3 bytes
    (three zero zigzags); typical < 1 stud motion at 0.01-stud precision: 3-6
    bytes. Baseline vec3 = 12 bytes, so 4x reduction at the static end.
]]
function DeltaScalar.deltaVec3(
    min: number,
    max: number,
    precision: number
): Types.InternalCodec<Vector3>
    if max - min == 0 then
        return Base.constant(Vector3.new(min, min, min)) :: Types.InternalCodec<Vector3>
    end

    local _, _, _, scale, invScale, delta = Quantize.setup("Lync.deltaVec3", min, max, precision)
    local deltaId = allocDeltaId()

    local function quantize(v: Vector3): (number, number, number)
        return round(clamp(v.X - min, 0, delta) * scale),
            round(clamp(v.Y - min, 0, delta) * scale),
            round(clamp(v.Z - min, 0, delta) * scale)
    end

    local function dequantize(qx: number, qy: number, qz: number): Vector3
        return Vector3.new(qx * invScale + min, qy * invScale + min, qz * invScale + min)
    end

    return table.freeze({
        _isDelta = true,
        _typeCheck = "Vector3",
        _min = min,
        _max = max,

        write = function(ch: Types.ChannelState, value: Vector3): ()
            local qx, qy, qz = quantize(value)
            local cache = ch.deltas[deltaId] :: any
            local px, py, pz = 0, 0, 0
            if cache then
                px, py, pz = cache.qx :: number, cache.qy :: number, cache.qz :: number
            end

            varintWrite(ch, zigzagEncode(qx - px))
            varintWrite(ch, zigzagEncode(qy - py))
            varintWrite(ch, zigzagEncode(qz - pz))

            if cache then
                cache.qx, cache.qy, cache.qz = qx, qy, qz
            else
                ch.deltas[deltaId] = { qx = qx, qy = qy, qz = qz } :: any
            end
        end,

        read = function(src: buffer, pos: number, _refs: { Instance }?): (Vector3, number)
            local rx, cx = varintRead(src, pos)
            if cx == 0 then
                Log.error("truncated deltaVec3 X")
            end
            local ry, cy = varintRead(src, pos + cx)
            if cy == 0 then
                Log.error("truncated deltaVec3 Y")
            end
            local rz, cz = varintRead(src, pos + cx + cy)
            if cz == 0 then
                Log.error("truncated deltaVec3 Z")
            end

            local cached = Baseline.getCache(deltaId) :: any
            local px, py, pz = 0, 0, 0
            if cached then
                px, py, pz = cached.qx, cached.qy, cached.qz
            end
            local qx = px + zigzagDecode(rx)
            local qy = py + zigzagDecode(ry)
            local qz = pz + zigzagDecode(rz)
            Baseline.setCache(deltaId, { qx = qx, qy = qy, qz = qz })

            return dequantize(qx, qy, qz), cx + cy + cz
        end,
    }) :: Types.InternalCodec<Vector3>
end

--[[
    Quantized position + smallest-three quaternion rotation. Wire layout:
      byte 0   header bits: bit0=Δx, bit1=Δy, bit2=Δz, bit3=Δrot
      For each set position bit: zigzag varint of quantized diff
      If rotation bit set: 4-byte packed quat

    Static CFrame: 1 byte. Pos-only motion: 1 + 3 zint bytes (~4-7).
    Full update: 1 + 3 zint + 4 quat (~8-13). Baseline lossless: 24 bytes.
]]
function DeltaScalar.deltaCFrame(
    posMin: number,
    posMax: number,
    posPrecision: number
): Types.InternalCodec<CFrame>
    if posMax <= posMin then
        Log.error(`posMin ({posMin}) must be < posMax ({posMax})`)
    end

    local _, _, _, scale, invScale, delta =
        Quantize.setup("Lync.deltaCFrame", posMin, posMax, posPrecision)
    local deltaId = allocDeltaId()

    local function quantize(v: Vector3): (number, number, number)
        return round(clamp(v.X - posMin, 0, delta) * scale),
            round(clamp(v.Y - posMin, 0, delta) * scale),
            round(clamp(v.Z - posMin, 0, delta) * scale)
    end

    return table.freeze({
        _isDelta = true,
        _typeCheck = "CFrame",

        write = function(ch: Types.ChannelState, value: CFrame): ()
            local qx, qy, qz = quantize(value.Position)
            local packed = quatPack(quatFromCFrame(value))

            --[[
                Default prev values to 0 so the first frame encodes ABSOLUTE
                quantized values (since the receiver also defaults to 0 when
                its baseline cache is missing). Setting prev = qx would write
                a zigzag(0) on the first frame and the receiver would
                reconstruct 0 from a 0 prev — corrupting the value.
            ]]
            local cache = ch.deltas[deltaId] :: any
            local flag: number
            local px, py, pz = 0, 0, 0
            if cache then
                px = cache.qx :: number
                py = cache.qy :: number
                pz = cache.qz :: number
                local ppacked = cache.qrot :: number
                flag = 0
                if qx ~= px then
                    flag = bor(flag, CF_X)
                end
                if qy ~= py then
                    flag = bor(flag, CF_Y)
                end
                if qz ~= pz then
                    flag = bor(flag, CF_Z)
                end
                if packed ~= ppacked then
                    flag = bor(flag, CF_ROT)
                end
            else
                -- First frame: emit everything so the receiver has a baseline.
                flag = CF_ALL
            end

            ensure(ch, 1)
            writeu8(ch.buff, ch.cursor, flag)
            ch.cursor += 1

            if band(flag, CF_X) ~= 0 then
                varintWrite(ch, zigzagEncode(qx - px))
            end
            if band(flag, CF_Y) ~= 0 then
                varintWrite(ch, zigzagEncode(qy - py))
            end
            if band(flag, CF_Z) ~= 0 then
                varintWrite(ch, zigzagEncode(qz - pz))
            end
            if band(flag, CF_ROT) ~= 0 then
                ensure(ch, 4)
                writeu32(ch.buff, ch.cursor, packed)
                ch.cursor += 4
            end

            if cache then
                cache.qx, cache.qy, cache.qz, cache.qrot = qx, qy, qz, packed
            else
                ch.deltas[deltaId] = { qx = qx, qy = qy, qz = qz, qrot = packed } :: any
            end
        end,

        read = function(src: buffer, pos: number, _refs: { Instance }?): (CFrame, number)
            if pos >= bufLen(src) then
                Log.error("truncated deltaCFrame header")
            end
            local flag = readu8(src, pos)
            local total = 1

            local cached = Baseline.getCache(deltaId) :: any
            local qx, qy, qz, packed = 0, 0, 0, 0
            if cached then
                qx, qy, qz, packed = cached.qx, cached.qy, cached.qz, cached.qrot
            end

            if band(flag, CF_X) ~= 0 then
                local r, c = varintRead(src, pos + total)
                if c == 0 then
                    Log.error("truncated deltaCFrame X")
                end
                qx += zigzagDecode(r)
                total += c
            end
            if band(flag, CF_Y) ~= 0 then
                local r, c = varintRead(src, pos + total)
                if c == 0 then
                    Log.error("truncated deltaCFrame Y")
                end
                qy += zigzagDecode(r)
                total += c
            end
            if band(flag, CF_Z) ~= 0 then
                local r, c = varintRead(src, pos + total)
                if c == 0 then
                    Log.error("truncated deltaCFrame Z")
                end
                qz += zigzagDecode(r)
                total += c
            end
            if band(flag, CF_ROT) ~= 0 then
                if pos + total + 4 > bufLen(src) then
                    Log.error("truncated deltaCFrame rotation")
                end
                packed = readu32(src, pos + total)
                total += 4
            end

            Baseline.setCache(deltaId, { qx = qx, qy = qy, qz = qz, qrot = packed })

            local position =
                Vector3.new(qx * invScale + posMin, qy * invScale + posMin, qz * invScale + posMin)
            return CFrame.new(position) * quatUnpack(packed), total
        end,
    }) :: Types.InternalCodec<CFrame>
end

return table.freeze(DeltaScalar)
