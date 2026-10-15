local A = 0x1234
local B = 0x4321
local K = bit32.bxor(A, B) + 7 * 3
return function(x) return bit32.bxor(x, K) end
