--!strict
local Lync = require("./lync")
local t = Lync.types
return Lync.schema("arena", {
	chat = Lync.event({ from = "client", data = t.string(200), rate = 5 }),
	strike = Lync.event({
		from = "client",
		lane = "unreliable",
		data = { target = t.int(1, 64), aim = t.vector3() },
	}),
	announce = Lync.event({
		from = "server",
		data = t.union({
			round = { number = t.int(1, 99) },
			winner = { team = t.enum({ "red", "blue" }) },
		}),
	}),
	ping = Lync.event({ from = "server" }),
	buy = Lync.request({
		from = "client",
		data = { item = t.enum({ "sword", "shield" }) },
		reply = t.int(0, 100_000),
		timeout = 10,
	}),
	fighters = Lync.collection({
		key = t.int(),
		data = {
			name = t.string(20),
			health = t.int(0, 100),
			position = t.vector3(-2048, 2048, 1 / 32):newest(),
			title = t.optional(t.string(16)),
			nested = t.array(t.int(0, 3):newest(), 4), -- marker where it means nothing: accepted?
		},
	}),
})
