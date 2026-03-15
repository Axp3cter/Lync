--!strict
-- Run.server.luau — Rojo maps this to ServerScriptService.RunTests.
-- Requires the test init inside ReplicatedStorage.Lync.test.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

require(ReplicatedStorage:WaitForChild("Lync"):WaitForChild("test"))
