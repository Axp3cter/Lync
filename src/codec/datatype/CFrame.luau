--!strict
--!native
-- CFrame codec. Default lossless (24B); __call yields smallest-three quat (16B).

local Base = require(script.Parent.Parent.Base)
local Quat = require(script.Parent.Parent.Parent.util.Quat)
local Types = require(script.Parent.Parent.Parent.Types)

-- Constants --------------------------------------------------------------

local EPSILON = 2.4e-7
local EPSILON_SQ = EPSILON * EPSILON

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local writef32 = buffer.writef32
local readf32 = buffer.readf32
local writeu32 = buffer.writeu32
local readu32 = buffer.readu32
local sqrt = math.sqrt
local quatPack = Quat.pack
local quatUnpack = Quat.unpack
local quatFromCFrame = Quat.fromCFrame

local function writeLossless(b: buffer, off: number, value: CFrame): ()
    local pos = value.Position
    writef32(b, off, pos.X)
    writef32(b, off + 4, pos.Y)
    writef32(b, off + 8, pos.Z)

    local axis, angle = value:ToAxisAngle()
    if angle < EPSILON then
        writef32(b, off + 12, 0)
        writef32(b, off + 16, 0)
        writef32(b, off + 20, 0)
        return
    end
    writef32(b, off + 12, axis.X * angle)
    writef32(b, off + 16, axis.Y * angle)
    writef32(b, off + 20, axis.Z * angle)
end

local function readLossless(b: buffer, off: number): CFrame
    local px = readf32(b, off)
    local py = readf32(b, off + 4)
    local pz = readf32(b, off + 8)
    local rx = readf32(b, off + 12)
    local ry = readf32(b, off + 16)
    local rz = readf32(b, off + 20)

    local sqLen = rx * rx + ry * ry + rz * rz
    if sqLen < EPSILON_SQ then
        return CFrame.new(px, py, pz)
    end

    local angle = sqrt(sqLen)
    local inv = 1 / angle
    return CFrame.new(px, py, pz)
        * CFrame.fromAxisAngle(Vector3.new(rx * inv, ry * inv, rz * inv), angle)
end

--[[
    Compressed wire (16B):
      [0..11]  position 3x f32
      [12..15] packed [largest:2][a:10][b:10][c:10] (smallest-three quat)
]]
local function writeCompressed(b: buffer, off: number, value: CFrame): ()
    local pos = value.Position
    writef32(b, off, pos.X)
    writef32(b, off + 4, pos.Y)
    writef32(b, off + 8, pos.Z)
    writeu32(b, off + 12, quatPack(quatFromCFrame(value)))
end

local function readCompressed(b: buffer, off: number): CFrame
    local px = readf32(b, off)
    local py = readf32(b, off + 4)
    local pz = readf32(b, off + 8)
    return CFrame.new(px, py, pz) * quatUnpack(readu32(b, off + 12))
end

local function compressedFactory(_self): Types.InternalCodec<CFrame>
    return Base.define(16, writeCompressed, readCompressed, { _typeCheck = "CFrame" })
end

-- Public -----------------------------------------------------------------

local CFrameCodec = {}

CFrameCodec.cframe = table.freeze(setmetatable({
    _size = 24,
    _directWrite = writeLossless,
    _directRead = readLossless,
    _typeCheck = "CFrame",
    write = function(ch: Types.ChannelState, value: CFrame): ()
        local cursor = ch.cursor
        if cursor + 24 > ch.size then
            alloc(ch, 24)
        end
        writeLossless(ch.buff, cursor, value)
        ch.cursor = cursor + 24
    end,
    read = function(src: buffer, pos: number, _refs: { Instance }?): (CFrame, number)
        return readLossless(src, pos), 24
    end,
}, table.freeze({ __call = compressedFactory })))

return table.freeze(CFrameCodec)
