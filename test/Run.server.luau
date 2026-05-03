--!strict
--!optimize 2
-- Studio entry point. Mounted to ServerScriptService.RunTests by dev.project.json.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local testFolder = ReplicatedStorage:WaitForChild("Lync"):WaitForChild("test")

require(testFolder)

local Runner = require(testFolder:WaitForChild("runner"))
local passed = Runner.run({ reporter = "compact" })

if not passed then
    error("[Lync] Tests failed")
end
