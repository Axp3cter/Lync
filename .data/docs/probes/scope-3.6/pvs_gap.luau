-- 2D PVS sampling miss: two 32-stud cells, a wall between them with a 4-stud gap.
-- Sample points: S x S per cell at (i + 0.5) * cell / S. A pair is "visible" if any sample-to-sample ray is unblocked.
local CELL, S = 32, 2
local walls = { { -64, 2, 40, 48 }, { 4, 64, 40, 48 } } -- gap is x in (2, 4)
local function segHitsBox(ax, az, bx, bz, b)
	-- Liang-Barsky clip of segment against box
	local t0, t1 = 0, 1
	local dx, dz = bx - ax, bz - az
	local p = { -dx, dx, -dz, dz }
	local q = { ax - b[1], b[2] - ax, az - b[3], b[4] - az }
	for i = 1, 4 do
		if p[i] == 0 then
			if q[i] < 0 then return false end
		else
			local r = q[i] / p[i]
			if p[i] < 0 then t0 = math.max(t0, r) else t1 = math.min(t1, r) end
			if t0 > t1 then return false end
		end
	end
	return true
end
local function blocked(ax, az, bx, bz)
	for _, b in walls do if segHitsBox(ax, az, bx, bz, b) then return true end end
	return false
end
local function samples(cx, cz)
	local pts = {}
	for i = 0, S - 1 do for j = 0, S - 1 do
		table.insert(pts, { cx + (i + 0.5) * CELL / S, cz + (j + 0.5) * CELL / S })
	end end
	return pts
end
local A, B = samples(0, 0), samples(0, 64)
local open = 0
for _, a in A do for _, b in B do
	if not blocked(a[1], a[2], b[1], b[2]) then open += 1 end
end end
print(("sampled rays %d, unblocked %d -> bake marks pair %s"):format(#A * #B, open, open > 0 and "visible" or "HIDDEN"))
print(("true line of sight (3,4)->(3,90) blocked: %s"):format(tostring(blocked(3, 4, 3, 90))))
