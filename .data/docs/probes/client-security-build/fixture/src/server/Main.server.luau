local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Shared.Lync)
local Combat = Lync.server(require(ReplicatedStorage.Shared.Combat))
Combat.hit:fire(Lync.all, { target = 1, damage = 10 })
local shop = Instance.new("RemoteEvent")
shop.Name = "LegacyShop"
shop.Parent = ReplicatedStorage
