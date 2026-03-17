--!strict
--!optimize 2
-- Read-side baseline cache keyed by source (player or client sentinel).

-- State --------------------------------------------------------------

local _readKey = false :: any
local _readCaches = {} :: { [any]: { [number]: any } }

-- Public -------------------------------------------------------------

local Baseline = {}

-- One-way latch: set to true on first delta write, never reset. This
-- avoids a setReadKey call on every non-delta frame at the cost of a
-- cheap branch once deltas are first used in the session.
Baseline.hasDelta = false

function Baseline.setReadKey (key: any): ()
    _readKey = key
end

function Baseline.getCache (deltaId: number): any
    local map = _readCaches[_readKey]
    return map and map[deltaId]
end

function Baseline.setCache (deltaId: number, data: any): ()
    if not Baseline.hasDelta then
        Baseline.hasDelta = true
    end
    local map = _readCaches[_readKey]
    if not map then
        map = {}
        _readCaches[_readKey] = map
    end
    map[deltaId] = data
end

function Baseline.clearSource (key: any): ()
    _readCaches[key] = nil
end

-- Not frozen: hasDelta is mutated at runtime by setCache.
return Baseline
