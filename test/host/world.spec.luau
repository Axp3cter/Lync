--!strict

--[=[
	world.spec

	The simulated world (m2-plan.md §2, §6.1) driven through a stub endpoint with
	`Runtime.new`'s and `Runtime.observe`'s signatures: it opens its transport, records every
	frame it receives, refuses calls that are not one buffer plus at most an instance array as
	`malformed` rule 1 (the shape step of v5.md §6.1), and sweeps its facts every step. Unit F
	puts the real runtime in its place.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Check = require("../support/check")
local Console = require("../../src/diag/console")
local Facts = require("../../src/diag/facts")
local Host = require("../../src/host/host")
local World = require("../support/world")

-- Types -------------------------------------------------------------------------------------------

type Received = { at: number, player: Player?, lane: number, bytes: number, first: number }

type Stub = {
	host: Host.Host,
	facts: Facts.State,
	received: { Received },
	options: any?,
	stepCount: number,
}

-- Constants ---------------------------------------------------------------------------------------

const RELIABLE = 0
const UNRELIABLE = 1

const STEADY = table.freeze({
	jitter = 0,
	loss = 0,
	stall = table.freeze({ chance = 0, seconds = 0 }),
})

-- Private -----------------------------------------------------------------------------------------

local function isShaped(count: number, frame: unknown, instances: unknown): boolean
	if count < 1 or count > 2 or typeof(frame) ~= "buffer" then
		return false
	end

	return instances == nil or typeof(instances) == "table"
end

local StubEndpoint = {}

function StubEndpoint.new(_side: "server" | "client", host: Host.Host, options: any?): Stub
	local stub: Stub = {
		host = host,
		facts = Facts.new(host, Console.new(host)),
		received = {},
		options = options,
		stepCount = 0,
	}

	host.transport.onReceive(function(player: Player?, lane: Host.Lane, ...: unknown)
		local frame, instances = ...
		if not isShaped(select("#", ...), frame, instances) then
			Facts.record(stub.facts, "malformed", player, nil, nil, lane, 1)
			return
		end

		local bytes = frame :: buffer
		table.insert(stub.received, {
			at = host.clock(),
			player = player,
			lane = lane,
			bytes = buffer.len(bytes),
			first = buffer.readu8(bytes, 0),
		})
	end)
	host.transport.open()
	host.onStep(function()
		stub.stepCount += 1
		Facts.sweep(stub.facts, host.clock())
	end)

	return stub
end

function StubEndpoint.observe(stub: Stub, notify: (fact: Facts.Fact) -> ()): Host.Connection
	return Facts.observe(stub.facts, notify)
end

local function frameOf(first: number, length: number?): buffer
	local frame = buffer.create(length or 4)
	buffer.writeu8(frame, 0, first)
	return frame
end

local function worldOf(seed: number, net: { [string]: any }?): World.World
	return World.new({ seed = seed, endpoint = StubEndpoint, net = net })
end

local function firstsOf(received: { Received }, lane: number): { number }
	local firsts = {}
	for _, frame in received do
		if frame.lane == lane then
			table.insert(firsts, frame.first)
		end
	end

	return firsts
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["frames arrive after the latency, both ways, on both lanes"] = function()
		local world = worldOf(1, STEADY)
		local client = world:join()
		world:step(0.5)

		for _, lane in { RELIABLE, UNRELIABLE } do
			local sentAt = world.now
			client.host.transport.send(nil, lane, frameOf(lane + 1), nil)
			world.server.host.transport.send(client.player, lane, frameOf(lane + 3), nil)
			world:step(0.2)

			local up = world.server.runtime.received[lane + 1]
			local down = client.runtime.received[lane + 1]
			Check.expectEqual(up.player, client.player, "the sender reaches the server's handler")
			Check.expectEqual(up.first, lane + 1, "the frame up")
			Check.expectEqual(down.player, nil, "a client's handler gets no player")
			Check.expectEqual(down.first, lane + 3, "the frame down")
			for _, received in { up, down } do
				local delay = received.at - sentAt
				Check.expect(delay >= 0.05 and delay < 0.05 + 1 / 60 + 1e-9, `delay {delay}`)
			end
		end

		world:expectQuiet()
	end,

	["reliable frames arrive in order through jitter and stalls"] = function()
		local world = worldOf(2, { jitter = 0.05, stall = { chance = 2, seconds = 0.3 } })
		local client = world:join()
		world:step(0.1)
		for i = 1, 600 do
			client.host.transport.send(nil, RELIABLE, frameOf(i % 256), nil)
			world:step(1 / 60)
		end
		world:step(2)

		local firsts = firstsOf(world.server.runtime.received, RELIABLE)
		Check.expectEqual(#firsts, 600, "every reliable frame arrives")
		for i, first in firsts do
			Check.expectEqual(first, i % 256, `frame {i}`)
		end
	end,

	["a broadcast is one call and reaches every client"] = function()
		local world = worldOf(3, STEADY)
		local clients = { world:join(), world:join(), world:join() }
		world:step(0.1)

		local callCount = #world.calls
		world.server.host.transport.broadcast(RELIABLE, frameOf(9), nil)
		world:step(0.2)

		Check.expectEqual(#world.calls, callCount + 1, "calls")
		Check.expectEqual(world.calls[#world.calls].kind, "broadcast", "the call's kind")
		for _, client in clients do
			Check.expectEqual(firstsOf(client.runtime.received, RELIABLE), { 9 }, "received")
		end
	end,

	["a frame is copied when sent"] = function()
		local world = worldOf(4, STEADY)
		local client = world:join()
		world:step(0.1)

		local frame = frameOf(1)
		client.host.transport.send(nil, RELIABLE, frame, nil)
		buffer.writeu8(frame, 0, 2)
		world:step(0.2)

		Check.expectEqual(firstsOf(world.server.runtime.received, RELIABLE), { 1 }, "received")
	end,

	["a call that is not one buffer is malformed, rule 1, for its sender only"] = function()
		local world = worldOf(5, STEADY)
		local honest = world:join()
		local attacker = world:join()
		world:step(0.1)

		honest.host.transport.send(nil, RELIABLE, frameOf(1), nil)
		world:raw(attacker, RELIABLE, "not a buffer")
		world:raw(attacker, UNRELIABLE, frameOf(1), frameOf(2))
		world:step(0.2)

		world:expectFact(world.server, {
			reason = "malformed",
			player = attacker.player,
			count = 1,
			evidence = { lane = RELIABLE, rule = 1 },
		})
		world:expectFact(world.server, {
			reason = "malformed",
			player = attacker.player,
			count = 1,
			evidence = { lane = UNRELIABLE, rule = 1 },
		})
		Check.expectEqual(#world:claimLines(world.server, "malformed"), 1, "console lines")
		Check.expectEqual(#world.server.runtime.received, 1, "the honest frame arrives")
		world:expectQuiet()
	end,

	["unclaimed output fails expectQuiet"] = function()
		local world = worldOf(6, STEADY)
		local attacker = world:join()
		world:step(0.1)
		world:raw(attacker, RELIABLE, {})
		world:step(0.2)

		local isQuiet = pcall(function()
			world:expectQuiet()
		end)
		Check.expect(not isQuiet, "an unclaimed fact and line must fail")
	end,

	["virtual time is deterministic for a given seed"] = function()
		local function trace(seed: number): string
			local world = worldOf(seed, { duplicate = 0.05, stall = { chance = 0.5, seconds = 0.3 } })
			local clients = { world:join(), world:join() }
			local parts = {}
			for step = 1, 300 do
				for i, client in clients do
					client.host.transport.send(nil, step % 2, frameOf(step % 256, 4 + i), nil)
				end
				world.server.host.transport.broadcast(UNRELIABLE, frameOf(step % 256), nil)
				world:step(1 / 60)
			end
			world:step(1)

			for _, peer in { world.server, clients[1], clients[2] } do
				for _, received in peer.runtime.received do
					local userId = if received.player == nil then 0 else received.player.UserId
					table.insert(parts, `{received.at}:{userId}:{received.lane}:{received.first}`)
				end
			end

			return table.concat(parts, ",")
		end

		Check.expect(trace(11) == trace(11), "equal seeds must give equal worlds")
		Check.expect(trace(11) ~= trace(12), "other seeds must give other worlds")
	end,

	["each side steps at its own rate"] = function()
		local world = worldOf(7, { fps = 240 })
		local fast = world:join()
		local slow = world:join({ net = { fps = 30 } })
		world:step(1)

		Check.expectEqual(world.server.runtime.stepCount, 60, "server steps")
		Check.expectEqual(fast.runtime.stepCount, 240, "240 Hz client steps")
		Check.expectEqual(slow.runtime.stepCount, 30, "30 Hz client steps")
	end,

	["joining and leaving reach the server's roster, and a leaver's frames are dropped"] = function()
		local world = World.new({ seed = 8, net = STEADY })
		local server = world.server.host
		local added: { Player } = {}
		local removing: { Player } = {}
		server.onPlayerAdded(function(player: Player)
			table.insert(added, player)
		end)
		server.onPlayerRemoving(function(player: Player)
			table.insert(removing, player)
			Check.expect(table.find(server.players(), player) ~= nil, "a leaver is listed while leaving")
		end)
		local received = 0
		server.transport.onReceive(function()
			received += 1
		end)
		server.transport.open()

		local client = world:join({ name = "Leaver" })
		client.host.transport.open()
		Check.expectEqual(added, { client.player }, "added")
		Check.expectEqual((client.player :: Player).Name, "Leaver", "name")
		Check.expectEqual(client.host.localPlayer, client.player, "localPlayer")

		client.host.transport.send(nil, RELIABLE, frameOf(1), nil)
		world:leave(client)
		world:step(1)

		Check.expectEqual(removing, { client.player }, "removing")
		Check.expectEqual(#server.players(), 0, "roster")
		Check.expectEqual(received, 0, "frames in flight from a leaver")
	end,

	["a client is ready once both transports are open"] = function()
		local world = World.new({ seed = 9 })
		local client = world:join()
		client.host.transport.open()
		Check.expect(not client.host.transport.ready(), "the server has not opened")
		world.server.host.transport.open()
		Check.expect(client.host.transport.ready(), "both are open")
	end,

	["spawn runs at once, and a raise in it is a native report"] = function()
		local world = World.new({ seed = 10 })
		local host = world.server.host
		local ran = false
		host.spawn(function(value: boolean)
			ran = value
		end, true)
		host.spawn(function()
			error("observer failed", 0)
		end)
		host.report("[Lync] decoderRaised: test")

		Check.expect(ran, "spawn must run the function at once")
		Check.expectEqual(world:claimReports(world.server, "observer failed"), 1, "the raise")
		Check.expectEqual(world:claimReports(world.server, "[Lync] decoderRaised:"), 1, "the report")
		world:expectQuiet()
	end,

	["Kick only records the call"] = function()
		local world = World.new({ seed = 11 })
		local client = world:join()
		local player = client.player :: Player
		player:Kick("bye")

		Check.expectEqual(#world.kicks, 1, "kicks")
		Check.expectEqual(world.kicks[1].player, player, "kicked player")
		Check.expect(table.isfrozen(player :: any), "players are frozen")
	end,

	["the runtimes get their pins and the hosts their clocks"] = function()
		local pin = { permutationSeed = 0 }
		local world = World.new({ seed = 12, endpoint = StubEndpoint, pin = pin })
		local client = world:join({ pin = pin })
		world:step(2)

		Check.expectEqual(world.server.runtime.options.pin, pin, "server pin")
		Check.expectEqual(client.runtime.options.pin, pin, "client pin")
		Check.expectEqual(world.server.host.clock(), 2, "clock")
		Check.expect(world.server.host.now() > world.server.host.clock(), "now is server time")

		local entropy = world.server.host.entropy32()
		Check.expect(entropy >= 0 and entropy < 2 ^ 32 and entropy % 1 == 0, "entropy is a u32")
	end,
}
