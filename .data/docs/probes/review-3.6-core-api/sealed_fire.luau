--!strict
-- Runtime path (v5.md §3.5, v5-checks.md §9.2): fire's return type from the presence of `sealed` in the
-- definition's options table type, by a type function. Lync.event captures the options table type D.
type Seal = { reveal: (self: Seal) -> (), discard: (self: Seal) -> () }
type function FireReturn(opts)
	if opts:is("table") and opts:readproperty(types.singleton("sealed")) ~= nil then
		return Seal
	end
	return types.singleton(nil)
end
type Event<D> = { fire: (self: Event<D>, target: any, data: any) -> FireReturn<D> }
local function event<D>(options: D): Event<D>
	return nil :: any
end
local plain = event({ from = "server", data = 1 })
local sealedEv = event({ from = "server", data = 1, sealed = {} })
local sealedOpts = event({ from = "server", data = 1, sealed = { outstanding = 2, hideLength = false } })
local s1 = sealedEv:fire(nil, 1)
s1:reveal()
sealedOpts:fire(nil, 1):discard()
local n = plain:fire(nil, 1)
-- EXPECT errors below: plain fire returns nil
n:reveal()
-- A conditional option: at run time `sealed` may be nil, the type says Seal (EXPECT: no error, which is the finding)
local flag: boolean = math.random() > 0.5
local maybe = event({ from = "server", data = 1, sealed = if flag then {} else nil })
maybe:fire(nil, 1):reveal()
-- A helper returning the options table: the property survives (EXPECT: no error)
local function serverEvent(data: number, extra: { sealed: {}? })
	return event({ from = "server", data = data, sealed = extra.sealed })
end
serverEvent(1, {}):fire(nil, 1):reveal()
