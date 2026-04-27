--!strict
--!optimize 2
-- Cross-module utility helpers.

-- Public -----------------------------------------------------------------

local Util = {}

function Util.isPlayer(value: any): boolean
    return typeof(value) == "Instance" and (value :: Instance):IsA("Player")
end

--[[
    O(1) array remove via swap with last element. The slot becomes nil
    after this returns; callers that track an external count must
    decrement it themselves.
]]
function Util.swapRemove<T>(arr: { T }, idx: number): ()
    local last = #arr
    if idx ~= last then
        arr[idx] = arr[last]
    end
    arr[last] = nil
end

return table.freeze(Util)
