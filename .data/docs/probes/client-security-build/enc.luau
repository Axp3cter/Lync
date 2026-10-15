local Remotes = game:GetService("ReplicatedStorage"):WaitForChild("LyncReliable")
local SECRET = 0x5A17
local function writeChatMessage(b: buffer, o: number, text: string, channel: number): number
	local len = #text
	buffer.writeu16(b, o, bit32.bxor(len, SECRET))
	buffer.writestring(b, o + 2, text)
	buffer.writeu8(b, o + 2 + len, channel)
	return o + 3 + len
end
return { writeChatMessage = writeChatMessage, remote = Remotes }
