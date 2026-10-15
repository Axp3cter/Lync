--!strict
--!optimize 2
-- Generated-codec shapes for one record { ammo = t.int(0, 255), health = t.int(0, 100), team = t.enum({"red","blue"}) },
-- as the build would emit them under different generation methods. Measures ns per encode+decode.
-- Run: luau -O2 shapes.luau   and   luau -O2 --codegen shapes.luau

type R = { ammo: number, health: number, team: string }
local TEAM = { red = 0, blue = 1 }
local TEAM_NAME = { "red", "blue" }

-- seed 0: canonical field order (ammo, health, team), codes v - min
local function enc0(b: buffer, bit: number, r: R): number
	buffer.writebits(b, bit, 8, r.ammo)
	buffer.writebits(b, bit + 8, 7, r.health)
	buffer.writebits(b, bit + 15, 1, TEAM[r.team])
	return bit + 16
end
local function dec0(b: buffer, bit: number): R
	return { ammo = buffer.readbits(b, bit, 8), health = buffer.readbits(b, bit + 8, 7), team = TEAM_NAME[buffer.readbits(b, bit + 15, 1) + 1] }
end

-- seed 7: rotated field order (team, ammo, health): same opcodes, different order
local function enc7(b: buffer, bit: number, r: R): number
	buffer.writebits(b, bit, 1, TEAM[r.team])
	buffer.writebits(b, bit + 1, 8, r.ammo)
	buffer.writebits(b, bit + 9, 7, r.health)
	return bit + 16
end
local function dec7(b: buffer, bit: number): R
	return { team = TEAM_NAME[buffer.readbits(b, bit, 1) + 1], ammo = buffer.readbits(b, bit + 1, 8), health = buffer.readbits(b, bit + 9, 7) }
end

-- seed 7 + per-build code offsets: wire code = (v - min + c) mod n, c folded in as constants
-- ammo n=256 c=173; health n=101 c=58; team n=2 c=1
local function enc7o(b: buffer, bit: number, r: R): number
	buffer.writebits(b, bit, 1, bit32.bxor(TEAM[r.team], 1))
	buffer.writebits(b, bit + 1, 8, bit32.band(r.ammo + 173, 255))
	local h = r.health + 58
	if h >= 101 then h -= 101 end
	buffer.writebits(b, bit + 9, 7, h)
	return bit + 16
end
local function dec7o(b: buffer, bit: number): R
	local h = buffer.readbits(b, bit + 9, 7) - 58
	if h < 0 then h += 101 end
	return { team = TEAM_NAME[bit32.bxor(buffer.readbits(b, bit, 1), 1) + 1], ammo = bit32.band(buffer.readbits(b, bit + 1, 8) - 173, 255), health = h }
end

-- per-session variant selection: the shard carries 4 straight-line variants, WELCOME picks one index
local ENC = { enc0, enc7, enc7o, enc0 }
local DEC = { dec0, dec7, dec7o, dec0 }
local sessionIndex = 3
local encSel, decSel = ENC[sessionIndex], DEC[sessionIndex] -- resolved once per session

local N = 2_000_000
local b = buffer.create(8)
local rec: R = { ammo = 200, health = 77, team = "blue" }

local function bench(name: string, enc: (buffer, number, R) -> number, dec: (buffer, number) -> R)
	local best = math.huge
	for _ = 1, 7 do
		local t0 = os.clock()
		for _ = 1, N do
			enc(b, 0, rec)
			dec(b, 0)
		end
		best = math.min(best, os.clock() - t0)
	end
	local back = (function() enc(b, 0, rec); return dec(b, 0) end)()
	assert(back.ammo == 200 and back.health == 77 and back.team == "blue", name)
	print(string.format("%-28s %6.1f ns per encode+decode", name, best / N * 1e9))
end

bench("seed 0", enc0, dec0)
bench("seed 7 (field order)", enc7, dec7)
bench("seed 7 + code offsets", enc7o, dec7o)
bench("session-selected variant", encSel, decSel)
bench("per-call table lookup", function(bb, bit, r) return ENC[sessionIndex](bb, bit, r) end,
	function(bb, bit) return DEC[sessionIndex](bb, bit) end)

-- exhaustive round trip of the offset codes, so the method is canonical (every code decodes and re-encodes to itself)
for v = 0, 100 do
	local r2: R = { ammo = v * 2, health = v, team = if v % 2 == 0 then "red" else "blue" }
	enc7o(b, 0, r2)
	local d = dec7o(b, 0)
	assert(d.ammo == r2.ammo and d.health == r2.health and d.team == r2.team, "offset round trip " .. v)
end
print("offset round trip: ok (health 0..100, ammo 0..200 step 2)")
