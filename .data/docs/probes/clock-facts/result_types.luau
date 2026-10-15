--!strict
-- U4: the server-side request result with timing fields, as a generated shard would declare it, and the game-code
-- reads it must allow. Checked under both solvers: luau-analyze --solver=new / --solver=old.
-- Fields are present on every arm; -1 marks "no such moment" (the facts' convention, e.g. desync.sinceRekey).
export type ServerTiming = {
	roundTrip: number, -- s: os.clock() at the answer's decode minus os.clock() at the flush that sent the ask; -1 if none
	pingAtAsk: number, -- s: GetNetworkPing() sampled at that flush; -1 if the ask was never sent
	pingAtAnswer: number, -- s: GetNetworkPing() sampled at the answer's decode; -1 if no answer arrived
	minPing: number, -- s: the path bound (U10) at the answer's decode; -1 if no answer arrived
}
export type ServerResult<R, E> =
	{ ok: true, value: R, roundTrip: number, pingAtAsk: number, pingAtAnswer: number, minPing: number }
	| { ok: false, error: E, roundTrip: number, pingAtAsk: number, pingAtAnswer: number, minPing: number }

type AskError = "timeout" | "rejected" | "unanswered" | "left" | "shutdown"

local function fake(): ServerResult<number, AskError>
	return { ok = true, value = 3, roundTrip = 0.13, pingAtAsk = 0.1, pingAtAnswer = 0.1, minPing = 0.09 }
end

local r = fake()
-- every arm: timing readable without narrowing
local slack: number = r.roundTrip - r.minPing
if r.ok then
	local v: number = r.value
	print(v, slack)
else
	local e: AskError = r.error
	if r.error == "timeout" then
		local none: number = r.pingAtAnswer -- -1 here
		print(none)
	end
	print(e)
end
-- a helper that only takes the timing part (structural: the result is a subtype of ServerTiming)
local function processing(t: ServerTiming): number
	return t.roundTrip - t.minPing
end
print(processing(r))
