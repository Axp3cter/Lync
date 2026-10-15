local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Shared.Lync)
local Combat = Lync.client(require(ReplicatedStorage.Shared.Combat))
local name = "hit"
-- Dynamic indexing: the analysis cannot see which definition this fires.
Combat[name]:fire({ target = 1, damage = 5 })
