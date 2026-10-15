--!strict
-- The fix for sealed_fire.luau's conditional case: Seal when `sealed` excludes nil, Seal? when it may be nil.
type Seal = { reveal: (self: Seal) -> (), discard: (self: Seal) -> () }
type function FireReturn(opts)
	local p = if opts:is("table") then opts:readproperty(types.singleton("sealed")) else nil
	if p == nil or p:is("nil") then return types.singleton(nil) end
	if p:is("union") then
		for _, c in p:components() do
			if c:is("nil") then return types.optional(Seal) end
		end
	end
	return Seal
end
type Event<D> = { fire: (self: Event<D>, target: any, data: any) -> FireReturn<D> }
local function event<D>(options: D): Event<D>
	return nil :: any
end
local flag: boolean = math.random() > 0.5
event({ from = "server", data = 1, sealed = {} }):fire(nil, 1):reveal()
local maybe = event({ from = "server", data = 1, sealed = if flag then {} else nil }):fire(nil, 1)
if maybe then maybe:reveal() end
maybe:reveal() -- EXPECT error: maybe may be nil
