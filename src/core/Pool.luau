--!strict
--!optimize 2
-- Stack-based ChannelState pool with warmup support.

local Channel = require (script.Parent.Channel)
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- State ------------------------------------------------------------------

local _stack = {} :: { ChannelState }
local _depth = 0

-- Public -----------------------------------------------------------------

local Pool = {}

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
    ch.batchCount = 0
    table.clear (ch.refs)
    table.clear (ch.deltas)
    ch.prevDump = nil
    _depth += 1
    _stack[_depth] = ch
end

return table.freeze (Pool)
