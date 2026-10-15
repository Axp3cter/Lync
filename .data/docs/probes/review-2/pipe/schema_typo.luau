--!strict
-- The draft-2 §3.4 schema, plus a server-sent request (§3.5 "Requests go both ways").
local Lync = require("./lync")
local t = Lync.types
return Lync.schema("arena", {
	chat = Lync.event({ from = "client", data = t.string(200), limit = { perSecond = 5, burst = 5 } }),
	strike = Lync.event({
		from = "client",
		lane = "unreliable",
		data = { target = t.int(1, 2 ^ 40), aim = t.vector3f32() },
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
	confirm = Lync.request({ from = "server", data = t.string(40), reply = t.bol() -- typo on purpose }),
	fighters = Lync.collection({
		key = t.int(1, 2 ^ 40),
		maxRecords = 64,
		data = {
			name = t.string(20),
			health = t.int(0, 100),
			position = t.vector3(-2048, 2048, 1 / 32):newest(),
			look = t.rotation(9):newest(),
			title = t.optional(t.string(16)),
		},
	}),
	round = Lync.collection({ -- no key: a singleton
		data = { endsAt = t.int(0, 2 ^ 31), phase = t.enum({ "lobby", "play" }) },
	}),
})
