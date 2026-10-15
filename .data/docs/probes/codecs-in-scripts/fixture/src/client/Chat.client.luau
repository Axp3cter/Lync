local Net = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Net"):WaitForChild("client"))
local chat = Net.chat -- an alias of one definition
local function say(text: string)
	chat:fire(text)
end
local box = {}
box.FocusLost = function() say("gg") end
return nil
