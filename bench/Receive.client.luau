--!strict
-- Client-side bench receiver.

local ReplicatedStorage = game:GetService ("ReplicatedStorage")

local LyncFolder = ReplicatedStorage:WaitForChild ("Lync")
local Lync = require (LyncFolder)
local Definitions = require (LyncFolder:WaitForChild ("bench"):WaitForChild ("Definitions"))

Lync.start ()

Definitions.Booleans:listen (function (): () end)
Definitions.Entities:listen (function (): () end)

task.wait (1)
Definitions.Ready:send (true)
