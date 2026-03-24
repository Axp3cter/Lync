--!strict
--!optimize 2
-- Client-side bench receiver.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LyncFolder = ReplicatedStorage:WaitForChild("Lync")
local Lync = require(LyncFolder)
local benchFolder = LyncFolder:WaitForChild("bench")
local Scenarios = require(benchFolder:WaitForChild("Scenarios"))

Lync.start()

for _, packet in Scenarios.allPackets do
    packet:on(function(): () end)
end

-- Wait for server to finish CPU benchmarks before signaling ready
Scenarios.ServerReady:wait()
Scenarios.Ready:send(true)
