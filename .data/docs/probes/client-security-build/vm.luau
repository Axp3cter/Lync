local N = 300_000
local b = buffer.create(256)
local function direct(b, o, id, x, y, z, flags, name)
	buffer.writeu16(b, o, id)
	buffer.writef32(b, o + 2, x); buffer.writef32(b, o + 6, y); buffer.writef32(b, o + 10, z)
	buffer.writeu8(b, o + 14, flags)
	local n = #name
	buffer.writeu8(b, o + 15, n)
	buffer.writestring(b, o + 16, name)
	return o + 16 + n
end
-- register VM in the style of IronBrew/Prometheus output: one table-driven dispatch per Luau-level op
-- opcodes: 1 ADDK r[a]=r[b]+K c ; 2 CALL4 f[a](r[b],r[c],r[d]) ; 3 LEN r[a]=#r[b] ; 4 ADD r[a]=r[b]+r[c] ; 5 RET r[a]
local F = { buffer.writeu16, buffer.writef32, buffer.writeu8, buffer.writestring }
local code = {
	{2,1,1,2,3},          -- writeu16(b,o,id)
	{1,9,2,2},{2,2,1,9,4},
	{1,9,2,6},{2,2,1,9,5},
	{1,9,2,10},{2,2,1,9,6},
	{1,9,2,14},{2,3,1,9,7},
	{3,10,8},
	{1,9,2,15},{2,3,1,9,10},
	{1,9,2,16},{2,4,1,9,8},
	{1,11,2,16},{4,11,11,10},
	{5,11},
}
local function vm(...)
	local r = { ... }
	local pc = 1
	while true do
		local ins = code[pc]; pc += 1
		local op = ins[1]
		if op == 1 then r[ins[2]] = r[ins[3]] + ins[4]
		elseif op == 2 then F[ins[2]](r[ins[3]], r[ins[4]], r[ins[5]])
		elseif op == 3 then r[ins[2]] = #r[ins[3]]
		elseif op == 4 then r[ins[2]] = r[ins[3]] + r[ins[4]]
		else return r[ins[2]] end
	end
end
assert(vm(b,0,7,1.5,2.5,3.5,3,"hello") == direct(b,0,7,1.5,2.5,3.5,3,"hello"))
local function time(label, f)
	local best = math.huge
	for _ = 1, 7 do local t = os.clock(); f(); best = math.min(best, os.clock() - t) end
	print(string.format("%-24s %7.1f ns/op", label, best / N * 1e9)); return best
end
local a = time("direct", function() for i = 1, N do direct(b,0,7,1.5,2.5,3.5,3,"hello") end end)
local c = time("register VM", function() for i = 1, N do vm(b,0,7,1.5,2.5,3.5,3,"hello") end end)
print(string.format("ratio %.1fx", c / a))
