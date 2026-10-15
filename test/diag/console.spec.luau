--!strict

--[=[
	console.spec

	Console lines (v5.md §7.4): at most 2 per code per window whatever the number of players,
	constant text with the numbers in the context, local facts only on a client, and silence
	when disabled.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Check = require("../support/check")
local Console = require("../../src/diag/console")
local Facts = require("../../src/diag/facts")
local World = require("../support/world")

-- Constants ---------------------------------------------------------------------------------------

const WINDOW = 30
const TEMPLATE =
	"[Lync] overLimit: {count} in {seconds} s, {players} players, {definitions} definitions"

-- Private -----------------------------------------------------------------------------------------

local function sweep(world: World.World, facts: Facts.State, dt: number)
	world:step(dt)
	Facts.sweep(facts, world.server.host.clock())
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["100 players make at most 2 lines per code per window, with constant text"] = function()
		local world = World.new({ seed = 1 })
		local host = world.server.host
		local facts = Facts.new(host, Console.new(host))
		local players: { Player } = {}
		for _ = 1, 100 do
			table.insert(players, world:join().player :: Player)
		end

		for window = 1, 2 do
			for round = 1, 5 do
				for i, player in players do
					local definition = `definition{(i + round) % 3}`
					Facts.record(facts, "overLimit", player, "arena", definition, 5, 5)
				end
				sweep(world, facts, 1)
			end

			local lines = world:claimLines(world.server, "overLimit")
			Check.expectEqual(#lines, 1, `window {window}: one line at once`)
			Check.expectEqual(lines[1].template, TEMPLATE, "the first line's text")
			Check.expectEqual(lines[1].context.count, 1, "the first line's count")
			Check.expectEqual(lines[1].context.seconds, 0, "the first line's seconds")
			Check.expectEqual(lines[1].context.userIds, { players[1].UserId }, "the first player")

			sweep(world, facts, WINDOW - 5)
			lines = world:claimLines(world.server, "overLimit")
			Check.expectEqual(#lines, 1, `window {window}: one summary at its close`)

			local summary = lines[1]
			Check.expectEqual(summary.template, TEMPLATE, "the summary's text")
			Check.expectEqual(summary.context.count, 500, "every occurrence counted")
			Check.expectEqual(summary.context.seconds, WINDOW, "the window")
			Check.expectEqual(summary.context.players, 100, "distinct players")
			Check.expectEqual(summary.context.definitions, 3, "distinct definitions")
			Check.expectEqual(#summary.context.userIds, 8, "at most 8 user ids")
			Check.expectEqual(#summary.context.definitionNames, 3, "the definition names")
			Check.expect(table.isfrozen(summary.context.userIds), "the lists are frozen")
		end

		Check.expectEqual(world:claimReports(world.server, ""), 0, "no reports")
		world:expectQuiet()
	end,

	["one occurrence makes one line and no summary"] = function()
		local world = World.new({ seed = 2 })
		local host = world.server.host
		local console = Console.new(host)
		Console.fact(console, "impossibleAck", nil, nil, host.clock())
		world:step(WINDOW + 1)
		Console.sweep(console, host.clock())

		local lines = world:claimLines(world.server, "impossibleAck")
		Check.expectEqual(#lines, 1, "lines")
		Check.expectEqual(lines[1].context.players, 0, "no player")
		world:expectQuiet()
	end,

	["each code has its own window"] = function()
		local world = World.new({ seed = 3 })
		local host = world.server.host
		local console = Console.new(host)
		Console.fact(console, "malformed", nil, nil, host.clock())
		Console.fact(console, "tagMismatch", nil, nil, host.clock())
		Console.fact(console, "malformed", nil, nil, host.clock())

		Check.expectEqual(#world:claimLines(world.server, "malformed"), 1, "malformed")
		Check.expectEqual(#world:claimLines(world.server, "tagMismatch"), 1, "tagMismatch")
		world:expectQuiet()
	end,

	["a client prints only its local facts"] = function()
		local world = World.new({ seed = 4 })
		local client = world:join()
		local host = client.host
		local console = Console.new(host)
		for _, reason in { "malformed", "tagMismatch", "replayed", "suppressed" } do
			Console.fact(console, reason :: any, nil, nil, host.clock())
		end
		Check.expectEqual(#client.lines, 0, "facts about what it received")

		for _, reason in { "sendDropped", "missedFlush", "remotesMissing" } do
			Console.fact(console, reason :: any, nil, "chat", host.clock())
			Check.expectEqual(#world:claimLines(client, reason), 1, reason)
		end
		world:expectQuiet()
	end,

	["a disabled console prints nothing, and its open windows close silently"] = function()
		local world = World.new({ seed = 5 })
		local host = world.server.host
		local console = Console.new(host)
		Console.fact(console, "overBudget", nil, nil, host.clock())
		Console.fact(console, "overBudget", nil, nil, host.clock())
		Check.expectEqual(#world:claimLines(world.server, "overBudget"), 1, "the first line")

		Console.enable(console, false)
		Console.fact(console, "overBudget", nil, nil, host.clock())
		Console.fact(console, "malformed", nil, nil, host.clock())
		world:step(WINDOW)
		Console.sweep(console, host.clock())
		world:expectQuiet()

		Console.enable(console, true)
		Console.fact(console, "malformed", nil, nil, host.clock())
		Check.expectEqual(#world:claimLines(world.server, "malformed"), 1, "printing again")
	end,

	["the window follows observe.window"] = function()
		local world = World.new({ seed = 6 })
		local host = world.server.host
		local facts = Facts.new(host, Console.new(host))
		Facts.configure(facts, 5, 16, 256)
		Facts.record(facts, "frameGap", nil, nil, nil, 1)
		Facts.record(facts, "frameGap", nil, nil, nil, 1)
		sweep(world, facts, 5)

		local lines = world:claimLines(world.server, "frameGap")
		Check.expectEqual(#lines, 2, "the first line and the summary")
		Check.expectEqual(lines[2].context.seconds, 5, "the summary's window")
		world:expectQuiet()
	end,
}
