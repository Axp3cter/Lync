--!strict
--!optimize 2
-- Stack-based ChannelState pool for per-player channel reuse.

local Types   = require(script.Parent.Parent.Types)
local Channel = require(script.Parent.Channel)

-- Constants -----------------------------------------------------------

local DEFAULT_SIZE = 16

-- State ---------------------------------------------------------------

local _stack: { Types.ChannelState } = {}
local _depth = 0
local _maxSize = DEFAULT_SIZE

-- Public --------------------------------------------------------------

local Pool = {}

function Pool.acquire(): Types.ChannelState
    if _depth > 0 then
        local ch = _stack[_depth]
        _stack[_depth] = nil :: any
        _depth -= 1
        Channel.reset(ch)
        return ch
    end

    return Channel.create()
end

function Pool.release(ch: Types.ChannelState): ()
    if _depth >= _maxSize then return end

    _depth += 1
    _stack[_depth] = ch
end

function Pool.setMaxSize(size: number): ()
    _maxSize = size

    -- Trim excess
    while _depth > _maxSize do
        _stack[_depth] = nil :: any
        _depth -= 1
    end
end

function Pool.count(): number
    return _depth
end

return table.freeze(Pool)
