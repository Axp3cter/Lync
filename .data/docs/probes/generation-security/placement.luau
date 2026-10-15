-- Where a per-build value ends up in bytecode, by how generated code writes it.
-- Compile with: luau-compile --text -O2 --dump-constants placement.luau
local M = {}

-- (a) inlined literal, small: expected as an instruction immediate
function M.small(b: buffer)
	buffer.writeu16(b, 0, 1234)
end

-- (b) inlined literal, large: expected in the constant table
function M.large(b: buffer, x: number): number
	return bit32.bxor(x, 0x6c796765)
end

-- (c) folded expression of literals: does -O2 fold it to one constant?
function M.folded(b: buffer, x: number): number
	return bit32.bxor(x, bit32.bxor(0x6c796765, 0x12345678))
end

-- (d) computed at load from a seed table, captured as an upvalue
local seed = { 0x12345678, 0x0badf00d }
local k = bit32.bxor(seed[1], seed[2])
function M.upvalue(b: buffer, x: number): number
	return bit32.bxor(x, k)
end

return M
