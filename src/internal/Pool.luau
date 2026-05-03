--!strict
--!optimize 2
-- ChannelState pool. Acquire fullResets to wipe prior owner state.

local Channel = require(script.Parent.Channel)
local Log     = require(script.Parent.Parent.util.Log)
local Types   = require(script.Parent.Parent.Types)

-- Constants --------------------------------------------------------------

local DEFAULT_SIZE = 16

-- State ------------------------------------------------------------------

local _stack:   { Types.ChannelState } = {}
local _depth   = 0
local _maxSize = DEFAULT_SIZE

-- Public -----------------------------------------------------------------

local Pool = {}

-- fullReset wipes the prior owner's XOR baseline and delta caches.
function Pool.acquire(): Types.ChannelState
    if _depth > 0 then
        local ch = _stack[_depth]
        _stack[_depth] = nil
        _depth -= 1
        Channel.fullReset(ch)
        return ch
    end
    return Channel.create()
end

-- Above the cap, drop on the floor; the GC reclaims the buffer.
function Pool.release(ch: Types.ChannelState): ()
    if _depth >= _maxSize then
        return
    end
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
    _depth   = 0
    _maxSize = DEFAULT_SIZE
end

return table.freeze(Pool)
