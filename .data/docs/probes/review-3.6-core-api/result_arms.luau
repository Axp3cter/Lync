--!strict
-- v5.md §5.2 guarantees all four timing fields for a client-sent `rejected` or `unanswered`, but §3.5's
-- ServerResult types them number? in the one failure arm. Part 1: the design's type forces a nil test there.
export type ServerResult<R, E> =
	{ ok: true, value: R, roundTrip: number, pingAtSend: number, pingAtAnswer: number, minPing: number }
	| { ok: false, error: E, roundTrip: number?, pingAtSend: number?, pingAtAnswer: number?, minPing: number? }
local r: ServerResult<number, "timeout" | "rejected" | "unanswered" | "left" | "shutdown"> = nil :: any
if not r.ok and r.error == "rejected" then
	local t: number = r.roundTrip -- EXPECT error under the design's type, though §5.2 says it is present
	print(t)
end
-- Part 2: arms split by what §5.2's table guarantees, discriminated on `error`.
export type ServerResult2<R> =
	{ ok: true, value: R, roundTrip: number, pingAtSend: number, pingAtAnswer: number, minPing: number }
	| { ok: false, error: "rejected" | "unanswered", roundTrip: number, pingAtSend: number, pingAtAnswer: number, minPing: number }
	| { ok: false, error: "timeout" | "left" | "shutdown", roundTrip: nil, pingAtSend: number?, pingAtAnswer: nil, minPing: nil }
local q: ServerResult2<number> = nil :: any
if q.ok then
	local v: number = q.value
	print(v)
elseif q.error == "rejected" or q.error == "unanswered" then
	local t: number = q.roundTrip -- clean if narrowing on error works
	print(t)
else
	local p = q.pingAtSend
	if p then print(p + 1) end
	print(q.roundTrip + 1) -- EXPECT error: nil
end
