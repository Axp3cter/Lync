-- os.clock step: how many of 1,000,000 consecutive reads repeat the previous value, and the smallest
-- nonzero difference. Run: luau -O2 clockstep.luau
local zero, least = 0, math.huge
local last = os.clock()
for _ = 1, 1_000_000 do
	local now = os.clock()
	local d = now - last
	if d == 0 then
		zero += 1
	elseif d < least then
		least = d
	end
	last = now
end
print(string.format("repeats %d of 1000000; smallest nonzero step %.1f ns", zero, least * 1e9))
