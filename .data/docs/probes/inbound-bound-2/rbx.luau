--!nocheck
-- Stand-ins for the Roblox datatypes the codecs touch, for the Luau CLI (no Roblox host). run.sh prepends
-- `local __R = require("../../rbx_<mode>")` to src/codec/{leaves,rows,columns}.luau and src/plan/dsl.luau of each
-- scratch copy, so the modules see these as locals (the CLI gives each required module its own global table, so a
-- global set by the probe would not reach them).
--
-- Two modes, one math:
--   "build"  (build_frames.luau, the frame builder): CFrame, Color3, Enum, EnumItem and Instance are tables whose
--            metatable carries __lynctype, and `typeof` is replaced in those modules so the encoder's
--            `typeof(value) ~= "CFrame"` checks pass; Vector3 values are native vectors, typed "Vector3".
--   "fast"   (every timing probe): run.sh rewrites `Vector3.new(` to `vector.create(` (a builtin fast call, as
--            Roblox's Vector3 constructor is); CFrame and Color3 are plain tables (Roblox allocates a userdata for
--            each); `typeof` is replaced only in dsl.luau, which checks `typeof(items) == "Enum"` at plan time.
-- The CFrame math is the same in both modes (f64, quaternions normalised as Roblox does), so the encoder's canonical
-- rotation codes (v5.md §3.3) are canonical for the decoder too. Its cost is not Roblox's (C++), see RESULTS.md.

local made = {}

local realTypeof = typeof

local function shimTypeof(v)
	local t = realTypeof(v)
	if t == "vector" then
		return "Vector3"
	end
	if t == "table" then
		local mt = getmetatable(v)
		if type(mt) == "table" then
			local k = rawget(mt, "__lynctype")
			if k ~= nil then
				return k
			end
		end
	end
	return t
end

local function make(mode: string)
	if made[mode] then
		return made[mode]
	end

	local CF = {}
	local methods = {}
	local cfMeta
	if mode == "build" then
		cfMeta = { __lynctype = "CFrame" }
	else
		cfMeta = { __index = methods }
	end

	local function fromMatrix(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
		return setmetatable({ X = x, Y = y, Z = z, r00, r01, r02, r10, r11, r12, r20, r21, r22 }, cfMeta)
	end

	function CF.new(x, y, z, a, b, c, d, e, f, g, h, i)
		x, y, z = x or 0, y or 0, z or 0
		if a == nil then
			return fromMatrix(x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
		end
		if e == nil then
			-- quaternion qx, qy, qz, qw
			local qx, qy, qz, qw = a, b, c, d
			local n = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
			qx, qy, qz, qw = qx / n, qy / n, qz / n, qw / n
			return fromMatrix(
				x, y, z,
				1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw),
				2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw),
				2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy)
			)
		end
		return fromMatrix(x, y, z, a, b, c, d, e, f, g, h, i)
	end

	function methods.GetComponents(cf)
		return cf.X, cf.Y, cf.Z, cf[1], cf[2], cf[3], cf[4], cf[5], cf[6], cf[7], cf[8], cf[9]
	end

	cfMeta.__add = function(cf, v)
		return fromMatrix(cf.X + v.X, cf.Y + v.Y, cf.Z + v.Z, cf[1], cf[2], cf[3], cf[4], cf[5], cf[6], cf[7], cf[8], cf[9])
	end

	if mode == "build" then
		cfMeta.__index = function(cf, k)
			if k == "GetComponents" then
				return methods.GetComponents
			elseif k == "Position" then
				return vector.create(cf.X, cf.Y, cf.Z)
			elseif k == "Rotation" then
				return fromMatrix(0, 0, 0, cf[1], cf[2], cf[3], cf[4], cf[5], cf[6], cf[7], cf[8], cf[9])
			end
			return nil
		end
	end

	local C3 = {}
	local c3Meta = if mode == "build" then { __lynctype = "Color3" } else nil
	function C3.new(r, g, b)
		local c = { R = r, G = g, B = b }
		if c3Meta then
			setmetatable(c, c3Meta)
		end
		return c
	end

	-- One Roblox enum of 16 items, values 0, 3, 6, ... (gaps, as real enums have).
	local enumMeta = { __lynctype = "Enum", __tostring = function() return "Enum.ShimKind" end }
	local itemMeta = { __lynctype = "EnumItem" }
	local items = {}
	local enum = setmetatable({}, enumMeta)
	for i = 1, 16 do
		items[i] = setmetatable({ Name = "Item" .. i, Value = (i - 1) * 3, EnumType = enum }, itemMeta)
	end
	enumMeta.__index = { GetEnumItems = function() return table.clone(items) end }

	local instanceMeta = {
		__lynctype = "Instance",
		__index = {
			ClassName = "Part",
			IsA = function(_, class)
				return class == "Part" or class == "BasePart" or class == "PVInstance" or class == "Instance"
			end,
		},
	}
	local function newInstance()
		return setmetatable({}, instanceMeta)
	end

	local R = {
		CFrame = CF,
		Color3 = C3,
		Vector3 = { new = vector.create },
		ShimEnum = enum,
		ShimEnumItems = items,
		newInstance = newInstance,
		typeof = shimTypeof,
	}
	made[mode] = R
	return R
end

return make
