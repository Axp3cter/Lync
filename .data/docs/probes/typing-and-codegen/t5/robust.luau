--!strict
local Lync = require("./lync")
local Net = require("./net")
local _ra: "REVEAL_defA" = Net.hitA
local _rb: "REVEAL_defB" = Net.hitB
Net.hitA:conect(function() end) -- typo'd method
Net.hitB:conect(function() end)
-- malformed schema: a number where a codec belongs
local badA = Lync.packetA({ x = 5 })
local badB = Lync.packetB({ x = 5 })
badB:connect(function(v) local _r: "REVEAL_badB" = v end)
return nil
