--!strict
-- Encoder for { id: u16, x: f32, y: f32, z: f32, flags: u8, name: string(<=32) }
local N = 500_000
local b = buffer.create(65536)

local function encShared(b: buffer, o: number, id: number, x: number, y: number, z: number, flags: number, name: string): number
	buffer.writeu16(b, o, id)
	buffer.writef32(b, o + 2, x); buffer.writef32(b, o + 6, y); buffer.writef32(b, o + 10, z)
	buffer.writeu8(b, o + 14, flags)
	local n = #name
	buffer.writeu8(b, o + 15, n)
	buffer.writestring(b, o + 16, name)
	return o + 16 + n
end
local Lync = { enc = encShared }

local function time(label, f)
	local best = math.huge
	for r = 1, 7 do local t = os.clock(); f(); best = math.min(best, os.clock() - t) end
	print(string.format("%-34s %7.1f ns/op", label, best / N * 1e9))
end

time("shared via module table", function()
	local o = 0
	for i = 1, N do o = Lync.enc(b, 0, 7, 1.5, 2.5, 3.5, 3, "hello") end
end)
time("shared local upvalue", function()
	local o = 0
	for i = 1, N do o = encShared(b, 0, 7, 1.5, 2.5, 3.5, 3, "hello") end
end)
time("inlined at call site", function()
	local o = 0
	for i = 1, N do
		local name = "hello"
		buffer.writeu16(b, 0, 7)
		buffer.writef32(b, 2, 1.5); buffer.writef32(b, 6, 2.5); buffer.writef32(b, 10, 3.5)
		buffer.writeu8(b, 14, 3)
		local n = #name
		buffer.writeu8(b, 15, n)
		buffer.writestring(b, 16, name)
		o = 16 + n
	end
end)
-- permuted field order + xor-masked id (polymorphic variant): same op count
time("inlined, permuted + id mask", function()
	local o = 0
	for i = 1, N do
		local name = "hello"
		buffer.writeu8(b, 0, 3)
		buffer.writef32(b, 1, 3.5); buffer.writeu16(b, 5, bit32.bxor(7, 0xA5C3)); buffer.writef32(b, 7, 1.5)
		local n = #name
		buffer.writeu8(b, 11, n)
		buffer.writef32(b, 12, 2.5)
		buffer.writestring(b, 16, name)
		o = 16 + n
	end
end)
-- id via runtime lookup table (per-session permutation)
local perm = table.create(256, 0); for i = 1, 256 do perm[i] = (i * 167) % 256 end
time("shared + id perm lookup", function()
	local o = 0
	for i = 1, N do o = encShared(b, 0, perm[8], 1.5, 2.5, 3.5, 3, "hello") end
end)
-- woven canary: identity check of the encoder against a captured reference
local ref = Lync.enc
local tripped = 0
time("shared + identity canary", function()
	local o = 0
	for i = 1, N do
		if Lync.enc ~= ref then tripped += 1 end
		o = Lync.enc(b, 0, 7, 1.5, 2.5, 3.5, 3, "hello")
	end
end)
-- debug.info canary (source check), the kind of thing woven into other scripts
time("debug.info(f,'s') canary alone", function()
	local s
	for i = 1, N do s = debug.info(encShared, "s") end
end)
-- toy VM: same encoder expressed as interpreted ops (what VM obfuscators do)
local OPS = { 1,0, 2,2, 2,6, 2,10, 3,14, 4,15 }
local function vmEnc(b: buffer, args: {any})
	local pc, ai, o = 1, 1, 0
	local ops = OPS
	while pc <= #ops do
		local op, off = ops[pc], ops[pc + 1]
		if op == 1 then buffer.writeu16(b, off, args[ai])
		elseif op == 2 then buffer.writef32(b, off, args[ai])
		elseif op == 3 then buffer.writeu8(b, off, args[ai])
		else local s = args[ai]; buffer.writeu8(b, off, #s); buffer.writestring(b, off + 1, s); o = off + 1 + #s end
		ai += 1; pc += 2
	end
	return o
end
time("toy VM interpreter (6 ops)", function()
	local args = { 7, 1.5, 2.5, 3.5, 3, "hello" }
	for i = 1, N do vmEnc(b, args) end
end)
