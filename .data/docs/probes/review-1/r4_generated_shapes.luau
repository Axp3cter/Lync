--!strict
-- R4: the concrete types a generated shard would emit, checked on BOTH solvers.
-- No type functions, no `read` modifiers: what draft 1 calls the primary path.
type Fighter = { name: string, health: number, title: string? }
type FighterPatch = { name: string?, health: number?, title: string? }
type Failure = "timeout" | "rejected" | "unanswered" | "left" | "shutdown"
type BuyResult = { ok: true, value: number } | { ok: false, error: Failure }
type Announce = { kind: "round", number: number } | { kind: "winner", team: "red" | "blue" }

local Net = {} :: {
	fighters: { patch: (self: any, id: number, p: FighterPatch) -> () },
	buy: { invoke: (self: any, req: { item: "sword" | "shield" }) -> BuyResult },
	announce: { connect: (self: any, f: (a: Announce) -> ()) -> () },
}

-- patch: concrete partial record
Net.fighters:patch(1, { health = 90 }) -- ok
Net.fighters:patch(1, { healht = 90 }) -- draft 1 says compile error
Net.fighters:patch(1, { health = "x" }) -- must fail

-- result narrowing on result.ok
local result = Net.buy:invoke({ item = "sword" })
if result.ok then
	local _v: number = result.value
else
	local _e: Failure = result.error
end
local _wrong: number = result.value -- must fail: not narrowed

-- union narrowing on kind
Net.announce:connect(function(a)
	if a.kind == "round" then
		local _n: number = a.number
		local _bad = a.team -- must fail
	end
end)
Net.buy:invoke({ item = "axe" }) -- must fail
