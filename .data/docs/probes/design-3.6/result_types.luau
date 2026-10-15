--!strict
export type ServerResult<R, E> =
	{ ok: true, value: R, roundTrip: number, pingAtSend: number, pingAtAnswer: number, minPing: number }
	| { ok: false, error: E, roundTrip: number?, pingAtSend: number?, pingAtAnswer: number?, minPing: number? }
local r: ServerResult<number, "timeout" | "left"> = nil :: any
if r.ok then
	local v: number = r.value
	local t: number = r.roundTrip
	print(v, t)
else
	local e: "timeout" | "left" = r.error
	local t = r.roundTrip
	if t then print(e, t + 1) end
	print(t + 1) -- EXPECT error: t may be nil
	print(r.value) -- EXPECT error
end
