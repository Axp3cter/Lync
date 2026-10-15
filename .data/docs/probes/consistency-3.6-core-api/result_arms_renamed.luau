--!strict
-- v5.md §5.2 guarantees all four timing fields for a client-sent `rejected` or `unanswered`, but §3.5's
-- ServerResult types them number? in the one failure arm. Part 1: the design's type forces a nil test there.
export type ServerResult<R, E> =
	{ ok: true, value: R, roundTripSeconds: number, sendPingSeconds: number, answerPingSeconds: number, minPingSeconds: number }
	| { ok: false, error: E, roundTripSeconds: number?, sendPingSeconds: number?, answerPingSeconds: number?, minPingSeconds: number? }
local r: ServerResult<number, "timedOut" | "rejected" | "unanswered" | "playerLeft" | "serverClosing"> = nil :: any
if not r.ok and r.error == "rejected" then
	local t: number = r.roundTripSeconds -- EXPECT error under the design's type, though §5.2 says it is present
	print(t)
end
-- Part 2: arms split by what §5.2's table guarantees, discriminated on `error`.
export type ServerResult2<R> =
	{ ok: true, value: R, roundTripSeconds: number, sendPingSeconds: number, answerPingSeconds: number, minPingSeconds: number }
	| { ok: false, error: "rejected" | "unanswered", roundTripSeconds: number, sendPingSeconds: number, answerPingSeconds: number, minPingSeconds: number }
	| { ok: false, error: "timedOut" | "playerLeft" | "serverClosing", roundTripSeconds: nil, sendPingSeconds: number?, answerPingSeconds: nil, minPingSeconds: nil }
local q: ServerResult2<number> = nil :: any
if q.ok then
	local v: number = q.value
	print(v)
elseif q.error == "rejected" or q.error == "unanswered" then
	local t: number = q.roundTripSeconds -- clean if narrowing on error works
	print(t)
else
	local p = q.sendPingSeconds
	if p then print(p + 1) end
	print(q.roundTripSeconds + 1) -- EXPECT error: nil
end
