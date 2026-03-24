--!strict
--!optimize 2
-- Read-side delta cache for delta codecs.

-- State ---------------------------------------------------------------

local _caches: { [number]: { [any]: any } } = {}
local _currentKey: any = false
local _hasDelta = false

-- Public --------------------------------------------------------------

local Baseline = {}

function Baseline.setReadKey(key: any): ()
    _currentKey = key
end

function Baseline.getCache(deltaId: number): any?
    local perPlayer = _caches[deltaId]
    if not perPlayer then return nil end
    return perPlayer[_currentKey]
end

function Baseline.setCache(deltaId: number, value: any): ()
    local perPlayer = _caches[deltaId]
    if not perPlayer then
        perPlayer = {}
        _caches[deltaId] = perPlayer
    end
    perPlayer[_currentKey] = value
end

function Baseline.clearPlayer(key: any): ()
    for _, perPlayer in _caches do
        perPlayer[key] = nil
    end
end

function Baseline.markHasDelta(): ()
    _hasDelta = true
end

function Baseline.hasDelta(): boolean
    return _hasDelta
end

return table.freeze(Baseline)
