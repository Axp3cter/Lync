--!strict

--[=[
	facts.spec

	Facts (v5.md §7.3): evidence in each reason's registry order, coalescing, both caps and
	`suppressed`, bounded memory freed on `forget`, and delivery to observers in their own
	threads. Facts run on a world's server host, whose clock the tests step.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Check = require("../support/check")
local Console = require("../../src/diag/console")
local Counters = require("../../src/diag/counters")
local Facts = require("../../src/diag/facts")
local World = require("../support/world")

-- Types -------------------------------------------------------------------------------------------

type Setup = {
	world: World.World,
	facts: Facts.State,
	counters: Counters.State,
	delivered: { Facts.Fact },
}

-- Constants ---------------------------------------------------------------------------------------

const WINDOW = 30

-- Each fact with the evidence fields v5.md §7.3 lists, in its order.
const EVIDENCE_CASES = table.freeze({
	{ reason = "overBudget", evidence = { "lane", "bytes", "instances", "elements" } },
	{ reason = "malformed", evidence = { "lane", "rule" } },
	{ reason = "decoderRaised", evidence = { "lane" } },
	{ reason = "tagMismatch", evidence = { "lane", "expected" } },
	{ reason = "frameGap", evidence = { "skipped" } },
	{ reason = "desync", evidence = { "failures", "rekeySent" } },
	{ reason = "replayed", evidence = { "seq", "behind", "seen" } },
	{ reason = "impossibleAck", evidence = { "seq" } },
	{ reason = "repeatedHello", evidence = { "hashChanged" } },
	{
		reason = "schemaMismatch",
		evidence = { "version", "seedDiffers", "hashLow", "hashHigh", "unknownName" },
	},
	{ reason = "slotConflict", evidence = { "slot", "case" } },
	{ reason = "overLimit", evidence = { "perSecond", "burst" } },
	{ reason = "unresolved", evidence = { "what", "value" } },
	{ reason = "sendDropped", evidence = { "queue", "lane", "bytes" } },
	{ reason = "missedFlush", evidence = { "frames" } },
	{ reason = "remotesMissing", evidence = { "seconds" } },
})

-- Private -----------------------------------------------------------------------------------------

local function setUp(seed: number): Setup
	local world = World.new({ seed = seed })
	local host = world.server.host
	local counters = Counters.new()
	local facts = Facts.new(host, Console.new(host), counters)
	local delivered: { Facts.Fact } = {}
	Facts.observe(facts, function(fact: Facts.Fact)
		table.insert(delivered, fact)
	end)

	return { world = world, facts = facts, counters = counters, delivered = delivered }
end

local function playersOf(setup: Setup, count: number): { Player }
	local players = {}
	for _ = 1, count do
		table.insert(players, setup.world:join().player :: Player)
	end

	return players
end

-- Steps the clock by `dt`, then sweeps, as a flush does.
local function stepAndSweep(setup: Setup, dt: number)
	setup.world:step(dt)
	Facts.sweep(setup.facts, setup.world.server.host.clock())
end

local function countOf(facts: { Facts.Fact }, reason: string, player: Player?): number
	local count = 0
	for _, fact in facts do
		if fact.reason == reason and fact.player == player then
			count += 1
		end
	end

	return count
end

local function senderOf(setup: Setup, player: Player): any
	return (setup.facts :: any).senderByPlayer[player]
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["every fact's evidence follows its registry order"] = function()
		local setup = setUp(1)
		for _, case in EVIDENCE_CASES do
			Facts.record(setup.facts, case.reason :: any, nil, "arena", "chat", 1, 2, 3, 4, 5)

			local fact = setup.delivered[#setup.delivered]
			local expected = {}
			for i, name in case.evidence do
				expected[name] = i
			end
			Check.expectEqual(fact.reason, case.reason, "reason")
			Check.expectEqual(fact.evidence, expected, `{case.reason} evidence`)
		end
	end,

	["the first occurrence is delivered at once, the rest at the window's close"] = function()
		local setup = setUp(2)
		local player = playersOf(setup, 1)[1]
		local now = setup.world.server.host.now
		local firstAt = now()
		Facts.record(setup.facts, "overLimit", player, "arena", "chat", 5, 5)

		Check.expectEqual(setup.delivered, {
			{
				reason = "overLimit",
				player = player,
				namespace = "arena",
				definition = "chat",
				count = 1,
				first = firstAt,
				last = firstAt,
				evidence = { perSecond = 5, burst = 5 },
			},
		}, "the first occurrence")

		stepAndSweep(setup, 1)
		local secondAt = now()
		Facts.record(setup.facts, "overLimit", player, "arena", "chat", 6, 7)
		stepAndSweep(setup, 1)
		local lastAt = now()
		Facts.record(setup.facts, "overLimit", player, "arena", "chat", 8, 9)
		stepAndSweep(setup, WINDOW - 3)
		Check.expectEqual(#setup.delivered, 1, "nothing more before the close")

		stepAndSweep(setup, 1)
		Check.expectEqual(setup.delivered[2], {
			reason = "overLimit",
			player = player,
			namespace = "arena",
			definition = "chat",
			count = 2,
			first = secondAt,
			last = lastAt,
			evidence = { perSecond = 8, burst = 9 },
		}, "the coalesced occurrences")
	end,

	["a key with one occurrence closes silently, and the next opens a new window"] = function()
		local setup = setUp(3)
		Facts.record(setup.facts, "frameGap", nil, nil, nil, 1)
		stepAndSweep(setup, WINDOW)
		Check.expectEqual(#setup.delivered, 1, "only the first")

		Facts.record(setup.facts, "frameGap", nil, nil, nil, 2)
		Check.expectEqual(#setup.delivered, 2, "a new window delivers at once")
		Check.expectEqual(setup.delivered[2].count, 1, "count")
	end,

	["keys are per reason, namespace and definition"] = function()
		local setup = setUp(4)
		Facts.record(setup.facts, "overLimit", nil, "arena", "chat", 5, 5)
		Facts.record(setup.facts, "overLimit", nil, "shop", "chat", 5, 5)
		Facts.record(setup.facts, "overLimit", nil, "arena", "buy", 5, 5)
		Facts.record(setup.facts, "unresolved", nil, "arena", "chat", 1, 0)
		Facts.record(setup.facts, "overLimit", nil, "arena", "chat", 5, 5)

		Check.expectEqual(#setup.delivered, 4, "one delivery per key")
	end,

	["past the per-player cap, occurrences are suppressed and counted per reason"] = function()
		local setup = setUp(5)
		Facts.configure(setup.facts, WINDOW, 4, 256)
		local player = playersOf(setup, 1)[1]
		for i = 1, 6 do
			Facts.record(setup.facts, "overLimit", player, "arena", `definition{i}`, 5, 5)
		end
		Facts.record(setup.facts, "unresolved", player, "arena", "chat", 1, 0)
		Facts.record(setup.facts, "unresolved", player, "arena", "chat", 1, 0)

		Check.expectEqual(countOf(setup.delivered, "overLimit", player), 4, "within the cap")
		local at = setup.world.server.host.now()
		stepAndSweep(setup, WINDOW)

		Check.expectEqual(#setup.delivered, 5, "the cap holds within the window")
		Check.expectEqual(setup.delivered[5], {
			reason = "suppressed",
			player = player,
			count = 4,
			first = at,
			last = at,
			evidence = { overLimit = 2, unresolved = 2 },
		}, "the suppressed fact")
	end,

	["the server cap holds across players, each getting its own suppressed"] = function()
		local setup = setUp(6)
		Facts.configure(setup.facts, WINDOW, 16, 16)
		local players = playersOf(setup, 20)
		for _, player in players do
			Facts.record(setup.facts, "malformed", player, nil, nil, 0, 4)
		end

		Check.expectEqual(#setup.delivered, 16, "within the server cap")
		stepAndSweep(setup, WINDOW)

		Check.expectEqual(#setup.delivered, 20, "4 suppressed, exempt from the caps")
		for i = 17, 20 do
			Check.expectEqual(setup.delivered[i].reason, "suppressed", `fact {i}`)
			Check.expectEqual(setup.delivered[i].evidence, { malformed = 1 }, `fact {i} evidence`)
			Check.expectEqual(countOf(setup.delivered, "suppressed", players[i]), 1, `player {i}`)
		end
	end,

	["a coalesced fact past a cap is suppressed, never lost"] = function()
		local setup = setUp(7)
		Facts.configure(setup.facts, WINDOW, 1, 256)
		local player = playersOf(setup, 1)[1]
		for _ = 1, 3 do
			Facts.record(setup.facts, "replayed", player, nil, nil, 7, 70, 0)
		end
		stepAndSweep(setup, WINDOW)

		Check.expectEqual(#setup.delivered, 2, "the first, then suppressed")
		Check.expectEqual(setup.delivered[2].reason, "suppressed", "reason")
		Check.expectEqual(setup.delivered[2].evidence, { replayed = 2 }, "evidence")
	end,

	["a player holds at most perPlayerEvents keys and one count per reason"] = function()
		local setup = setUp(8)
		local player = playersOf(setup, 1)[1]
		for _, case in EVIDENCE_CASES do
			for definition = 1, 200 do
				Facts.record(setup.facts, case.reason :: any, player, "arena", `d{definition}`, 1)
			end
		end

		local sender = senderOf(setup, player)
		local reasonCount = 0
		for _ in sender.suppressedByReason do
			reasonCount += 1
		end
		Check.expectEqual(#sender.keys, 16, "keys")
		Check.expectEqual(reasonCount, #EVIDENCE_CASES, "suppressed counts")

		Facts.forget(setup.facts, player)
		Check.expectEqual(senderOf(setup, player), nil, "freed on forget")
	end,

	["a player holding nothing is freed by the sweep"] = function()
		local setup = setUp(9)
		local player = playersOf(setup, 1)[1]
		Facts.record(setup.facts, "malformed", player, nil, nil, 0, 4)
		stepAndSweep(setup, WINDOW)

		Check.expectEqual(senderOf(setup, player), nil, "freed")
	end,

	["observers run in their own threads: a throwing one is one native report"] = function()
		local setup = setUp(10)
		local connection = Facts.observe(setup.facts, function()
			error("observer failed", 0)
		end)
		local yielded = 0
		Facts.observe(setup.facts, function()
			yielded += 1
			coroutine.yield()
			yielded += 1
		end)
		local last: Facts.Fact? = nil
		Facts.observe(setup.facts, function(fact: Facts.Fact)
			last = fact
		end)

		Facts.record(setup.facts, "desync", nil, nil, nil, 8, 1)
		Check.expectEqual(#setup.delivered, 1, "the first observer still gets it")
		Check.expect(last ~= nil and last.reason == "desync", "an observer after the throw gets it")
		Check.expectEqual(yielded, 1, "a yielding observer holds only itself")
		Check.expectEqual(
			setup.world:claimReports(setup.world.server, "observer failed"),
			1,
			"reports"
		)

		connection:disconnect()
		connection:disconnect()
		Facts.record(setup.facts, "desync", nil, "arena", nil, 8, 0)
		Check.expectEqual(#setup.delivered, 2, "the others keep observing")
		Check.expectEqual(#setup.world:claimLines(setup.world.server, "desync"), 1, "lines")
		setup.world:expectQuiet()
	end,

	["every occurrence counts in its reason's counter, past coalescing and caps"] = function()
		local setup = setUp(12)
		Facts.configure(setup.facts, WINDOW, 1, 256)
		local players = playersOf(setup, 2)
		for _ = 1, 3 do
			Facts.record(setup.facts, "replayed", players[1], nil, nil, 7, 70, 1)
		end
		Facts.record(setup.facts, "malformed", players[1], nil, nil, 0, 4)
		Facts.record(setup.facts, "malformed", players[2], nil, nil, 0, 4)
		Facts.record(setup.facts, "frameGap", nil, nil, nil, 1)
		stepAndSweep(setup, WINDOW)

		local side = Counters.snapshot(setup.counters).facts
		Check.expectEqual(side.replayed, 3, "replayed, coalesced and suppressed")
		Check.expectEqual(side.malformed, 2, "malformed, one suppressed")
		Check.expectEqual(side.frameGap, 1, "a local fact")
		Check.expectEqual(side.suppressed, 0, "suppressed is a delivery, not an occurrence")
		Check.expectEqual(side.overLimit, 0, "every fact reason has its counter")

		local first = Counters.snapshot(setup.counters, players[1]).facts
		Check.expectEqual(first.replayed, 3, "the first player's replayed")
		Check.expectEqual(first.malformed, 1, "the first player's malformed")
		Check.expectEqual(
			Counters.snapshot(setup.counters, players[2]).facts.malformed,
			1,
			"the second's"
		)
	end,

	["facts and their evidence are frozen"] = function()
		local setup = setUp(11)
		local player = playersOf(setup, 1)[1]
		Facts.configure(setup.facts, WINDOW, 1, 256)
		Facts.record(setup.facts, "tagMismatch", player, nil, nil, 0, 3)
		Facts.record(setup.facts, "frameGap", player, nil, nil, 1)
		stepAndSweep(setup, WINDOW)

		for _, fact in setup.delivered do
			Check.expect(table.isfrozen(fact :: any), `{fact.reason} is frozen`)
			Check.expect(table.isfrozen(fact.evidence :: any), `{fact.reason} evidence is frozen`)
		end
		Check.expectEqual(setup.delivered[2].reason, "suppressed", "the second fact")
	end,
}
