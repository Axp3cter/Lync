--!strict
--!optimize 2
-- Stack-based ChannelState pool. Reset-on-acquire keeps released
-- channels reusable without per-release reset cost.

local Channel = require(script.Parent.Channel)
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
        Channel.reset(ch)
        return ch
    end
    return Channel.create()
end

function Pool.release(ch: Types.ChannelState): ()
    if _depth >= _maxSize then
        return
    end
    _depth += 1
    _stack[_depth] = ch
end

function Pool.setMaxSize(size: number): ()
    if size < 0 then
        error(`[Lync] Pool.setMaxSize: size must be >= 0, got {size}`)
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

return table.freeze(Pool)
