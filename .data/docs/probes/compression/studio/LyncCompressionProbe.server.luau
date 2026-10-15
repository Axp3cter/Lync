--!strict
-- Lync v5 compression probe, server half. Put this Script in ServerScriptService, the
-- LocalScript in StarterPlayer.StarterPlayerScripts, Samples in ReplicatedStorage.
-- Start a local server with 1 player (Test > Clients and Servers). The report prints
-- to the server Output between "LYNC PROBE REPORT BEGIN" and "LYNC PROBE REPORT END".
--
-- What it settles (see README.md):
--   T1 the ruler: on-wire size of a buffer argument, from the unreliable overflow
--      message ("went over by N bytes") or, if no number is printed, from delivery
--   T2 the compression threshold, and whether incompressible buffers fall back to raw
--   T3 the zstd level (fingerprint against EncodingService:CompressBuffer) and dictionary
--   T4 per-argument or whole-call compression (identical twin buffers), strings, tables
--   T5 cross-call and cross-frame context (Stats bandwidth with repeated buffers)
--   T6 reliable lane threshold (Stats bandwidth around the threshold)
--   T7 whether the 1000 B unreliable limit is counted after compression

local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local Samples = require(ReplicatedStorage:WaitForChild("Samples")) :: any

-- Set to true if the first run shows many null sizes (overflow messages throttled or
-- missing): every size is then measured by delivery binary search instead (slower).
local FORCE_DELIVERY = false

------------------------------------------------------------------------------
-- remotes
------------------------------------------------------------------------------
local folder = Instance.new("Folder")
folder.Name = "LyncProbe"
local ctl = Instance.new("RemoteEvent")
ctl.Name = "Ctl"
ctl.Parent = folder
local rel = Instance.new("RemoteEvent")
rel.Name = "R"
rel.Parent = folder
local unrel = Instance.new("UnreliableRemoteEvent")
unrel.Name = "U"
unrel.Parent = folder
folder.Parent = ReplicatedStorage

------------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------------
local rng = Random.new(20261015)

local function randomBuffer(n: number, seed: number?): buffer
	local r = if seed then Random.new(seed) else rng
	local b = buffer.create(n)
	for i = 0, n - 1 do
		buffer.writeu8(b, i, r:NextInteger(0, 255))
	end
	return b
end

local function zeroBuffer(n: number): buffer
	return buffer.create(n)
end

local function fromHex(hex: string): buffer
	local n = #hex // 2
	local b = buffer.create(n)
	for i = 0, n - 1 do
		buffer.writeu8(b, i, tonumber(string.sub(hex, 2 * i + 1, 2 * i + 2), 16) :: number)
	end
	return b
end

local function prefix(src: buffer, n: number): buffer
	local b = buffer.create(n)
	buffer.copy(b, 0, src, 0, n)
	return b
end

local report: { [string]: any } = {
	engineVersion = version(), -- deprecated global, still the simplest build stamp
	placeVersion = game.PlaceVersion,
	studio = RunService:IsStudio(),
	date = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	warnings = {},
	notes = {},
}
local function note(s: string)
	table.insert(report.notes, s)
	print("[LyncProbe] " .. s)
end

------------------------------------------------------------------------------
-- overflow message capture (server log, plus anything the client relays)
------------------------------------------------------------------------------
local pending: { { text: string, n: number? } } = {}
local seenTexts: { [string]: boolean } = {}

local function onLog(text: string)
	local lower = string.lower(text)
	if string.find(lower, "went over", 1, true) or string.find(lower, "payload", 1, true) then
		if string.find(text, "[LyncProbe]", 1, true) then
			return
		end
		local n = string.match(text, "went over by:?%s*(%d+)") or string.match(text, "(%d+)%s*bytes")
		table.insert(pending, { text = text, n = if n then tonumber(n) else nil })
		local key = string.gsub(text, "%d+", "#")
		if not seenTexts[key] and #report.warnings < 8 then
			seenTexts[key] = true
			table.insert(report.warnings, text)
		end
	end
end
LogService.MessageOut:Connect(function(text: string, _kind: Enum.MessageType)
	onLog(text)
end)

local acks: { [number]: boolean } = {}
local clientReady = false
local clientResults: any = nil
local clientKbps: { number } = {}
ctl.OnServerEvent:Connect(function(_player: Player, kind: string, a: any)
	if kind == "ready" then
		clientReady = true
	elseif kind == "ack" then
		acks[a :: number] = true
	elseif kind == "warn" then
		onLog(a :: string)
	elseif kind == "results" then
		clientResults = a
	elseif kind == "kbps" then
		table.insert(clientKbps, a :: number)
	end
end)

local player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()
local t0 = os.clock()
while not clientReady and os.clock() - t0 < 30 do
	task.wait(0.1)
end
assert(clientReady, "client LocalScript did not report ready within 30 s")
task.wait(2) -- let join traffic settle

------------------------------------------------------------------------------
-- T1: the ruler
------------------------------------------------------------------------------
local PAD = randomBuffer(1100, 99)
local tagCounter = 0
local function tagBuffer(): (buffer, number)
	tagCounter += 1
	local b = buffer.create(4)
	buffer.writeu32(b, 0, tagCounter)
	return b, tagCounter
end

-- fire (tag, x, pad) and wait for an overflow message; returns N or nil
local function fireWarn(x: any, pad: buffer): number?
	table.clear(pending)
	local tag = tagBuffer()
	unrel:FireClient(player, tag, x, pad)
	local t = os.clock()
	while os.clock() - t < 1.5 do
		if #pending > 0 then
			return pending[1].n
		end
		task.wait()
	end
	return nil
end

-- fire (tag, x, pad) and wait for the client's ack; true if delivered
local function fireDelivered(x: any, pad: buffer): boolean
	local tag, id = tagBuffer()
	unrel:FireClient(player, tag, x, pad)
	local t = os.clock()
	while os.clock() - t < 0.6 do
		if acks[id] then
			return true
		end
		task.wait()
	end
	return false
end

local mode = "warn"
local base: number? = nil

-- largest pad length that is still delivered alongside x (binary search)
local function maxPad(x: any): number
	local lo, hi = -1, 1100 -- lo delivered (or -1), hi not delivered
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		local ok = fireDelivered(x, prefix(PAD, math.max(mid, 0)))
		if not ok then
			ok = fireDelivered(x, prefix(PAD, math.max(mid, 0))) -- one retry
		end
		if ok then
			lo = mid
		else
			hi = mid
		end
	end
	return lo
end

-- on-wire size of x relative to an empty buffer argument
local function wire(x: any): number?
	if mode == "warn" then
		local n = fireWarn(x, PAD)
		if n == nil or base == nil then
			return nil
		end
		return n - (base :: number)
	else
		return (base :: number) - maxPad(x)
	end
end

do
	local n = if FORCE_DELIVERY then nil else fireWarn(buffer.create(0), PAD)
	if n then
		base = n
		note(`ruler: overflow message carries a byte count (empty-buffer baseline {n})`)
	else
		mode = "delivery"
		note("ruler: no byte count in any overflow message; falling back to delivery binary search (slow)")
		base = maxPad(buffer.create(0))
	end
	report.rulerMode = mode
	report.rulerBase = base
	-- check the ruler: a raw 50-byte random buffer should cost 50 (+0 or +1 for the length)
	report.rulerCheck50 = wire(randomBuffer(50))
end

------------------------------------------------------------------------------
-- T2: threshold and raw fallback
------------------------------------------------------------------------------
do
	local sizes = { 1, 2, 4, 8, 16, 32, 48, 64, 80, 90 }
	for L = 91, 110 do
		table.insert(sizes, L)
	end
	for _, L in { 120, 128, 160, 200, 256, 400, 800 } do
		table.insert(sizes, L)
	end
	if mode == "delivery" then
		sizes = { 8, 64, 96, 100, 104, 128, 256, 800 }
	end
	local rows = {}
	for _, L in sizes do
		local z = wire(zeroBuffer(L))
		local r = wire(randomBuffer(L))
		table.insert(rows, { L = L, zeros = z, random = r })
	end
	report.threshold = rows
	local first: number? = nil
	for _, row in rows do
		if row.zeros and row.zeros < row.L - 2 and first == nil then
			first = row.L
		end
	end
	report.thresholdFirstCompressed = first
	note(`T2 smallest zero-filled length that compressed: {first}`)
end

------------------------------------------------------------------------------
-- T3: level fingerprint and dictionary
------------------------------------------------------------------------------
do
	local LEVELS = { -7, -5, -3, -1, 0, 1, 2, 3, 4, 5, 6, 7, 9, 12, 19, 22 }
	local rows = {}
	for _, s in Samples do
		local b = fromHex(s.hex)
		local es: { [string]: number } = {}
		for _, lv in LEVELS do
			local ok, out = pcall(EncodingService.CompressBuffer, EncodingService, b, Enum.CompressionAlgorithm.Zstd, lv)
			if ok then
				es[tostring(lv)] = buffer.len(out)
			end
		end
		local py: { [string]: number } = {}
		for lv, n in s.py do
			py[tostring(lv)] = n
		end
		table.insert(rows, { name = s.name, len = buffer.len(b), wire = wire(b), encodingService = es, libzstd = py })
	end
	report.samples = rows
	-- fit: wire = len(CompressBuffer(level)) + c; the right level has zero spread in c
	local fit = {}
	for _, lv in LEVELS do
		local cs = {}
		for _, row in rows do
			local e = row.encodingService[tostring(lv)]
			if e and row.wire and row.wire < row.len then
				table.insert(cs, row.wire - e)
			end
		end
		if #cs > 0 then
			table.sort(cs)
			table.insert(fit, { level = lv, cMin = cs[1], cMax = cs[#cs], n = #cs })
		end
	end
	report.levelFit = fit
end

------------------------------------------------------------------------------
-- T4: per-argument vs whole-call, strings, tables
------------------------------------------------------------------------------
do
	local A = randomBuffer(400, 1)
	local B = randomBuffer(400, 2)
	local function wire2(x: any, y: any): number?
		if mode ~= "warn" then
			return nil
		end
		table.clear(pending)
		local tag = tagBuffer()
		unrel:FireClient(player, tag, x, y, PAD)
		local t = os.clock()
		while os.clock() - t < 1.5 do
			if #pending > 0 and pending[1].n then
				return (pending[1].n :: number) - (base :: number)
			end
			task.wait()
		end
		return nil
	end
	report.twins = {
		AB = wire2(A, B),
		AA = wire2(A, A),
		AcopyA = wire2(A, prefix(A, 400)),
	}
	local randomText = table.create(600)
	local r = Random.new(3)
	for i = 1, 600 do
		randomText[i] = string.char(r:NextInteger(33, 126))
	end
	report.strings = {
		aaa600 = wire(string.rep("a", 600)),
		random600 = wire(table.concat(randomText)),
		empty = wire(""),
	}
	report.tables = {
		zeros800InTable = wire({ zeroBuffer(800) }),
		emptyTable = wire({}),
		zeros800 = wire(zeroBuffer(800)),
	}
end

------------------------------------------------------------------------------
-- T7: is the 1000 B limit counted after compression?
------------------------------------------------------------------------------
do
	local function delivered(x: buffer): boolean
		local tag, id = tagBuffer()
		unrel:FireClient(player, tag, x)
		local t = os.clock()
		while os.clock() - t < 0.8 do
			if acks[id] then
				return true
			end
			task.wait()
		end
		return false
	end
	report.limit = {
		zeros4000 = delivered(zeroBuffer(4000)),
		zeros20000 = delivered(zeroBuffer(20000)),
		random980 = delivered(randomBuffer(980)),
		random990 = delivered(randomBuffer(990)),
		random1000 = delivered(randomBuffer(1000)),
	}
end

------------------------------------------------------------------------------
-- T5/T6: bandwidth scenarios (Stats), 60 Hz
------------------------------------------------------------------------------
local function measure(label: string, perFrame: ((number) -> ())?, seconds: number): { [string]: any }
	local conn = if perFrame then RunService.Heartbeat:Connect(perFrame) else nil
	task.wait(2) -- settle
	local samples = {}
	table.clear(clientKbps)
	ctl:FireClient(player, "sampleKbps", seconds)
	local t = os.clock()
	while os.clock() - t < seconds do
		table.insert(samples, Stats.DataSendKbps)
		task.wait(0.25)
	end
	if conn then
		conn:Disconnect()
	end
	task.wait(0.5)
	table.sort(samples)
	local cs = table.clone(clientKbps)
	table.sort(cs)
	local row = {
		label = label,
		serverSendMedian = samples[(#samples + 1) // 2],
		clientRecvMedian = cs[(#cs + 1) // 2],
	}
	print(`[LyncProbe] {label}: server send {row.serverSendMedian}, client recv {row.clientRecvMedian}`)
	return row
end

do
	local SEC = 6
	local fixed900 = randomBuffer(900, 11)
	local fixed450 = randomBuffer(450, 12)
	local fixed90 = randomBuffer(90, 13)
	local rows = {}
	table.insert(rows, measure("idle", nil, SEC))
	table.insert(rows, measure("R fresh random 900 B/frame", function()
		rel:FireClient(player, randomBuffer(900))
	end, SEC))
	table.insert(rows, measure("R same random 900 B every frame", function()
		rel:FireClient(player, fixed900)
	end, SEC))
	table.insert(rows, measure("R same random 450 B twice per frame", function()
		rel:FireClient(player, fixed450)
		rel:FireClient(player, fixed450)
	end, SEC))
	table.insert(rows, measure("R zeros 900 B/frame", function()
		rel:FireClient(player, zeroBuffer(900))
	end, SEC))
	table.insert(rows, measure("R fresh random 90 B/frame", function()
		rel:FireClient(player, randomBuffer(90))
	end, SEC))
	table.insert(rows, measure("R same random 90 B every frame", function()
		rel:FireClient(player, fixed90)
	end, SEC))
	table.insert(rows, measure("U fresh random 900 B/frame", function()
		unrel:FireClient(player, randomBuffer(900))
	end, SEC))
	table.insert(rows, measure("U same random 900 B every frame", function()
		unrel:FireClient(player, fixed900)
	end, SEC))
	for _, L in { 90, 99, 100, 101, 110 } do
		local z = zeroBuffer(L)
		table.insert(rows, measure(`R zeros {L} B/frame`, function()
			rel:FireClient(player, z)
		end, SEC))
	end
	local r100 = randomBuffer(100, 14)
	table.insert(rows, measure("R same random 100 B/frame", function()
		rel:FireClient(player, r100)
	end, SEC))
	report.bandwidth = rows
end

------------------------------------------------------------------------------
-- client->server ruler results and the report
------------------------------------------------------------------------------
ctl:FireClient(player, "runClientRuler")
local tc = os.clock()
while clientResults == nil and os.clock() - tc < 60 do
	task.wait(0.2)
end
report.clientToServer = clientResults

print("=== LYNC PROBE REPORT BEGIN ===")
print(HttpService:JSONEncode(report))
print("=== LYNC PROBE REPORT END ===")

-- short human summary
print(`[LyncProbe] ruler mode {mode}; threshold first compressed at {report.thresholdFirstCompressed} B`)
for _, f in report.levelFit do
	print(`[LyncProbe] level {f.level}: c in [{f.cMin}, {f.cMax}] over {f.n} samples`)
end
