--!strict
-- Typing probe for the U11/U14 server API shapes, as a generated server shard would declare them.
-- Lines marked EXPECT must produce exactly one type error each, on both solvers; nothing else may.
-- No `read` modifiers: the old solver rejects them ("read keyword is illegal here", first run of this probe), so
-- shards typed for both solvers declare plain fields and freeze at run time.
-- MISSED marks an error neither solver reports (an extra key in a table literal passed to a sealed table type).
-- Run: luau-analyze --solver=new --mode=strict types.luau ; luau-analyze --solver=old --mode=strict types.luau

type Player = { UserId: number } -- stand-in: the probe runs without Roblox definitions

-- U14 ---------------------------------------------------------------------------------------------------
export type ChallengeOptions = { within: number, values: number?, attempts: number? }
export type ChallengeClosed =
	{ outcome: "answered", after: number, attempts: number, minPing: number, definition: string }
	| { outcome: "mismatched", after: number, attempts: number, minPing: number, definition: string }
	| { outcome: "timeout" | "cancelled" | "left" | "shutdown", after: nil, attempts: number, minPing: number, definition: nil }

export type Challenge = {
	token: number,
	deadline: number,
	wait: (self: Challenge) -> ChallengeClosed,
	extend: (self: Challenge, seconds: number) -> (),
	cancel: (self: Challenge) -> (),
}

-- generated per definition: only the definition's top-level integer fields are accepted
type UseServerView = { answers: (self: UseServerView, field: "code") -> () }

local function makeChallenge(_player: Player, options: ChallengeOptions): Challenge
	local c: Challenge = {
		token = 0,
		deadline = options.within,
		wait = function(_self: Challenge): ChallengeClosed
			return { outcome = "timeout", after = nil, attempts = 0, minPing = 0.05, definition = nil }
		end,
		extend = function(_self: Challenge, _seconds: number) end,
		cancel = function(_self: Challenge) end,
	}
	return c
end
local Lync = { challenge = makeChallenge }
local use: UseServerView = { answers = function(_self: UseServerView, _field: "code") end }

use:answers("code")
use:answers("cdoe") -- EXPECT: a misspelled field is a type error

local player: Player = { UserId = 1 }
local c = Lync.challenge(player, { within = 120, values = 10_000, attempts = 3 })
local closed = c:wait()
if closed.outcome == "answered" then
	local after: number = closed.after -- narrowed: number
	local def: string = closed.definition
	print(after, def)
elseif closed.outcome == "timeout" then
	local after: number = closed.after -- EXPECT: after is nil when nothing closed the challenge
	print(after)
end
Lync.challenge(player, { within = 120, attemps = 3 }) -- MISSED: misspelled option; the runtime must throw for unknown keys

-- U11 ---------------------------------------------------------------------------------------------------
type Fighter = { position: vector, health: number }
type Perceived = { tick: number, exact: boolean }
type Rewound = { ok: true, value: Fighter } | { ok: false, error: "expired" | "notHeld" | "unknownKey" }
type FightersServerView = {
	held: (self: FightersServerView, seen: Perceived) -> { number },
	rewound: (self: FightersServerView, seen: Perceived, key: number) -> Rewound,
	reportInteraction: (self: FightersServerView, player: Player, key: number, kind: number) -> (),
}
local fighters: FightersServerView = {
	held = function(_self: FightersServerView, _seen: Perceived): { number } return {} end,
	rewound = function(_self: FightersServerView, _seen: Perceived, _key: number): Rewound
		return { ok = false, error = "unknownKey" }
	end,
	reportInteraction = function(_self: FightersServerView, _player: Player, _key: number, _kind: number) end,
}

local seen: Perceived = { tick = 230.4, exact = true }
for _, key in fighters:held(seen) do
	local r = fighters:rewound(seen, key)
	if r.ok then
		local p: vector = r.value.position
		print(p)
		fighters:reportInteraction(player, key, 1)
	else
		local e: "expired" | "notHeld" | "unknownKey" = r.error
		print(e)
	end
end
fighters:reportInteraction(player, "k", 1) -- EXPECT: the key's type is the collection's key type
