# M14 probe helper: writes a copy of f1fbfd7:src/codec/rows.luau whose int, bool and enum branches apply a
# per-codec code offset read from the IR (codec.offset, codec.n), as a table-driven runtime path would.
# Identity IR (no offset field) takes one extra nil test per bounded value.
# Usage: python3 -I patch_rows.py SRC_ROWS OUT_ROWS
import sys

src, out = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()

def sub(old, new):
    global text
    n = text.count(old)
    if n != 1:
        sys.exit(f"patch_rows: expected one match, found {n}: {old[:60]!r}")
    text = text.replace(old, new)

# write: int
sub("""		local code = Leaves.intCode(value, codec.min, codec.max)
		if code == nil then
			return Leaves.refusal(codec, value)
		end
		Bits.write(w, codec.width, code)
	elseif codec.kind == "bool" then
		if value == true then
			Bits.write(w, 1, 1)
		elseif value == false then
			Bits.write(w, 1, 0)
		else""",
"""		local code = Leaves.intCode(value, codec.min, codec.max)
		if code == nil then
			return Leaves.refusal(codec, value)
		end
		local offset = codec.offset
		if offset ~= nil then
			local n = codec.n
			code = if code >= n - offset then code - (n - offset) else code + offset
		end
		Bits.write(w, codec.width, code)
	elseif codec.kind == "bool" then
		local flip = codec.offset or 0
		if value == true then
			Bits.write(w, 1, bit32.bxor(1, flip))
		elseif value == false then
			Bits.write(w, 1, flip)
		else""")

# write: enum
sub("""		local code = codec.index[value]
		if code == nil then
			return Leaves.refusal(codec, value)
		end
		Bits.write(w, codec.width, code)
	elseif codec.kind == "optional" then""",
"""		local code = codec.index[value]
		if code == nil then
			return Leaves.refusal(codec, value)
		end
		local offset = codec.offset
		if offset ~= nil then
			local n = codec.n
			code = if code >= n - offset then code - (n - offset) else code + offset
		end
		Bits.write(w, codec.width, code)
	elseif codec.kind == "optional" then""")

# read: int
sub("""		local value = code + codec.min
		if value > codec.max then
			return nil, 3
		end
		return value, 0
	elseif codec.kind == "bool" then
		local code = Bits.read(r, 1)
		if code == nil then
			return nil, 4
		end
		return code == 1, 0""",
"""		local offset = codec.offset
		if offset ~= nil then
			local n = codec.n
			if code >= n then
				return nil, 3
			end
			code = if code < offset then code + (n - offset) else code - offset
		end
		local value = code + codec.min
		if value > codec.max then
			return nil, 3
		end
		return value, 0
	elseif codec.kind == "bool" then
		local code = Bits.read(r, 1)
		if code == nil then
			return nil, 4
		end
		return code ~= (codec.offset or 0), 0""")

# read: enum
sub("""		local item = codec.items[code + 1]
		if item == nil then
			return nil, 2
		end
		return item, 0""",
"""		local offset = codec.offset
		if offset ~= nil then
			local n = codec.n
			if code >= n then
				return nil, 2
			end
			code = if code < offset then code + (n - offset) else code - offset
		end
		local item = codec.items[code + 1]
		if item == nil then
			return nil, 2
		end
		return item, 0""")

open(out, "w", encoding="utf-8").write(text)
