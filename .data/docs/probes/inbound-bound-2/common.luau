--!nocheck
-- A milestone server runtime with no Roblox host (as probes/inbound-budgets/decode_shapes.luau assembles it), and
-- the frame helpers shared by the probes. Takes the src modules so the builder (srcA) and the timing probes (src)
-- each pass their own copy.

return function(M, schemaIr)
	local Bits, Ints, Run, Frame, Tag = M.Bits, M.Ints, M.Run, M.Frame, M.Tag
	local Connection, Handshake, Counters, Console, Facts = M.Connection, M.Handshake, M.Counters, M.Console, M.Facts
	local Column = M.Column

	local HUGE = { perSecond = 1e12, burst = 1e12 }
	local host = {
		side = "server",
		now = os.clock,
		clock = os.clock,
		entropy32 = function() return math.random(0, 2 ^ 31 - 1) end,
		spawn = function() end,
		report = function(m) error("report: " .. tostring(m)) end,
		warn = function() end,
		players = function() return {} end,
	}
	local counters = Counters.new()
	local console = Console.new(host)
	local facts = Facts.new(host, console, counters)
	local rt = {
		side = "server",
		host = host,
		config = {
			stateRate = 20, stateBudget = 16000, stateFloor = 0.25,
			reliableFrames = HUGE, reliableBytes = HUGE, unreliableFrames = HUGE, unreliableBytes = HUGE, elements = HUGE,
			cover = 16384, window = 30, perPlayerEvents = 16, serverEvents = 256, console = false, profile = false,
		},
		facts = facts, counters = counters, console = console,
		namespaces = {}, namespaceByIndex = {}, permutationSeed = 0, epoch = 0, stateRate = 20,
		connections = {}, knownPlayers = {}, pending = {}, mode = "automatic",
		decodeReportedAt = -math.huge, validatorThread = nil, validatorState = { isRunning = false },
		answer = function() end, control = function() end, slotByName = {}, disconnects = {},
	}
	local namespace = Handshake.load(rt, schemaIr)
	local player = { Name = "p1" }
	local conn = Connection.new(rt, player)
	conn.key = Connection.key(0x03020100, 0x07060504)
	conn.cover = 16384
	conn.isWelcomed = true
	conn.hasTagged = true
	conn.welcomed[namespace.index] = true
	rt.connections[player] = conn
	rt.knownPlayers[player] = true

	local wireOf = {}
	for wire, canonical in namespace.readIds do
		local entry = schemaIr.up[canonical + 1]
		wireOf[entry.definition.name] = wire - 1
	end

	-- One run chunk of `count` messages of definition `name` (as the client's outbox writes it, §4.1).
	local function chunkOf(name, values, count)
		local w = Bits.writer()
		Bits.write(w, schemaIr.upWidth, wireOf[name])
		Ints.writeEg(w, count - 1, 0)
		local definition = namespace.definitions[name]
		local ir = definition.ir
		local codec = ir.data
		local instances = { list = {}, index = {}, count = 0 }
		if codec ~= nil then
			Run.collect(codec, values, count, instances)
			if ir.hasInstances then
				Ints.writeEg(w, #instances.list, 0)
			end
			Run.encode(w, codec, values, count, instances, "bench." .. name .. ":fire", "data")
		elseif ir.hasInstances then
			Ints.writeEg(w, 0, 0)
		end
		return Frame.chunk(namespace.index, 2, w, instances.list)
	end

	return {
		rt = rt, host = host, counters = counters, namespace = namespace, player = player, conn = conn,
		wireOf = wireOf, chunkOf = chunkOf, HUGE = HUGE, Column = Column,
	}
end
