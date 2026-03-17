--!strict
--!optimize 2
-- Named player sets with auto-cleanup on PlayerRemoving.

local Players = game:GetService ("Players")

-- State ------------------------------------------------------------------

local _groups = {} :: { [string]: { [Player]: true } }
local _counts = {} :: { [string]: number }
local _playerGroups = {} :: { [Player]: { [string]: true } }

-- Private ----------------------------------------------------------------

local function onPlayerRemoving (player: Player): ()
    local memberships = _playerGroups[player]
    if not memberships then
        return
    end

    for name in memberships do
        local set = _groups[name]
        if set and set[player] then
            set[player] = nil
            _counts[name] -= 1
        end
    end

    _playerGroups[player] = nil
end

Players.PlayerRemoving:Connect (onPlayerRemoving)

-- GroupImpl ---------------------------------------------------------------

local GroupImpl = {}
GroupImpl.__index = GroupImpl

function GroupImpl.add (self: any, player: Player): boolean
    local name = self._name
    local set = _groups[name]
    if not set then
        error (`[Lync] Group has been destroyed: "{name}"`)
    end

    if set[player] then
        return false
    end

    set[player] = true
    _counts[name] += 1

    local memberships = _playerGroups[player]
    if not memberships then
        memberships = {}
        _playerGroups[player] = memberships
    end
    memberships[name] = true

    return true
end

function GroupImpl.remove (self: any, player: Player): boolean
    local name = self._name
    local set = _groups[name]
    if not set then
        error (`[Lync] Group has been destroyed: "{name}"`)
    end

    if not set[player] then
        return false
    end

    set[player] = nil
    _counts[name] -= 1

    local memberships = _playerGroups[player]
    if memberships then
        memberships[name] = nil
    end

    return true
end

function GroupImpl.has (self: any, player: Player): boolean
    local name = self._name
    local set = _groups[name]
    if not set then
        error (`[Lync] Group has been destroyed: "{name}"`)
    end
    return set[player] == true
end

function GroupImpl.count (self: any): number
    local name = self._name
    if not _groups[name] then
        error (`[Lync] Group has been destroyed: "{name}"`)
    end
    return _counts[name]
end

function GroupImpl.forEach (self: any, fn: (player: Player) -> ()): ()
    local name = self._name
    local set = _groups[name]
    if not set then
        error (`[Lync] Group has been destroyed: "{name}"`)
    end
    for player in set do
        fn (player)
    end
end

function GroupImpl.getSet (self: any): { [Player]: true }
    local name = self._name
    local set = _groups[name]
    if not set then
        error (`[Lync] Group has been destroyed: "{name}"`)
    end
    return set
end

function GroupImpl.destroy (self: any): ()
    local name = self._name
    local set = _groups[name]
    if not set then
        error (`[Lync] Group has been destroyed: "{name}"`)
    end

    for player in set do
        local memberships = _playerGroups[player]
        if memberships then
            memberships[name] = nil
        end
    end

    _groups[name] = nil
    _counts[name] = nil
end

table.freeze (GroupImpl)

-- Public -----------------------------------------------------------------

local Group = {}

function Group.create (name: string): any
    if _groups[name] then
        error (`[Lync] Group already exists: "{name}"`)
    end
    _groups[name] = {}
    _counts[name] = 0

    return setmetatable ({
        _tag = "group",
        _name = name,
    }, GroupImpl)
end

return table.freeze (Group)
