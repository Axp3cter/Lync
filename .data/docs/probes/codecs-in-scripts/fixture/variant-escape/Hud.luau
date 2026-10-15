-- a module that passes the namespace on: makes it incomplete (nothing closes)
local Net = require(script.Parent.Net.client)
local M = {}
function M.bind(registry)
	registry.net = Net
end
return M
