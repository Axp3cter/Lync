--!strict
local Lync = require("./lync")
local Net = require("./net")
local CG = Lync.clientG(Net)
local CF = Lync.clientF(Net)
CG.hit:connect(function(value, player) end) -- 2-param handler on client: accepted? (extra param)
CG.hit:connect(function(value) local _r: "REVEAL_CG" = value end)
CG.hit:fire({ target = 1, note = "x" }) -- ok
CG.hit:fireAll({ target = 1, note = "x" }) -- server-only: must fail
CF.hit:fireAll({ target = 1, note = "x" }) -- server-only: must fail
local p: Lync.Player = nil :: any
CG.hit:fire(p, { target = 1, note = "x" }) -- server-style: must fail
CF.hit:fire(p, { target = 1, note = "x" }) -- server-style: must fail
-- malformed schema passed to a view
local bad = Lync.clientG({ x = 5 })
return nil
