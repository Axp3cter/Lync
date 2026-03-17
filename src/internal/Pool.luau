--!strict
--!optimize 2
-- Stack-based ChannelState pool with warmup support.

local Channel = require (script.Parent.Channel)
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Constants ----------------------------------------------------------

local DEFAULT_MAX = 16

-- State --------------------------------------------------------------

local _stack = {} :: { ChannelState }
local _depth = 0
local _maxSize = DEFAULT_MAX

-- Public -------------------------------------------------------------

local Pool = {}

-- Override the max idle ChannelStates in the pool. Default 16. Range: 2-128.
function Pool.setMaxSize (count: number): ()
    if count < 2 or count > 128 then
        error (`[Lync] Pool max size must be 2-128, got {count}`)
    end
    _maxSize = count
end

function Pool.getMaxSize (): number
    return _maxSize
end

function Pool.acquire (): ChannelState
    if _depth > 0 then
        local ch = _stack[_depth]
        _stack[_depth] = nil :: any
        _depth -= 1
        return ch
    end

    return Channel.create ()
end

function Pool.release (ch: ChannelState): ()
    ch.cursor = 0
    ch.lastId = -1
    ch.countPos = 0
    ch.itemCount = 0
    table.clear (ch.refs)
    table.clear (ch.deltas)
    ch.prevDump = nil

    if _depth >= _maxSize then
        return -- discard; GC will reclaim
    end

    _depth += 1
    _stack[_depth] = ch
end

function Pool.size (): number
    return _depth
end

return table.freeze (Pool)
