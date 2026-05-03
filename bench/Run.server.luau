--!strict
--!optimize 2
-- Server: wire + delta + CPU + s2c throughput. Yields to client for c2s.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Harness = require(ReplicatedStorage.Lync.bench.Harness)
local Lync = require(ReplicatedStorage:WaitForChild("Lync"))
local Scenarios = require(ReplicatedStorage.Lync.bench.Scenarios)

local bench = Scenarios.bench

Lync.configure({ channelMaxSize = bench.channelMaxSize, stats = true })
Lync.start()

-- Wire size --------------------------------------------------------------

Harness.header("Wire Size (single fire, bytes)")
for _, c in Scenarios.wireCases do
    Harness.wireSize(c.label, c.codec, c.value)
end

-- Delta wire size --------------------------------------------------------

Harness.header("Delta Wire Size (per-codec, bytes)")
for _, c in Scenarios.deltaCases do
    Harness.deltaSize(c.label, c.codec, c.seed, c.value)
end

-- CPU round-trip ---------------------------------------------------------

Harness.header("Codec Round-Trip (CPU, 1000 iters)")
for _, c in Scenarios.roundTripCases do
    Harness.roundTrip(c.label, c.codec, c.value)
end

-- Wait for client --------------------------------------------------------

local players = Players:GetPlayers()
local player = if #players > 0 then players[1] else Players.PlayerAdded:Wait()
Scenarios.handshake.ServerCpuDone:send(true, player)
Scenarios.handshake.ClientReady:wait()

-- Blink-comparable: 1000 fires/frame, 10 s, varying data ----------------

Harness.header(
    string.format(
        "Cross-library reference (s2c, %d fires/frame, %ds)",
        bench.blinkFiresPerFrame,
        bench.blinkSeconds
    )
)
for _, case in Scenarios.blinkCases do
    Harness.throughput(
        case.label,
        bench.blinkFiresPerFrame,
        bench.blinkSeconds,
        case.pool,
        function(data)
            case.packet:send(data, player)
        end
    )
    task.wait(2)
end

-- Extended scenarios: 100 fires/frame, vary/stable pairs ----------------

Harness.header(
    string.format(
        "Extended (s2c, %d fires/frame, %ds)",
        bench.extendedFiresPerFrame,
        bench.extendedSeconds
    )
)
for _, case in Scenarios.extendedCases do
    Harness.throughput(
        case.label,
        bench.extendedFiresPerFrame,
        bench.extendedSeconds,
        case.pool,
        function(data)
            case.packet:send(data, player)
        end
    )
    task.wait(1)
end

-- Yield for c2s ----------------------------------------------------------

Scenarios.handshake.ServerSwap:send(true, player)
Scenarios.handshake.ClientDone:wait()

Harness.header("Done")
