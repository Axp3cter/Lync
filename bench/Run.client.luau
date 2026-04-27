--!strict
--!optimize 2
-- Client-side benchmark runner. Drains s2c, then drives c2s.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LyncFolder = ReplicatedStorage:WaitForChild("Lync")
local Harness = require(LyncFolder.bench.Harness)
local Lync = require(LyncFolder)
local Scenarios = require(LyncFolder.bench.Scenarios)

-- Constants --------------------------------------------------------------

local bench = Scenarios.bench

local function noop(): () end

--[[
    Client must mirror the server's channelMaxSize. Server and client run
    as separate Lua VMs with independent module state, so configure() on
    the server doesn't propagate. Without this, the client's buffer caps
    at the 256KB default and the comparison test (1000 fires of 601B
    entity arrays = 601KB) overflows during c2s.
]]
Lync.configure({ channelMaxSize = bench.channelMaxSize })
Lync.start()

-- Attach receivers so server -> client throughput isn't held back by
-- serializing into uncollected channels.
for _, packet in Scenarios.packets do
    packet:on(noop)
end

-- Wait through s2c phase -------------------------------------------------

Scenarios.handshake.ServerCpuDone:wait()
Scenarios.handshake.ClientReady:send(true)
Scenarios.handshake.ServerSwap:wait()

-- c2s throughput ---------------------------------------------------------

Harness.header("Network Throughput (client -> server)")

Harness.section(string.format("%d fires/frame, %ds per case", bench.smallFires, bench.netDuration))
for _, case in Scenarios.netCases do
    local packet, data = case.packet, case.data
    Harness.benchNetwork(case.label, case.fires, bench.netDuration, function()
        packet:send(data)
    end)
end
Harness.sectionEnd()

-- Cross-library comparison (client -> server) ----------------------------

Harness.header("Cross-Library Comparison (client -> server)")

for _, case in Scenarios.compCases do
    Harness.section(
        string.format("%s, %d/frame, %ds", case.title, bench.compFires, bench.compDuration)
    )
    local packet, data = case.packet, case.data
    Harness.benchComparison(
        case.label,
        bench.compFires,
        bench.compDuration,
        bench.compFps,
        function()
            packet:send(data)
        end
    )
    Harness.sectionEnd()
end

Scenarios.handshake.ClientDone:send(true)
