local Net = require(script.Parent.Net)
local function onClick()
	Net.buyItem:fire(3)
end
return onClick
