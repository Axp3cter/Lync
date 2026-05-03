--!strict
--!optimize 2
-- Read-side delta cache, keyed by (deltaId, peer).

local Types = require(script.Parent.Parent.Types)

-- State ------------------------------------------------------------------

-- Per-deltaId map keyed by BaselineKey: server uses Player, client uses `false`.
local _caches: { [number]: { [Types.BaselineKey]: any } } = {}
local _currentKey: Types.BaselineKey = false
local _hasDelta = false

-- Public -----------------------------------------------------------------

local Baseline = {}

function Baseline.setReadKey(key: Types.BaselineKey): ()
    _currentKey = key
end

function Baseline.getCache(deltaId: number): any?
    local perKey = _caches[deltaId]
    return if perKey then perKey[_currentKey] else nil
end

function Baseline.setCache(deltaId: number, value: any): ()
    local perKey = _caches[deltaId]
    if not perKey then
        perKey = {}
        _caches[deltaId] = perKey
    end
    perKey[_currentKey] = value
end

function Baseline.clearPlayer(key: Types.BaselineKey): ()
    for _, perKey in _caches do
        perKey[key] = nil
    end
end

-- Reader checks this once to skip baseline-key bookkeeping when no delta codec exists.
function Baseline.markHasDelta(): ()
    _hasDelta = true
end

function Baseline.hasDelta(): boolean
    return _hasDelta
end

function Baseline.reset(): ()
    table.clear(_caches)
    _currentKey = false
    _hasDelta = false
end

return table.freeze(Baseline)
