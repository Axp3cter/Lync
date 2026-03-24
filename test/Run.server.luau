--!strict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local testFolder = ReplicatedStorage:WaitForChild("Lync"):WaitForChild("test")

require(testFolder)

local Runner = require(testFolder:WaitForChild("Runner"))
local passed = Runner.run()

if not passed then
    error("[Lync] Tests failed")
end
