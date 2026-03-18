--!strict
--!optimize 2
-- Client-side bench receiver.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LyncFolder = ReplicatedStorage:WaitForChild("Lync")
local Lync = require(LyncFolder)
local Scenarios = require(LyncFolder:WaitForChild("bench"):WaitForChild("Scenarios"))

Lync.start()

for name, packet in Scenarios.allPackets do
    packet:listen(function(): () end)
end

task.wait(1)
Scenarios.Ready:send(true)
