--!strict

--[=[
	net.spec

	The simulated network of m2-plan.md §6.1, measured over 10^5 frames per property: delay
	distributions, reliable order under stalls, unreliable loss, duplication, bursts and
	reordering, the 1000 B unreliable drop, and seeded determinism.

	"Within 1%" is read as within 0.01 of the setting's fraction of frames. Reordering has no
	setting of its own: frames sent `interval` apart with uniform jitter J > interval swap with a
	neighbour with chance (1 - interval / J)^2 / 2, which is what the measured rate is compared
	with.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Check = require("../support/check")
local Net = require("../support/net")

-- Constants ---------------------------------------------------------------------------------------

const FRAMES = 100_000
const INTERVAL = 1 / 60
const RATE_TOLERANCE = 0.01

const RELIABLE = 0
const UNRELIABLE = 1

const QUIET = table.freeze({
	loss = 0,
	stall = table.freeze({ chance = 0, seconds = 0 }),
})

-- Private -----------------------------------------------------------------------------------------

local function linkOf(overrides: { [string]: any }, seed: number?): Net.Link
	return Net.link(Net.params(Net.HONEST, overrides), seed or 1, 0)
end

local function withQuiet(overrides: { [string]: any }): { [string]: any }
	local merged = table.clone(QUIET) :: { [string]: any }
	for name, value in overrides do
		merged[name] = value
	end

	return merged
end

-- Sends FRAMES frames `interval` apart; returns each frame's first arrival (nil when lost), and
-- how many arrived twice.
local function sendAll(link: Net.Link, lane: number, interval: number): ({ number? }, number)
	local arrivals: { number? } = {}
	local duplicateCount = 0
	for i = 1, FRAMES do
		local first, second = Net.schedule(link, (i - 1) * interval, lane, 100)
		arrivals[i] = first
		if second ~= nil then
			duplicateCount += 1
		end
	end

	return arrivals, duplicateCount
end

local function lostFraction(arrivals: { number? }): number
	local lostCount = 0
	for i = 1, FRAMES do
		if arrivals[i] == nil then
			lostCount += 1
		end
	end

	return lostCount / FRAMES
end

local function expectNear(actual: number, expected: number, tolerance: number, what: string)
	Check.expect(
		math.abs(actual - expected) <= tolerance,
		`{what}: got {actual}, expected {expected} ± {tolerance}`
	)
end

local function expectDelays(lane: number)
	local link = linkOf(withQuiet({ latency = 0.05, jitter = 0.02 }))
	local deciles = table.create(10, 0)
	local total = 0
	for i = 1, FRAMES do
		local sentAt = (i - 1) * 0.5
		local delay = (Net.schedule(link, sentAt, lane, 100) :: number) - sentAt
		Check.expect(delay >= 0.05 and delay < 0.07, `delay {delay} must be in [0.05, 0.07)`)
		total += delay
		local decile = math.floor((delay - 0.05) / 0.002) + 1
		deciles[decile] += 1
	end

	expectNear(total / FRAMES, 0.06, 0.0002, "mean delay")
	for decile, count in deciles do
		expectNear(count / FRAMES, 0.1, RATE_TOLERANCE, `delay decile {decile}`)
	end
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["delays are latency plus uniform jitter on the unreliable lane"] = function()
		expectDelays(UNRELIABLE)
	end,

	["delays are latency plus uniform jitter on the reliable lane"] = function()
		expectDelays(RELIABLE)
	end,

	["reliable frames keep their order under jitter and stalls"] = function()
		local link = linkOf({ jitter = 0.05, stall = { chance = 1, seconds = 0.3 } })
		local arrivals = sendAll(link, RELIABLE, INTERVAL)
		for i = 1, FRAMES do
			local arrival = arrivals[i] :: number
			Check.expect(
				arrival >= (i - 1) * INTERVAL + 0.05,
				`frame {i} arrived before its latency`
			)
			if i > 1 then
				Check.expect(
					arrival >= arrivals[i - 1] :: number,
					`frame {i} overtook frame {i - 1}`
				)
			end
		end
	end,

	["a stall holds every reliable frame due in it and releases them at its end"] = function()
		local stall = { chance = 1, seconds = 0.3 }
		local link = linkOf({ jitter = 0, stall = stall })
		local arrivals = sendAll(link, RELIABLE, INTERVAL)

		local heldCount = 0
		for i = 2, FRAMES do
			if arrivals[i] == arrivals[i - 1] then
				heldCount += 1
			end
		end

		-- Stalls start at `chance` per second once the last has ended; each holds the frames due
		-- in `seconds`, all but the first of which arrive with the one before.
		local stallsPerSecond = stall.chance / (1 + stall.chance * stall.seconds)
		local expected = stallsPerSecond * (stall.seconds / INTERVAL - 1)
		expectNear(heldCount / (FRAMES * INTERVAL), expected, 2, "frames held per second")
	end,

	["reliable frames are never lost, duplicated or limited in size"] = function()
		local link = linkOf({ loss = 0.5, duplicate = 0.5, burst = { enter = 0.5, leave = 0.1 } })
		for i = 1, 1000 do
			local first, second = Net.schedule(link, i * INTERVAL, RELIABLE, 20_000)
			Check.expect(first ~= nil and second == nil, `reliable frame {i} must arrive once`)
		end
	end,

	["unreliable loss is within 1% of its setting"] = function()
		for _, loss in { 0.05, 0.25 } do
			local arrivals = sendAll(linkOf(withQuiet({ loss = loss })), UNRELIABLE, INTERVAL)
			expectNear(lostFraction(arrivals), loss, RATE_TOLERANCE, `loss {loss}`)
		end
	end,

	["unreliable duplication is within 1% of its setting"] = function()
		for _, duplicate in { 0.01, 0.2 } do
			local link = linkOf(withQuiet({ duplicate = duplicate }))
			local _, duplicateCount = sendAll(link, UNRELIABLE, INTERVAL)
			expectNear(duplicateCount / FRAMES, duplicate, RATE_TOLERANCE, `duplicate {duplicate}`)
		end
	end,

	["unreliable reordering is within 1% of the rate its jitter gives"] = function()
		for _, interval in { INTERVAL, 0.004 } do
			local jitter = 0.02
			local link = linkOf(withQuiet({ jitter = jitter }))
			local arrivals = sendAll(link, UNRELIABLE, interval)

			local swappedCount = 0
			for i = 2, FRAMES do
				if (arrivals[i] :: number) < (arrivals[i - 1] :: number) then
					swappedCount += 1
				end
			end

			local expected = (1 - interval / jitter) ^ 2 / 2
			expectNear(
				swappedCount / (FRAMES - 1),
				expected,
				RATE_TOLERANCE,
				`reorder at {interval}`
			)
		end
	end,

	["bursts add their share of loss, in runs of 1 / leave frames"] = function()
		local burst = { enter = 0.01, leave = 0.25 }
		local badFraction = burst.enter / (burst.enter + burst.leave)
		local lossy =
			sendAll(linkOf(withQuiet({ loss = 0.05, burst = burst })), UNRELIABLE, INTERVAL)
		local expected = badFraction + (1 - badFraction) * 0.05
		expectNear(lostFraction(lossy), expected, RATE_TOLERANCE, "loss with bursts")

		local arrivals = sendAll(linkOf(withQuiet({ burst = burst })), UNRELIABLE, INTERVAL)
		local runCount = 0
		local lostCount = 0
		for i = 1, FRAMES do
			if arrivals[i] == nil then
				lostCount += 1
				if i == 1 or arrivals[i - 1] ~= nil then
					runCount += 1
				end
			end
		end
		expectNear(lostCount / runCount, 1 / burst.leave, 0.4, "burst length")
	end,

	["unreliable frames over 1000 B are dropped, and 1000 B frames are not"] = function()
		local link = linkOf(withQuiet({}))
		for i = 1, 100 do
			Check.expect(Net.schedule(link, i, UNRELIABLE, 1000) ~= nil, "1000 B must arrive")
			Check.expect(Net.schedule(link, i, UNRELIABLE, 1001) == nil, "1001 B must be dropped")
		end
	end,

	["a link's arrivals depend only on its seed"] = function()
		local overrides = { loss = 0.1, duplicate = 0.05, stall = { chance = 0.5, seconds = 0.3 } }
		local function trace(seed: number): string
			local link = linkOf(overrides, seed)
			local parts = {}
			for i = 1, 2000 do
				local first, second = Net.schedule(link, i * INTERVAL, i % 2, 100)
				table.insert(parts, `{first}/{second}`)
			end

			return table.concat(parts, ",")
		end

		Check.expect(trace(7) == trace(7), "equal seeds must give equal arrivals")
		Check.expect(trace(7) ~= trace(8), "other seeds must give other arrivals")
	end,

	["the random source is uniform over 32 bits"] = function()
		local random = Net.random(42)
		local bitCounts = table.create(32, 0)
		for _ = 1, FRAMES do
			local value = random()
			Check.expect(value >= 0 and value < 2 ^ 32 and value % 1 == 0, `{value} must be a u32`)
			for bit = 0, 31 do
				if bit32.btest(value, bit32.lshift(1, bit)) then
					bitCounts[bit + 1] += 1
				end
			end
		end

		for bit, count in bitCounts do
			expectNear(count / FRAMES, 0.5, RATE_TOLERANCE, `bit {bit - 1}`)
		end
	end,
}
