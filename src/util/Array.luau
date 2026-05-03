--!strict
--!optimize 2
-- O(1) array swap-remove. Breaks insertion order.

-- Public -----------------------------------------------------------------

local Array = {}

-- Reorders. Caller-tracked counts must decrement separately.
function Array.swapRemove<T>(arr: { T }, idx: number): ()
    local last = #arr
    if idx ~= last then
        arr[idx] = arr[last]
    end
    arr[last] = nil
end

return table.freeze(Array)
