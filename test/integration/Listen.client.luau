--!strict
local ReplicatedStorage = game:GetService ("ReplicatedStorage")

local LyncFolder = ReplicatedStorage:WaitForChild ("Lync")
local Lync = require (LyncFolder)
local Scenarios = require (LyncFolder:WaitForChild ("integration"):WaitForChild ("Scenarios"))

Lync.start ()

Scenarios.SimpleU8:listen (function (): () end)
Scenarios.Struct:listen (function (): () end)
Scenarios.BigArray:listen (function (): () end)
Scenarios.Unreliable:listen (function (): () end)

Scenarios.Echo:listen (function (request: string): string
    return "echo:" .. request
end)

Scenarios.MathQuery:listen (function (request: any): number
    return request.a + request.b
end)

task.wait (1)
Scenarios.Ready:send (true)

task.wait (2)
Scenarios.ClientToServer:send (42)
