--!strict
-- Claims about per-player state and per-tick work of draft 2's integrity measures:
--   1. canary sets: §6.2.12 keeps "one set entry per canary value a player was sent". Memory per entry
--      for a per-player { [string]: number } set, against one server-wide { [string]: slot } map plus a
--      per-viewer sent bitset (1 bit per record per viewer, in a buffer).
--   2. decoys: §6.2.11 calls behaviour(viewer, tick) for every viewer every state tick and diffs the
--      result against the viewer's previous decoys. Cost per call of a behaviour that returns one
--      decoy (a fresh { [Key]: Record } with a 6-field record) and the 6-field diff.
--   3. row ordering: §5.3 "the client applies a record's row only if its frame seq is newer (12-bit
--      serial arithmetic)": a record idle for 2048 or more downstream unreliable frames.
-- Run: luau -O2 [--codegen] integrity_state.luau

-- 1. canary memory
local function kb(): number
	return collectgarbage("count")
end
local RECORDS, PLAYERS = 1024, 100
local values = table.create(RECORDS, "")
for i = 1, RECORDS do
	values[i] = string.format("%016x", i * 2654435761 % 2 ^ 32) -- 16 chars, as min(16, maxBytes)
end
collectgarbage("collect")
local k0 = kb()
local perPlayer = table.create(PLAYERS)
for p = 1, PLAYERS do
	local s: { [string]: number } = {}
	for i = 1, RECORDS do
		s[values[i]] = i
	end
	perPlayer[p] = s
end
collectgarbage("collect")
local k1 = kb()
print(string.format("canary per-player sets: %d players x %d values = %.0f KB (%.1f B per entry)", PLAYERS, RECORDS, k1 - k0, (k1 - k0) * 1024 / (PLAYERS * RECORDS)))
perPlayer = nil :: any
collectgarbage("collect")
local k2 = kb()
local map: { [string]: number } = {}
for i = 1, RECORDS do
	map[values[i]] = i
end
local sent = table.create(PLAYERS)
for p = 1, PLAYERS do
	sent[p] = buffer.create(RECORDS // 8)
end
collectgarbage("collect")
local k3 = kb()
print(string.format("server-wide map + per-viewer bitsets: %.0f KB", k3 - k2))

-- 2. decoy behaviour call + diff
local N = 200000
local prev = { name = "Decoy", team = "red", health = 100, x = 1, y = 2, z = 3 }
local function behaviour(viewer: number, tick: number): { [number]: any }?
	return { [9000 + viewer] = { name = "Decoy", team = "red", health = 100, x = tick % 7, y = 2, z = 3 } }
end
local changedFields = 0
local times = {}
for _ = 1, 7 do
	local t0 = os.clock()
	for i = 1, N do
		local res = behaviour(i % 100, i)
		if res then
			for key, rec in res do
				for f, v in rec do
					if prev[f] ~= v then
						changedFields += 1
					end
				end
			end
		end
	end
	table.insert(times, (os.clock() - t0) / N * 1e9)
end
table.sort(times)
print(string.format("decoy behaviour call + diff: median %.0f ns (min %.0f, max %.0f) per viewer per state tick", times[4], times[1], times[7]))

-- 3. 12-bit serial arithmetic on a per-record stored sequence
local function newer12(a: number, b: number): boolean -- is a newer than b (RFC 1982 style)
	local d = (a - b) % 4096
	return d ~= 0 and d < 2048
end
for _, idle in { 100, 2047, 2048, 3000, 4095, 4096, 5000 } do
	local last = 500
	local nxt = (last + idle) % 4096
	print(string.format("record idle for %4d frames: new row %s (60 Hz: %.1f s, 20 Hz: %.1f s)", idle, if newer12(nxt, last) then "applied" else "DROPPED as older", idle / 60, idle / 20))
end
print(changedFields > 0)
