--!strict
--!optimize 2
-- Baseline.luau — Read-side baseline cache keyed by source (player or client sentinel).

-- State ------------------------------------------------------------------

local _readKey    = false :: any
local _readCaches = {} :: { [any]: { [number]: any } }

-- Public -----------------------------------------------------------------

local Baseline = {}

function Baseline.setReadKey(key: any): ()
    _readKey = key
end

function Baseline.getCache(deltaId: number): any
    local map = _readCaches[_readKey]
    return if map then map[deltaId] else nil
end

function Baseline.setCache(deltaId: number, data: any): ()
    local map = _readCaches[_readKey]
    if not map then
        map = {}
        _readCaches[_readKey] = map
    end
    map[deltaId] = data
end

function Baseline.clearSource(key: any): ()
    _readCaches[key] = nil
end

return table.freeze(Baseline)
