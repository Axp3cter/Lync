-- A Lync-side helper that reads its caller's environment, as `getfenv(2).script` would on Roblox.
return function()
	return getfenv(2)
end
