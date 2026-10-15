--!strict
-- P2: decode output construction: table.clone(pre-shaped template) + field writes vs a constructor literal.
local ITER = 1000000
local RUNS = 15
local TEMPLATE = { a = 0, b = 0, c = 0, f = 0, ok = false, name = "" }
local sink: any = nil
local va, vb, vc, vf, vok, vname = 777, 45, -1234, 1.5, true, "player_01"

local function literal()
	for _ = 1, ITER do
		sink = { a = va, b = vb, c = vc, f = vf, ok = vok, name = vname }
	end
end
local function clone()
	for _ = 1, ITER do
		local t = table.clone(TEMPLATE)
		t.a = va
		t.b = vb
		t.c = vc
		t.f = vf
		t.ok = vok
		t.name = vname
		sink = t
	end
end
local function emptyThenAssign() -- baseline: what a generic, data-driven decoder does
	for _ = 1, ITER do
		local t = {}
		t.a = va
		t.b = vb
		t.c = vc
		t.f = vf
		t.ok = vok
		t.name = vname
		sink = t
	end
end
local function emptyThenAssignDynamic() -- generic decoder writing by key variable (v4-style loop)
	local keys = { "a", "b", "c", "f", "ok", "name" }
	local vals = { va, vb, vc, vf, vok, vname }
	for _ = 1, ITER do
		local t = {}
		for i = 1, 6 do
			t[keys[i]] = vals[i]
		end
		sink = t
	end
end
local function cloneDynamic() -- generic decoder that clones a schema-built template, then writes by key
	local keys = { "a", "b", "c", "f", "ok", "name" }
	local vals = { va, vb, vc, vf, vok, vname }
	for _ = 1, ITER do
		local t = table.clone(TEMPLATE)
		for i = 1, 6 do
			t[keys[i]] = vals[i]
		end
		sink = t
	end
end

local variants = {
	{ "literal constructor", literal },
	{ "table.clone + 6 writes", clone },
	{ "{} + 6 constant-key writes", emptyThenAssign },
	{ "{} + 6 dynamic-key writes", emptyThenAssignDynamic },
	{ "table.clone + 6 dynamic writes", cloneDynamic },
}
local function time(fn: () -> ()): number
	local start = os.clock()
	fn()
	return (os.clock() - start) / ITER * 1e9
end
local samples = {}
for i, v in variants do
	time(v[2])
	samples[i] = {}
end
for _ = 1, RUNS do
	for i, v in variants do
		table.insert(samples[i], time(v[2]))
	end
end
local base
for i, v in variants do
	table.sort(samples[i])
	local m = samples[i][(RUNS + 1) // 2]
	base = base or m
	print(string.format("%-32s median %6.1f ns/op  min %6.1f  max %6.1f  x%.2f vs literal", v[1], m, samples[i][1], samples[i][RUNS], m / base))
end
