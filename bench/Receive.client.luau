--!strict
-- Client-side bench receiver.

local ReplicatedStorage = game:GetService ("ReplicatedStorage")

local LyncFolder = ReplicatedStorage:WaitForChild ("Lync")
local Definitions = require (LyncFolder:WaitForChild ("bench"):WaitForChild ("Definitions"))
local Lync = require (LyncFolder)

Lync.start ()

-- Lync-specific
Definitions.Booleans:listen (function (): () end)
Definitions.Entities:listen (function (): () end)

-- Blink-compatible
Definitions.BlinkEntities:listen (function (): () end)
Definitions.BlinkBooleans:listen (function (): () end)

task.wait (1)
Definitions.Ready:send (true)
