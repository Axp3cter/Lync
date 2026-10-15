# Bytecode per generated definition for the 3-field record of shapes.luau: encoder and decoder, plain and with
# per-build offsets, at 50 and 200 definitions. The marginal size per definition is (B200 - B50) / 150.
# Usage: python3 -I gen_defs2.py OUTDIR
import sys
w = sys.argv[1]
forms = {
 "enc_plain": '''M.e{i} = function(b: buffer, bit: number, r: any): number
	buffer.writebits(b, bit, 1, TEAM[r.team])
	buffer.writebits(b, bit + 1, 8, r.ammo)
	buffer.writebits(b, bit + 9, 7, r.health)
	return bit + 16
end
''',
 "enc_offset": '''M.e{i} = function(b: buffer, bit: number, r: any): number
	buffer.writebits(b, bit, 1, bit32.bxor(TEAM[r.team], {c1}))
	buffer.writebits(b, bit + 1, 8, bit32.band(r.ammo + {c2}, 255))
	local h = r.health + {c3}
	if h >= 101 then h -= 101 end
	buffer.writebits(b, bit + 9, 7, h)
	return bit + 16
end
''',
 "dec_plain": '''M.d{i} = function(b: buffer, bit: number): any
	return {{ team = NAME[buffer.readbits(b, bit, 1) + 1], ammo = buffer.readbits(b, bit + 1, 8), health = buffer.readbits(b, bit + 9, 7) }}
end
''',
 "dec_offset": '''M.d{i} = function(b: buffer, bit: number): any
	local h = buffer.readbits(b, bit + 9, 7) - {c3}
	if h < 0 then h += 101 end
	return {{ team = NAME[bit32.bxor(buffer.readbits(b, bit, 1), {c1}) + 1], ammo = bit32.band(buffer.readbits(b, bit + 1, 8) - {c2}, 255), health = h }}
end
''',
}
for name, body in forms.items():
    for n in (50, 200):
        s = 'local TEAM = { red = 0, blue = 1 }\nlocal NAME = { "red", "blue" }\nlocal M = {}\n' + ''.join(
            body.format(i=i, c1=i % 2, c2=(i * 37) % 256, c3=(i * 13) % 101) for i in range(n)) + 'return M\n'
        open(f"{w}/{name}_{n}.luau", "w").write(s)
