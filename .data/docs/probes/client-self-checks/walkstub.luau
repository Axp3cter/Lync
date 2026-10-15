--!strict
-- Lync-side stand-ins for the cost probe: a walk to the first frame outside this module, entered
-- through 1, 3 or 5 frames of this module (table calls, so -O2 cannot inline them away).

local OWN = debug.info(1, "s")

local W = {}

function W.walk(): string?
	local level = 2
	while true do
		local source = debug.info(level, "s")
		if source ~= OWN then
			return source
		end
		level += 1
	end
end

function W.walkSkipC(): string?
	local level = 2
	while true do
		local source = debug.info(level, "s")
		if source == nil then
			return nil
		end
		if source ~= OWN and source ~= "[C]" then
			return source
		end
		level += 1
	end
end

function W.d1(): string?
	return W.walk()
end
function W.d2(): string?
	return (W.d1())
end
function W.d3(): string?
	return (W.d2())
end
function W.d4(): string?
	return (W.d3())
end
function W.d5(): string?
	return (W.d4())
end

-- the same walk, then a lookup of the source in the build's list for the definition
local LISTED: { [string]: boolean } = { ["./cost.luau"] = true }
function W.checked(): boolean
	local source = W.walk()
	return source ~= nil and LISTED[source] == true
end

return W
