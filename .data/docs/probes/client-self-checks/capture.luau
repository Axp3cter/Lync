--!strict
-- U1: capture FireServer once per remote and call it as a plain function. Type-check only:
-- luau.py check --roblox capture.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local folder = ReplicatedStorage:WaitForChild("Lync")
local reliable = folder:WaitForChild("Reliable") :: RemoteEvent
local unreliable = folder:WaitForChild("Unreliable") :: UnreliableRemoteEvent

-- captured once, when each remote is found
local fireReliable = reliable.FireServer
local fireUnreliable = unreliable.FireServer

local function send(lane: number, frame: buffer, instances: { Instance }?)
	if lane == 0 then
		fireReliable(reliable, frame, instances)
	else
		fireUnreliable(unreliable, frame, instances)
	end
end

send(0, buffer.create(4), nil)
