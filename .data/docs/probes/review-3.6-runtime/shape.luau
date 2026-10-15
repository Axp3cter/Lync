local function countOf(list)
	local maxIndex = 0
	for key, value in list do
		if typeof(key) ~= "number" or typeof(value) ~= "table" then return nil end
		if key < 1 or key % 1 ~= 0 then return nil end
		maxIndex = math.max(maxIndex, key)
	end
	return maxIndex
end
local v = {}
for _, n in { 1000, 10000 } do
	local list = table.create(n, v)
	local reps = 2000000 // n
	countOf(list)
	local t0 = os.clock()
	for _ = 1, reps do countOf(list) end
	print(n, string.format("%.2f ns per entry", (os.clock() - t0) / (reps * n) * 1e9))
end
