# Writes modules of N generated upstream encoders (3 fields, per-build offsets folded in) to measure bytecode per definition.
# Usage: python3 -I gen_defs.py OUTDIR
import sys
w = sys.argv[1]
enc = '''M.d{i} = function(b: buffer, bit: number, r: any): number
	buffer.writebits(b, bit, 1, bit32.bxor(TEAM[r.team], {c1}))
	buffer.writebits(b, bit + 1, 8, bit32.band(r.ammo + {c2}, 255))
	local h = r.health + {c3}
	if h >= 101 then h -= 101 end
	buffer.writebits(b, bit + 9, 7, h)
	return bit + 16
end
'''
for n in (1, 50, 200):
    s = 'local TEAM = { red = 0, blue = 1 }\nlocal M = {}\n' + ''.join(enc.format(i=i, c1=i % 2, c2=(i * 37) % 256, c3=(i * 13) % 101) for i in range(n)) + 'return M\n'
    open(f"{w}/defs_{n}.luau", "w").write(s)
