--!strict
-- §4.3's column decode, verbatim: "if r > top − previous the code is previous + (r − n), if r < lo − previous it
-- is previous + (r + n), else previous + r", codes on [lo, top] = [0, n − 1]. Lists every residual r (from its
-- zigzag z) that decodes to an in-interval code, per (n, previous, code): more than one r per code is a second
-- accepted encoding that §4.8 neither refuses nor lists as a free choice.
local function unzig(z: number) return if z % 2 == 0 then z / 2 else -(z + 1) / 2 end
local function decode(prev: number, r: number, n: number): number
	local lo, top = 0, n - 1
	if r > top - prev then return prev + (r - n) elseif r < lo - prev then return prev + (r + n) else return prev + r end
end
for _, n in { 2, 4, 101 } do
	local prev = 0
	local seen: { [number]: { number } } = {}
	for z = 0, 4 * n do
		local c = decode(prev, unzig(z), n)
		if c >= 0 and c <= n - 1 then seen[c] = seen[c] or {}; table.insert(seen[c], z) end
	end
	local multi, example = 0, ""
	for c = 0, n - 1 do
		if seen[c] and #seen[c] > 1 then
			multi += 1
			if example == "" then example = string.format("code %d from zigzags %s", c, table.concat(seen[c], ", ")) end
		end
	end
	print(string.format("n %d, previous 0: %d of %d codes have more than one accepted residual (%s)", n, multi, n, example))
end
