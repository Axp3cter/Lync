--!strict
-- Receive.client.luau — Receives bench packets, signals ready to server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Lync        = ReplicatedStorage:WaitForChild("Lync")
local LyncModule  = require(Lync)
local Definitions = require(Lync:WaitForChild("bench"):WaitForChild("Definitions"))

LyncModule.start()

Definitions.Booleans:listen(function(): () end)
Definitions.Entities:listen(function(): () end)

task.wait(1)
Definitions.Ready:send(true)
