--!strict
-- review-2 t3: §6.3 observer events, generated-style concrete union: narrow on `kind`, then `reason`.
-- Checked on both solvers.
type Anomaly =
	{ kind: "anomaly", reason: "malformed", player: Player?, count: number, evidence: { lane: number, rule: number } }
	| { kind: "anomaly", reason: "overBudget", player: Player?, count: number, evidence: { lane: number, bytes: number, instances: number } }
	| { kind: "anomaly", reason: "trap", player: Player?, count: number, evidence: {} }
	| { kind: "anomaly", reason: "suppressed", player: Player?, count: number, evidence: { [string]: number } }
type Frame = { kind: "frame", definition: string, bytes: number }
type Event = Anomaly | Frame
type Player = { Name: string }
local function observe(fn: (e: Event) -> ()) end
observe(function(e)
	if e.kind == "anomaly" then
		if e.reason == "malformed" then
			local _r: number = e.evidence.rule
			local _bad = e.evidence.bytes -- must fail
		elseif e.reason == "suppressed" then
			local _n: number? = e.evidence.malformed
		end
	else
		local _b: number = e.bytes
	end
end)
