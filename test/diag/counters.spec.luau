--!strict

--[=[
	counters.spec

	Counters (v5.md §7.4): the snapshot's fields with and without a player, frozen, and freed on
	`forget`.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Check = require("../support/check")
local Counters = require("../../src/diag/counters")
local World = require("../support/world")

-- Private -----------------------------------------------------------------------------------------

local function twoPlayers(): (Player, Player)
	local world = World.new({ seed = 1 })
	return world:join().player :: Player, world:join().player :: Player
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["a fresh snapshot holds every field at zero"] = function()
		local counters = Counters.new()
		Check.expectEqual(Counters.snapshot(counters), {
			messagesSent = 0,
			messagesReceived = 0,
			bytesSent = 0,
			bytesReceived = 0,
			facts = {},
			rowsDeferred = 0,
			validatorErrors = 0,
			validatorRejections = 0,
			lateAnswers = 0,
			heldBytes = 0,
			definitions = {},
		}, "snapshot")
	end,

	["the side's snapshot has totals, facts by reason and messages per definition"] = function()
		local counters = Counters.new()
		local alice, bob = twoPlayers()
		local chatSent = Counters.slot(counters, "messagesSent.arena.chat")
		local chatBytes = Counters.slot(counters, "bytesSent.arena.chat")
		local buyReceived = Counters.slot(counters, "messagesReceived.arena.buy")
		local overLimit = Counters.slot(counters, "facts.overLimit")
		local lateAnswers = Counters.slot(counters, "lateAnswers")
		local heldBytes = Counters.slot(counters, "heldBytes")
		local unresolved = Counters.slot(counters, "unresolvedMessages")

		Counters.add(counters, chatSent, alice, 2)
		Counters.add(counters, chatSent, bob, 1)
		Counters.add(counters, chatBytes, alice, 40)
		Counters.add(counters, buyReceived, nil, 3)
		Counters.add(counters, overLimit, bob, 4)
		Counters.add(counters, lateAnswers, alice, 1)
		Counters.add(counters, heldBytes, alice, 100)
		Counters.add(counters, heldBytes, alice, -60)
		Counters.add(counters, unresolved, nil, 5)

		Check.expectEqual(Counters.snapshot(counters), {
			messagesSent = 3,
			messagesReceived = 3,
			bytesSent = 40,
			bytesReceived = 0,
			facts = { overLimit = 4 },
			rowsDeferred = 0,
			validatorErrors = 0,
			validatorRejections = 0,
			lateAnswers = 1,
			heldBytes = 40,
			unresolvedMessages = 5,
			definitions = {
				["arena.chat"] = {
					messagesSent = 3,
					messagesReceived = 0,
					bytesSent = 40,
					bytesReceived = 0,
				},
				["arena.buy"] = {
					messagesSent = 0,
					messagesReceived = 3,
					bytesSent = 0,
					bytesReceived = 0,
				},
			},
		}, "the side")

		Check.expectEqual(Counters.snapshot(counters, alice), {
			messagesSent = 2,
			messagesReceived = 0,
			bytesSent = 40,
			bytesReceived = 0,
			facts = { overLimit = 0 },
			rowsDeferred = 0,
			validatorErrors = 0,
			validatorRejections = 0,
			lateAnswers = 1,
			heldBytes = 40,
			unresolvedMessages = 0,
		}, "a player's totals, not per definition")
	end,

	["a name has one slot"] = function()
		local counters = Counters.new()
		local first = Counters.slot(counters, "facts.malformed")
		Check.expectEqual(Counters.slot(counters, "rowsDeferred"), first + 1, "a new name")
		Check.expectEqual(Counters.slot(counters, "facts.malformed"), first, "the same name")
	end,

	["snapshots are frozen through"] = function()
		local counters = Counters.new()
		Counters.add(counters, Counters.slot(counters, "bytesReceived.arena.chat"), nil, 1)

		local snapshot = Counters.snapshot(counters)
		Check.expect(table.isfrozen(snapshot), "the snapshot")
		Check.expect(table.isfrozen(snapshot.facts), "facts")
		Check.expect(table.isfrozen(snapshot.definitions), "definitions")
		Check.expect(table.isfrozen(snapshot.definitions["arena.chat"]), "a definition")
	end,

	["forget frees a player's counters and keeps the totals"] = function()
		local counters = Counters.new()
		local alice = twoPlayers()
		local slot = Counters.slot(counters, "validatorRejections")
		Counters.add(counters, slot, alice, 2)
		Counters.forget(counters, alice)

		Check.expectEqual((counters :: any).valuesByPlayer[alice], nil, "freed")
		Check.expectEqual(Counters.snapshot(counters, alice).validatorRejections, 0, "the player's")
		Check.expectEqual(Counters.snapshot(counters).validatorRejections, 2, "the side's")
	end,
}
