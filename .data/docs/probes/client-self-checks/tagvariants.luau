--!strict
-- U2: cost of per-build tag variants, interpreted. Each variant is straight-line code with its
-- round counts and rotation amounts as literals (gen_tag.py). Also checks that the generated 2-4
-- reference variant matches the published HalfSipHash-2-4 32-bit vector (key 00..07, empty).
-- Run from this directory: luau -O2 tagvariants.luau
local B = require("./bench")

local variants = {
	{ "1-3 reference", require("./tag_13_ref") },
	{ "1-3 altered rotations", require("./tag_13_alt") },
	{ "2-3 reference", require("./tag_23_ref") },
	{ "1-4 reference", require("./tag_14_ref") },
	{ "2-4 reference", require("./tag_24_ref") },
	{ "2-4 altered rotations", require("./tag_24_alt") },
	{ "3-4 reference", require("./tag_34_ref") },
	{ "4-4 reference", require("./tag_44_ref") },
}

local k = buffer.create(8)
for i = 0, 7 do
	buffer.writeu8(k, i, i)
end
local k0, k1 = buffer.readu32(k, 0), buffer.readu32(k, 4)
local got = (variants[5][2] :: any)(k0, k1, buffer.create(0), 0)
print(string.format("2-4 vector: %08x (expected 5b9f35a9 as u32le of a9 35 9f 5b)", got))

local sink = 0
for _, size in { 75, 1035 } do -- 11-byte prefix + 64 B and + 1024 B of frame
	local msg = buffer.create(size)
	for i = 0, size - 1 do
		buffer.writeu8(msg, i, (i * 37) % 256)
	end
	for _, v in variants do
		local f = v[2] :: (number, number, buffer, number) -> number
		B.report(string.format("%s, %d B input", v[1], size), if size < 100 then 50_000 else 5_000, function()
			sink = f(k0, k1, msg, size)
		end)
	end
end
local _ = sink
