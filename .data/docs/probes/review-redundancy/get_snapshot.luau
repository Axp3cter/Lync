--!strict
-- Claim: `get` returning "a frozen snapshot, never the live table" (design §3.5) costs an allocation
-- per call if it clones, while a copy-on-write store (a new frozen record built once per change,
-- reused by every `get` and handed out as `previous` in `changed`) costs zero allocations per `get`.
-- Record shape: the §3.4 fighters record (6 fields). Values are plain Luau values; on Roblox a
-- Vector3 is a native vector (no allocation) and a CFrame is userdata (already allocated on decode).
-- Measures, interpreted and native:
--   clone_get : table.freeze(table.clone(live)) per get
--   cow_get   : return current frozen record
--   cow_change: build the next frozen record from the previous one plus one changed field
--               (the per-change cost that copy-on-write pays instead)
--   mutate    : write one field into a live table and save the old value as `previous` (baseline)
-- Run: luau -O2 get_snapshot.luau ; luau -O2 --codegen get_snapshot.luau

local N = 200000
local function bench(name: string, f: () -> ())
	local times = {}
	local kb0 = collectgarbage("count")
	for r = 1, 7 do
		local t0 = os.clock()
		f()
		table.insert(times, (os.clock() - t0) / N * 1e9)
	end
	table.sort(times)
	print(string.format("%-11s median %6.1f ns/op  (min %6.1f, max %6.1f)", name, times[4], times[1], times[7]))
	local _ = kb0
end

local live = {
	name = "Builderman",
	team = "red",
	health = 100,
	position = vector.create(1, 2, 3),
	look = 0,
	title = "champ",
}
local current = table.freeze(table.clone(live))
local sink: any = nil

bench("clone_get", function()
	for i = 1, N do
		sink = table.freeze(table.clone(live))
	end
end)

bench("cow_get", function()
	for i = 1, N do
		sink = current
	end
end)

bench("cow_change", function()
	for i = 1, N do
		local nextRec = table.clone(current) -- clone of a frozen table is unfrozen
		nextRec.health = i
		current = table.freeze(nextRec)
		sink = current
	end
end)

local prev = { health = 0 }
bench("mutate", function()
	for i = 1, N do
		prev.health = live.health
		live.health = i
		sink = prev
	end
end)

-- allocation size of one 6-field record clone
collectgarbage("collect")
local before = collectgarbage("count")
local keep = table.create(10000)
for i = 1, 10000 do
	keep[i] = table.clone(live)
end
local after = collectgarbage("count")
print(string.format("bytes per 6-field record clone: %.0f", (after - before) * 1024 / 10000))
