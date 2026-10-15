--!native
--!optimize 2
local N, ITER = 1000, 4000
local b = buffer.create(16384)
for i = 0, 16383 do buffer.writeu8(b, i, math.random(0,255)) end
local TB = 11
local symT = buffer.create(2^TB) ; local lenT = buffer.create(2^TB)
for i = 0, 2^TB - 1 do buffer.writeu8(symT, i, i % 256); buffer.writeu8(lenT, i, 1 + (i % 11)) end
local function run()
	-- manual 32-bit window reader: refill bytewise
	local acc, nb, o, s = 0, 0, 0, 0
	for i = 1, N do
		while nb <= 24 do acc = acc + bit32.lshift(buffer.readu8(b, o), nb); o += 1; nb += 8 end
		local peek = bit32.band(acc, 2047)
		s += buffer.readu8(symT, peek)
		local l = buffer.readu8(lenT, peek)
		acc = bit32.rshift(acc, l); nb -= l
	end
	return s
end
run()
local t = os.clock()
for _ = 1, ITER do run() end
local dt = os.clock() - t
print(string.format("Huffman decode manual reader: %.1f ns/sym", dt/ITER/N*1e9))
