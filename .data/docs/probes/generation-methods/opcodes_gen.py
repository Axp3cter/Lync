# Writes two pairs of generated Luau functions that differ only by build seed, so their opcode streams can be compared:
#  rec_s0 / rec_s7: an 8-field record encoder+decoder in name order and in a rotated order (M1);
#  tag_c0 / tag_c1: HalfSipHash-1-3 (32-bit output) with the reference init constants and with replaced ones (M2).
# Usage: python3 -I opcodes_gen.py OUTDIR
import sys
w = sys.argv[1]
F = [("a", 8), ("b", 7), ("c", 1), ("d", 12), ("e", 3), ("f", 16), ("g", 5), ("h", 2)]
def rec(order):
    enc, dec, off = [], [], 0
    for name, width in order:
        enc.append(f"\tbuffer.writebits(b, bit + {off}, {width}, r.{name})")
        dec.append(f"{name} = buffer.readbits(b, bit + {off}, {width})")
        off += width
    return ("local M = {}\nfunction M.enc(b: buffer, bit: number, r: any): number\n" + "\n".join(enc) +
            f"\n\treturn bit + {off}\nend\nfunction M.dec(b: buffer, bit: number): any\n\treturn {{ " + ", ".join(dec) + " }\nend\nreturn M\n")
open(f"{w}/rec_s0.luau", "w").write(rec(F))
open(f"{w}/rec_s7.luau", "w").write(rec([F[i] for i in (2, 5, 0, 7, 3, 1, 6, 4)]))
TAG = '''local band, bor, bxor, lshift, rshift = bit32.band, bit32.bor, bit32.bxor, bit32.lshift, bit32.rshift
local function rotl(x: number, n: number): number return bor(lshift(x, n), rshift(x, 32 - n)) end
local M = {}
-- HalfSipHash-1-3 over whole 4-byte words of b[0, len), len a multiple of 4 (enough for the opcode comparison)
function M.tag(b: buffer, len: number, k0: number, k1: number): number
	local v0, v1, v2, v3 = k0, k1, bxor(k0, C2), bxor(k1, C3)
	for i = 0, len - 4, 4 do
		local m = buffer.readu32(b, i)
		v3 = bxor(v3, m)
		v0 = band(v0 + v1, 0xFFFFFFFF); v1 = rotl(v1, 5); v1 = bxor(v1, v0); v0 = rotl(v0, 16)
		v2 = band(v2 + v3, 0xFFFFFFFF); v3 = rotl(v3, 8); v3 = bxor(v3, v2)
		v0 = band(v0 + v3, 0xFFFFFFFF); v3 = rotl(v3, 7); v3 = bxor(v3, v0)
		v2 = band(v2 + v1, 0xFFFFFFFF); v1 = rotl(v1, 13); v1 = bxor(v1, v2); v2 = rotl(v2, 16)
		v0 = bxor(v0, m)
	end
	v2 = bxor(v2, 0xFF)
	for _ = 1, 3 do
		v0 = band(v0 + v1, 0xFFFFFFFF); v1 = rotl(v1, 5); v1 = bxor(v1, v0); v0 = rotl(v0, 16)
		v2 = band(v2 + v3, 0xFFFFFFFF); v3 = rotl(v3, 8); v3 = bxor(v3, v2)
		v0 = band(v0 + v3, 0xFFFFFFFF); v3 = rotl(v3, 7); v3 = bxor(v3, v0)
		v2 = band(v2 + v1, 0xFFFFFFFF); v1 = rotl(v1, 13); v1 = bxor(v1, v2); v2 = rotl(v2, 16)
	end
	return bxor(v1, v3)
end
return M
'''
open(f"{w}/tag_c0.luau", "w").write(TAG.replace("C2", "0x6c796765").replace("C3", "0x74656462"))
open(f"{w}/tag_c1.luau", "w").write(TAG.replace("C2", "0x9f3a21c4").replace("C3", "0x0b77e1d3"))
