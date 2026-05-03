--!strict
--!optimize 2
-- Client: receive s2c, then drive c2s.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Harness = require(ReplicatedStorage.Lync.bench.Harness)
local Lync = require(ReplicatedStorage:WaitForChild("Lync"))
local Scenarios = require(ReplicatedStorage.Lync.bench.Scenarios)

local bench = Scenarios.bench

-- Minimise render contention so frame budget reflects bench CPU only.
if Workspace.CurrentCamera then
    Workspace.CurrentCamera.FieldOfView = 1
end

Lync.configure({ channelMaxSize = bench.channelMaxSize, stats = true })
Lync.start()

Scenarios.handshake.ServerCpuDone:wait()
Scenarios.handshake.ClientReady:send(true)
Scenarios.handshake.ServerSwap:wait()

-- Blink-comparable c2s ---------------------------------------------------

Harness.header(
    string.format(
        "Cross-library reference (c2s, %d fires/frame, %ds)",
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
            case.packet:send(data)
        end
    )
    task.wait(2)
end

-- Extended c2s -----------------------------------------------------------

Harness.header(
    string.format(
        "Extended (c2s, %d fires/frame, %ds)",
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
            case.packet:send(data)
        end
    )
    task.wait(1)
end

Scenarios.handshake.ClientDone:send(true)
