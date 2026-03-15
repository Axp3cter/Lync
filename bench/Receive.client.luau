--!strict
-- Client-side bench receiver.

local ReplicatedStorage = game:GetService ("ReplicatedStorage")

local Lync = ReplicatedStorage:WaitForChild ("Lync")
local Definitions = require (Lync:WaitForChild ("bench"):WaitForChild ("Definitions"))
local LyncModule = require (Lync)

LyncModule.start ()

Definitions.Booleans:listen (function (): () end)
Definitions.Entities:listen (function (): () end)

task.wait (1)
Definitions.Ready:send (true)
