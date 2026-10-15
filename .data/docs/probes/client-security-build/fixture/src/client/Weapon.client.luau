local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Shared.Lync)
local Combat = Lync.client(require(ReplicatedStorage.Shared.Combat))

Combat.shoot:fire({ target = 1, aim = vector.create(0, 0, 1), charge = 0.5 })
Combat.reload:fire()
local result = Combat.inventory:invoke({ page = 0 })

-- A raw remote call the build must report: honest code bypassing Lync.
local legacy = ReplicatedStorage:WaitForChild("LegacyShop")
legacy:FireServer("buy", 3)
