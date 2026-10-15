--!strict
-- A stand-in for Lync's client shard: `fire` walks `debug.info` to the first frame whose source is
-- not this module's, and returns that frame's source, line, name and function.

local OWN = debug.info(1, "s")

local Stub = {}

local function firstOutside(): (string?, number?, string?, any)
	local level = 2
	while true do
		local source, line, name, fn = debug.info(level, "slnf")
		if source == nil then
			return nil, nil, nil, nil -- ran off the thread's stack
		end
		if source ~= OWN then
			return source, line, name, fn
		end
		level += 1
	end
end

local function inner(): (string?, number?, string?, any)
	return firstOutside()
end

function Stub.fire(_value: any): (string?, number?, string?, any)
	return inner()
end

Stub.own = OWN
Stub.firstOutside = firstOutside

return Stub
