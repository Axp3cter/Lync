--!strict
-- Client-side bench receiver.

local ReplicatedStorage = game:GetService ("ReplicatedStorage")

local LyncFolder = ReplicatedStorage:WaitForChild ("Lync")
local Definitions = require (LyncFolder:WaitForChild ("bench"):WaitForChild ("Definitions"))
local Lync = require (LyncFolder)

Lync.start ()

Definitions.Booleans:listen (function (): () end)
Definitions.Entities:listen (function (): () end)

task.wait (1)
Definitions.Ready:send (true)
