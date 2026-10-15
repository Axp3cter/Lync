-- review-3 p3: §3.3 parameters computed in doubles from the text.
-- (a) t.angle(step): n = ceil(2*pi/step). Steps users will write for "1 degree", "N per turn":
for _, c in { { "math.rad(1)", math.rad(1) }, { "2*pi/360", 2 * math.pi / 360 }, { "pi/180", math.pi / 180 },
	{ "2*pi/256", 2 * math.pi / 256 }, { "2*pi/1000", 2 * math.pi / 1000 }, { "math.rad(0.5)", math.rad(0.5) },
	{ "2*pi/100", 2 * math.pi / 100 }, { "2*pi/3600", 2 * math.pi / 3600 } } do
	local r = 2 * math.pi / c[2]
	print(string.format("t.angle(%-13s) 2pi/step = %.17g -> n = %d", c[1], r, math.ceil(r)))
end
-- (b) t.int(min, max) at the documented extremes: width = ceil(log2(max - min + 1))
local min, max = -(2 ^ 52), 2 ^ 52
local span = max - min + 1
local w = 0
while 2 ^ w < span do
	w += 1
end
print(string.format("t.int(-2^52, 2^52): max - min + 1 = %.0f, width %d, largest code v - min = %.0f, fits u(%d): %s",
	span, w, max - min, w, tostring(max - min < 2 ^ w)))
