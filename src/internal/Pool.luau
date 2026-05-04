--!strict
--!optimize 2
-- ChannelState pool. Acquire fullResets to wipe prior owner state.

local Channel = require(script.Parent.Channel)
local Log = require(script.Parent.Parent.util.Log)
local Types = require(script.Parent.Parent.Types)

-- Constants --------------------------------------------------------------

local DEFAULT_SIZE = 16

-- State ------------------------------------------------------------------

local _stack: { Types.ChannelState } = {}
local _depth = 0
local _maxSize = DEFAULT_SIZE

-- Public -----------------------------------------------------------------

local Pool = {}

function Pool.acquire(): Types.ChannelState
    if _depth > 0 then
        local ch = _stack[_depth]
        _stack[_depth] = nil
        _depth -= 1
        return ch
    end
    return Channel.create()
end

-- Scrub on release so the pool never holds the prior owner's Instance refs
-- or XOR baseline buffer; otherwise a player who disconnects mid-frame leaves
-- those rooted in the pool until the slot is re-acquired (potentially never).
function Pool.release(ch: Types.ChannelState): ()
    if _depth >= _maxSize then
        return
    end
    Channel.fullReset(ch)
    _depth += 1
    _stack[_depth] = ch
end

function Pool.setMaxSize(size: number): ()
    if size < 0 then
        Log.error(`size must be non-negative, got {size}`)
    end
    _maxSize = size
    while _depth > _maxSize do
        _stack[_depth] = nil
        _depth -= 1
    end
end

function Pool.count(): number
    return _depth
end

function Pool.reset(): ()
    table.clear(_stack)
    _depth = 0
    _maxSize = DEFAULT_SIZE
end

return table.freeze(Pool)
