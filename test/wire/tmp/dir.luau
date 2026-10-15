local roblox = require("@lune/roblox")
local V3 = roblox.Vector3
local Quant = require("../../../src/wire/quant")
local F = buffer.create(4)
local function f32(x)
	buffer.writef32(F, 0, x)
	return buffer.readf32(F, 0)
end
local function Epure(qx, qy, bits)
	local x, y, z = Quant.undirection(qx, qy, bits)
	return Quant.direction(f32(x), f32(y), f32(z), bits)
end
local function Evec(qx, qy, bits)
	local v = V3.new(Quant.undirection(qx, qy, bits))
	return Quant.direction(v.X, v.Y, v.Z, bits)
end
local function Edouble(qx, qy, bits)
	local x, y, z = Quant.undirection(qx, qy, bits)
	return Quant.direction(x, y, z, bits)
end
-- exhaustive 8 bits
for _, bits in { 8 } do
	local m = 2 ^ bits - 1
	local nonFixed, mismatch, mismatchDouble, steps, cycles, maxSteps = 0, 0, 0, {}, 0, 0
	for qx = 0, m do
		for qy = 0, m do
			local ex, ey = Epure(qx, qy, bits)
			local vx, vy = Evec(qx, qy, bits)
			if ex ~= vx or ey ~= vy then
				mismatch += 1
			end
			local dx, dy = Edouble(qx, qy, bits)
			if dx ~= ex or dy ~= ey then
				mismatchDouble += 1
			end
			if ex ~= qx or ey ~= qy then
				nonFixed += 1
			end
			-- iterate
			local cx, cy, px, py, n = qx, qy, -1, -1, 0
			while true do
				local nx, ny = Epure(cx, cy, bits)
				n += 1
				if nx == cx and ny == cy then
					break
				end
				if nx == px and ny == py then
					cycles += 1
					break
				end
				px, py, cx, cy = cx, cy, nx, ny
				if n > 10 then
					error("long orbit")
				end
			end
			maxSteps = math.max(maxSteps, n)
		end
	end
	print(
		"bits",
		bits,
		"non-fixed",
		nonFixed,
		"pure~=Vector3",
		mismatch,
		"pure~=double",
		mismatchDouble,
		"2-cycles",
		cycles,
		"max E calls",
		maxSteps
	)
end
-- random directions
for _, bits in { 8, 10, 12, 16 } do
	local m = 2 ^ bits - 1
	local firstNonCanon, mismatch, cycles, maxSteps, stepHist = 0, 0, 0, 0, {}
	local N = 1_000_000
	for i = 1, N do
		local z = 2 * math.random() - 1
		local a = 2 * math.pi * math.random()
		local r = math.sqrt(1 - z * z)
		local v = V3.new(r * math.cos(a), r * math.sin(a), z)
		local cx, cy = Quant.direction(v.X, v.Y, v.Z, bits)
		local px, py, n = -1, -1, 0
		while true do
			local nx, ny = Epure(cx, cy, bits)
			local vx, vy = Evec(cx, cy, bits)
			if nx ~= vx or ny ~= vy then
				mismatch += 1
			end
			n += 1
			if nx == cx and ny == cy then
				break
			end
			if nx == px and ny == py then
				cycles += 1
				break
			end
			px, py, cx, cy = cx, cy, nx, ny
			if n > 10 then
				error("long orbit")
			end
		end
		if n > 1 then
			firstNonCanon += 1
		end
		stepHist[n] = (stepHist[n] or 0) + 1
		maxSteps = math.max(maxSteps, n)
	end
	local h = {}
	for k, c in stepHist do
		table.insert(h, k .. ":" .. c)
	end
	print(
		"bits",
		bits,
		"first code not canonical",
		firstNonCanon,
		"of",
		N,
		"pure~=Vector3",
		mismatch,
		"2-cycles",
		cycles,
		"E calls hist",
		table.concat(h, " ")
	)
end
