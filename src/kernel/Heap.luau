--!strict
--!optimize 2
-- The one binary min-heap, over parallel key and value arrays.

local Heap = {}

-- Types ---------------------------------------------------------------

--[[
    `count` is the truth, not `#keys`. A pop leaves the arrays at the size they reached, so a heap
    draining at frame rate stops allocating and whatever sits past `count` is gone.
]]
export type Heap = {
    keys: { number },
    values: { number },
    count: number,
}

-- Public --------------------------------------------------------------

function Heap.new (): Heap return { keys = {}, values = {}, count = 0 } end

-- The parent moves down into the vacated place, so a climb of n levels costs n moves and not 3n.
function Heap.push (heap: Heap, key: number, value: number)
    local keys, values = heap.keys, heap.values

    local at = heap.count + 1
    heap.count = at

    while at > 1 do
        local parent = at // 2
        if keys[parent] <= key then break end

        keys[at], values[at] = keys[parent], values[parent]
        at = parent
    end

    keys[at], values[at] = key, value
end

function Heap.peek (heap: Heap): (number?, number?)
    if heap.count == 0 then return nil, nil end
    return heap.keys[1], heap.values[1]
end

--[[
    Moving rather than swapping for the reason `push` gives climbing. The walk stops at the last
    node with a child, which is half of what is left.
]]
function Heap.pop (heap: Heap): (number?, number?)
    local count = heap.count
    if count == 0 then return nil, nil end

    local keys, values = heap.keys, heap.values
    local key, value = keys[1], values[1]

    local size = count - 1
    heap.count = size
    if size == 0 then return key, value end

    local moved, movedValue = keys[count], values[count]
    local at = 1
    local half = size // 2

    while at <= half do
        local child = at * 2
        if child < size and keys[child + 1] < keys[child] then
            child += 1
        end
        if keys[child] >= moved then break end

        keys[at], values[at] = keys[child], values[child]
        at = child
    end

    keys[at], values[at] = moved, movedValue
    return key, value
end

return table.freeze (Heap)
