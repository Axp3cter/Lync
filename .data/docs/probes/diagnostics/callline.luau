-- Which line does debug.info(2, "l") report for a multi-line constructor call?
local t = {}
function t.int(min, max) return { min = min, max = max, line = debug.info(2, "l") } end
local Lync = {}
function Lync.event(options) options.line = debug.info(2, "l") return options end
local schema = {
	chat = Lync.event({          -- line 7
		from = "client",
		data = {
			count = t.int(          -- line 10
				10,
				1
			),
		},
	}),                          -- line 15
}
print("event recorded line", schema.chat.line)
print("t.int recorded line", schema.chat.data.count.line)
