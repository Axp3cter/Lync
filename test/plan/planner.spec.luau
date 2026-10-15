--!strict

--[=[
	planner.spec

	The arena schema of v5.md §3.4 planned into ids, widths and worst-case sizes, and every
	declaration error the planner raises, asserted by code, position and path.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Check = require("../support/check")
local Lync = require("../../src")

-- Constants ---------------------------------------------------------------------------------------

const SOURCE = debug.info(1, "s")

local t = Lync.types

-- Private -----------------------------------------------------------------------------------------

local function at(line: number): string
	return `{SOURCE}:{line}`
end

local function arena()
	return Lync.schema("arena", {
		chat = Lync.event({
			from = "client",
			data = t.string(200),
			limit = { perSecond = 5, burst = 5 },
		}),
		strike = Lync.event({
			from = "client",
			lane = "unreliable",
			data = { target = t.int(1, 2 ^ 40), aim = t.direction(11) },
		}),
		announce = Lync.event({
			from = "server",
			data = t.union({
				round = { number = t.int(1, 99) },
				winner = { team = t.enum({ "red", "blue" }) },
			}),
		}),
		buy = Lync.request({
			from = "client",
			data = { item = t.enum({ "sword", "shield" }) },
			reply = t.int(0, 100_000),
			timeout = 10,
		}),
		fighters = Lync.collection({
			key = t.int(1, 2 ^ 40),
			maxRecords = 64,
			data = {
				name = t.string(20),
				team = t.enum({ "red", "blue" }),
				health = t.int(0, 100),
				position = t.vector3(-2048, 2048, 1 / 32):newest(),
				look = t.rotation(9):newest(),
				title = t.optional(t.string(16)),
			},
		}),
		round = Lync.collection({
			data = { endsAt = t.int(0, 2 ^ 31), phase = t.enum({ "lobby", "play" }) },
		}),
	})
end

local function idsOf(entries: { any }): { string }
	local ids = {}
	for i, entry in entries do
		Check.expectEqual(entry.id, i - 1, `id of entry {i}`)
		ids[i] = `{entry.definition.name} {entry.role}`
	end

	return ids
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["arena: id spaces and widths (v5.md §4.6, §4.10)"] = function()
		local ir = arena().ir

		Check.expectEqual(idsOf(ir.up), { "buy ask", "chat event", "strike event" })
		Check.expectEqual(idsOf(ir.down), { "announce event", "buy answer" })
		Check.expectEqual(ir.collections[1].name, "fighters")
		Check.expectEqual(ir.collections[2].name, "round")
		Check.expectEqual(#ir.collections, 2)
		Check.expectEqual({ ir.upWidth, ir.downWidth, ir.collectionWidth }, { 2, 1, 1 })
	end,

	["arena: definitions in name order with resolved options"] = function()
		local ir = arena().ir
		local names = {}
		for i, definition in ir.definitions do
			names[i] = definition.name
		end

		Check.expectEqual(names, { "announce", "buy", "chat", "fighters", "round", "strike" })
		Check.expectEqual(ir.byName.strike.lane, "unreliable")
		Check.expectEqual(ir.byName.chat.limit, { perSecond = 5, burst = 5 })
		Check.expectEqual(ir.byName.buy.timeout, 10)
		Check.expectEqual(ir.byName.fighters.from, "server")
		Check.expectEqual(ir.byName.fighters.maxRecords, 64)
		Check.expectEqual(ir.byName.round.maxRecords, 1024)
		Check.expectEqual(ir.byName.round.priority, 1)
		Check.expect(ir.byName.round.key == nil, "round must have no key")
	end,

	["arena: worst-case sizes of chat, strike and fighters"] = function()
		local ir = arena().ir

		-- chat: a length of u(ceil(log2 201)) = 8 bits, and up to 200 tail bytes.
		Check.expectEqual(ir.byName.chat.dataMaxBits, 8)
		Check.expectEqual(ir.byName.chat.dataMaxTail, 200)

		-- strike: aim 2 x 11 bits, target u(ceil(log2 2^40)) = 40 bits.
		Check.expectEqual(ir.byName.strike.dataMaxBits, 62)
		Check.expectEqual(ir.byName.strike.dataMaxTail, 0)

		-- fighters: health 7, look 1 + 2 + 3 x 9 = 30, name 5, position 3 x 18, team 1,
		-- title 1 + 5; tail name 20 + title 16.
		Check.expectEqual(ir.byName.fighters.dataMaxBits, 103)
		Check.expectEqual(ir.byName.fighters.dataMaxTail, 36)
	end,

	["arena: record fields in name order, :newest() kept on the field"] = function()
		local data = arena().ir.byName.fighters.data :: any
		local fields = {}
		for i, field in data.fields do
			fields[i] = `{field.name} {field.codec.kind} {field.newest}`
		end

		Check.expectEqual(fields, {
			"health int false",
			"look rotation true",
			"name string false",
			"position vector3 true",
			"team enum false",
			"title optional false",
		})
	end,

	["arena: widths of codecs"] = function()
		local ir = arena().ir
		local announce = ir.byName.announce.data :: any
		local position = (ir.byName.fighters.data :: any).fields[4].codec

		Check.expectEqual(announce.width, 1)
		Check.expectEqual(announce.byName, { round = 0, winner = 1 })
		Check.expectEqual(position.axis.steps, 131_072)
		Check.expectEqual(position.axis.width, 18)
		Check.expectEqual((ir.byName.buy.reply :: any).width, 17)
	end,

	["arena: the IR is frozen"] = function()
		local ir = arena().ir

		Check.expect(table.isfrozen(ir), "the namespace must be frozen")
		Check.expect(table.isfrozen(ir.up[1]), "an entry must be frozen")
		Check.expect(table.isfrozen(ir.byName.fighters.data :: any), "a codec must be frozen")
	end,

	["hasInstances: data or reply holding a t.instance"] = function()
		local ir = Lync.schema("instances", {
			pick = Lync.event({
				from = "client",
				data = { target = t.optional(t.instance("Part")) },
			}),
			ping = Lync.event({ from = "client", data = t.bool() }),
		}).ir

		Check.expect(ir.byName.pick.hasInstances, "pick must have instances")
		Check.expect(not ir.byName.ping.hasInstances, "ping must have no instances")
	end,

	["unknownOption: a misspelled option, at the definition's line"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				chat = Lync.event({ from = "client", rtae = 5 }),
			})
		end, { code = "unknownOption", at = at(line + 3), subject = "arena.chat" })
	end,

	["unknownOption: limit on a server-sent definition"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				announce = Lync.event({ from = "server", limit = { perSecond = 5 } }),
			})
		end, { code = "unknownOption", at = at(line + 3), subject = "arena.announce" })
	end,

	["unknownOption: a misspelled limit field"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				chat = Lync.event({ from = "client", limit = { perSecond = 5, brust = 5 } }),
			})
		end, { code = "unknownOption", at = at(line + 3), subject = "arena.chat" })
	end,

	["missingOption: an event without from"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				chat = Lync.event({ data = t.string(200) }),
			})
		end, { code = "missingOption", at = at(line + 3), subject = "arena.chat" })
	end,

	["notACodec: a record field that is not a codec, with its path"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				strike = Lync.event({
					from = "client",
					data = { target = t.int(1, 10), aim = 5 },
				}),
			})
		end, { code = "notACodec", at = at(line + 3), subject = "arena.strike", path = "data.aim" })
	end,

	["notACodec: a nested record inside an array, at the array's line"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				hits = Lync.event({
					from = "client",
					data = t.array({ at = "now" }, 4),
				}),
			})
		end, { code = "notACodec", at = at(line + 5), subject = "arena.hits", path = "data[].at" })
	end,

	["notACodec: a collection whose data is not a record"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				score = Lync.collection({ data = t.int(0, 10) }),
			})
		end, { code = "notACodec", at = at(line + 3), subject = "arena.score", path = "data" })
	end,

	["paramRange: an option out of range"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				buy = Lync.request({ from = "client", timeout = 500 }),
			})
		end, { code = "paramRange", at = at(line + 3), subject = "arena.buy", path = "timeout" })
	end,

	["paramRange: from that is neither client nor server"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				chat = Lync.event({ from = "clinet" }),
			})
		end, { code = "paramRange", at = at(line + 3), subject = "arena.chat", path = "from" })
	end,

	["paramRange: limit.burst out of range"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				chat = Lync.event({ from = "client", limit = { perSecond = 5, burst = 0 } }),
			})
		end, {
			code = "paramRange",
			at = at(line + 3),
			subject = "arena.chat",
			path = "limit.burst",
		})
	end,

	["paramRange: a schema entry that is not a definition, at the schema's line"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				chat = t.string(200),
			})
		end, { code = "paramRange", at = at(line + 2), subject = "arena.chat" })
	end,

	["mapKey: a collection key that is not an integer, list enum or string"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				flags = Lync.collection({ key = t.bool(), data = {} }),
			})
		end, { code = "mapKey", at = at(line + 3), subject = "arena.flags", path = "key" })
	end,

	["newestPlacement: :newest() in an event, at the codec's line"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				move = Lync.event({
					from = "client",
					data = {
						position = t.vector3(-10, 10, 0.5):newest(),
					},
				}),
			})
		end, {
			code = "newestPlacement",
			at = at(line + 6),
			subject = "arena.move",
			path = "data.position",
		})
	end,

	["newestPlacement: :newest() below a collection's top-level fields"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				units = Lync.collection({
					data = { state = { hp = t.int(0, 9):newest() } },
				}),
			})
		end, {
			code = "newestPlacement",
			at = at(line + 4),
			subject = "arena.units",
			path = "data.state.hp",
		})
	end,

	["newestWidth: :newest() on a variable-width codec"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				units = Lync.collection({
					data = { label = t.string(8):newest() },
				}),
			})
		end, {
			code = "newestWidth",
			at = at(line + 4),
			subject = "arena.units",
			path = "data.label",
		})
	end,

	["unionKindField: a variant with its own kind field, at the union's line"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				announce = Lync.event({
					from = "server",
					data = t.union({
						round = { kind = t.int(0, 3) },
					}),
				}),
			})
		end, {
			code = "unionKindField",
			at = at(line + 5),
			subject = "arena.announce",
			path = "data.round",
		})
	end,

	["nameLength: an empty namespace name, at the schema's line"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("", {})
		end, { code = "nameLength", at = at(line + 2) })
	end,

	["nameLength: a namespace name over 64 bytes"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema(string.rep("a", 65), {})
		end, { code = "nameLength", at = at(line + 2) })
	end,

	["nameLength: a record field named by a number"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				list = Lync.event({ from = "client", data = { t.bool() } }),
			})
		end, { code = "nameLength", at = at(line + 3), subject = "arena.list", path = "data" })
	end,

	["messageTooLarge: a reliable message over 16,000 bytes"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				dump = Lync.event({ from = "server", data = t.array(t.string(1000), 100) }),
			})
		end, { code = "messageTooLarge", at = at(line + 3), subject = "arena.dump", path = "data" })
	end,

	["messageTooLarge: a request reply over 16,000 bytes"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(
			function()
				Lync.schema("arena", {
					fetch = Lync.request({ from = "client", reply = t.buffer(16_000) }),
				})
			end,
			{ code = "messageTooLarge", at = at(line + 3), subject = "arena.fetch", path = "reply" }
		)
	end,

	["messageTooLarge: a message of exactly 16,000 bytes plans"] = function()
		local ir = Lync.schema("arena", {
			dump = Lync.event({ from = "server", data = t.array(t.f64(), 1999) }),
		}).ir

		-- u(ceil(log2 2000)) = 11 bits of count and 1999 x 64 bits: 15,993.4 bytes.
		Check.expectEqual(ir.byName.dump.dataMaxBits, 11 + 1999 * 64)
	end,

	["unreliableTooLarge: an unreliable event over 960 bytes"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.schema("arena", {
				shout = Lync.event({ from = "client", lane = "unreliable", data = t.string(1000) }),
			})
		end, {
			code = "unreliableTooLarge",
			at = at(line + 3),
			subject = "arena.shout",
			path = "data",
		})
	end,
}
