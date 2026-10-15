local function lyncFire()
	-- walk by level from 1 and print source/function presence
	local out = {}
	for lvl = 1, 6 do
		local s, f = debug.info(lvl, "sf")
		if s == nil then break end
		table.insert(out, tostring(lvl) .. ":" .. s .. ":" .. tostring(f ~= nil))
	end
	return table.concat(out, " | ")
end
local function game() return lyncFire() end
print("direct", game())
print("pcall", select(2, pcall(game)))
print("pcall(lync)", select(2, pcall(lyncFire)))
print("wrap(game)", coroutine.wrap(game)())
print("wrap(lync)", coroutine.wrap(lyncFire)())
local function listener() return debug.info(2, "f") end
print("listener via wrap", coroutine.wrap(listener)())
print("listener direct", listener() ~= nil)
