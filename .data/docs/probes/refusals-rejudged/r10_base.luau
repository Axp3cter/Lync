--!optimize 2
-- R10 sample: a generated-style encoder module. r10_names.sh derives renamed copies of it.
local writeu8, writeu16 = buffer.writeu8, buffer.writeu16
local Codec = {}

local function encodeHit(target, damage, out)
	local offset = 0
	writeu16(out, offset, target)
	offset += 2
	writeu8(out, offset, damage)
	return offset + 1
end

local packShot = function(origin, spread, out)
	local cursor = 0
	writeu8(out, cursor, spread)
	return cursor + 1
end

function Codec.hit(target, damage, out)
	return encodeHit(target, damage, out)
end

Codec.shot = packShot

print(debug.info(encodeHit, "n"), debug.info(packShot, "n"), debug.info(Codec.hit, "n"))
return Codec
