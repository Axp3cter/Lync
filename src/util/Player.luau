--!strict
--!optimize 2
-- Player Instance type guard.

-- Public -----------------------------------------------------------------

local Player = {}

-- typeof first: :IsA errors on non-Instances.
function Player.is(value: any): boolean
    return typeof(value) == "Instance" and value:IsA("Player")
end

return table.freeze(Player)
