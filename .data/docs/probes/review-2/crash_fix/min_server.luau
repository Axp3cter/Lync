--!strict
-- review-2: requiring the minimal schema through the server view
local Lync = require("./lync")
local Net = Lync.server(require("./min_schema"))
local _ = Net
