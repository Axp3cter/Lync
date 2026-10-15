-- Design draft 3: bit order of Luau's buffer.writebits/readbits (decides the wire's bit order, §4.1),
-- and exactness of zigzag at the t.int() cap of 2^52 (decides the cap, §3.3).
local b = buffer.create(4)
buffer.writebits(b, 0, 3, 0b101) -- bits 0..2
buffer.writebits(b, 3, 6, 0b110011) -- bits 3..8, crosses a byte
print("byte0", buffer.readu8(b, 0), "byte1", buffer.readu8(b, 1))
print("readbits(0,3)", buffer.readbits(b, 0, 3), "readbits(3,6)", buffer.readbits(b, 3, 6))
local ok, err = pcall(buffer.writebits, b, 0, 33, 1)
print("33-bit write", ok, err)
local function zigzag(v: number): number
	return if v >= 0 then 2 * v else -2 * v - 1
end
local function unzigzag(z: number): number
	return if z % 2 == 0 then z / 2 else -(z + 1) / 2
end
for _, v in { 2 ^ 52, -(2 ^ 52), 2 ^ 52 - 1, -(2 ^ 52 - 1) } do
	print(string.format("v=%.0f zigzag=%.0f back=%s", v, zigzag(v), tostring(unzigzag(zigzag(v)) == v)))
end
