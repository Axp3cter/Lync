--!strict
-- Lync v5 compression probe, client half. Put this LocalScript in
-- StarterPlayer.StarterPlayerScripts. It acks unreliable probes, relays overflow
-- messages seen on the client, samples Stats.DataReceiveKbps on request, and runs a
-- small client->server ruler at the end.

local LogService = game:GetService("LogService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")

local folder = ReplicatedStorage:WaitForChild("LyncProbe")
local ctl = folder:WaitForChild("Ctl") :: RemoteEvent
local rel = folder:WaitForChild("R") :: RemoteEvent
local unrel = folder:WaitForChild("U") :: UnreliableRemoteEvent
local Samples = require(ReplicatedStorage:WaitForChild("Samples")) :: any

local pending: { number? } = {}
local relaying = true

LogService.MessageOut:Connect(function(text: string, _kind: Enum.MessageType)
	local lower = string.lower(text)
	if string.find(text, "[LyncProbe]", 1, true) then
		return
	end
	if string.find(lower, "went over", 1, true) or string.find(lower, "payload", 1, true) then
		local n = string.match(text, "went over by:?%s*(%d+)") or string.match(text, "(%d+)%s*bytes")
		table.insert(pending, if n then tonumber(n) else -1)
		if relaying then
			ctl:FireServer("warn", text)
		end
	end
end)

unrel.OnClientEvent:Connect(function(tag: any, ...)
	if typeof(tag) == "buffer" and buffer.len(tag) == 4 then
		ctl:FireServer("ack", buffer.readu32(tag, 0))
	end
end)

rel.OnClientEvent:Connect(function(...) end)

local function randomBuffer(n: number, seed: number): buffer
	local r = Random.new(seed)
	local b = buffer.create(n)
	for i = 0, n - 1 do
		buffer.writeu8(b, i, r:NextInteger(0, 255))
	end
	return b
end

local function fromHex(hex: string): buffer
	local n = #hex // 2
	local b = buffer.create(n)
	for i = 0, n - 1 do
		buffer.writeu8(b, i, tonumber(string.sub(hex, 2 * i + 1, 2 * i + 2), 16) :: number)
	end
	return b
end

local function clientRuler(): { [string]: any }
	relaying = false
	local PAD = randomBuffer(1100, 98)
	local tag = buffer.create(4)
	local function fire(x: any): number?
		table.clear(pending)
		unrel:FireServer(tag, x, PAD)
		local t = os.clock()
		while os.clock() - t < 1.5 do
			if #pending > 0 then
				local n = pending[1]
				return if n == -1 then nil else n
			end
			task.wait()
		end
		return nil
	end
	local base = fire(buffer.create(0))
	local out: { [string]: any } = { base = base }
	if base == nil then
		out.note = "no byte count in client-side overflow messages"
		relaying = true
		return out
	end
	local function rel0(x: any): number?
		local n = fire(x)
		return if n then n - base else nil
	end
	out.zeros64 = rel0(buffer.create(64))
	out.zeros99 = rel0(buffer.create(99))
	out.zeros100 = rel0(buffer.create(100))
	out.zeros128 = rel0(buffer.create(128))
	out.random128 = rel0(randomBuffer(128, 5))
	out.zeros800 = rel0(buffer.create(800))
	out.samples = {}
	for i = 1, math.min(4, #Samples) do
		local s = Samples[i]
		table.insert(out.samples, { name = s.name, wire = rel0(fromHex(s.hex)) })
	end
	relaying = true
	return out
end

ctl.OnClientEvent:Connect(function(kind: string, a: any)
	if kind == "sampleKbps" then
		task.spawn(function()
			local t = os.clock()
			while os.clock() - t < (a :: number) do
				ctl:FireServer("kbps", Stats.DataReceiveKbps)
				task.wait(0.25)
			end
		end)
	elseif kind == "runClientRuler" then
		task.spawn(function()
			ctl:FireServer("results", clientRuler())
		end)
	end
end)

ctl:FireServer("ready")
