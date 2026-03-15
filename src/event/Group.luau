--!strict
--!optimize 2
-- Group.luau — Named player sets with auto-cleanup on PlayerRemoving.

local Players = game:GetService("Players")

-- State ------------------------------------------------------------------

local _groups       = {} :: { [string]: { [Player]: true } }
local _playerGroups = {} :: { [Player]: { [string]: true } }

-- Private ----------------------------------------------------------------

local function onPlayerRemoving(player: Player): ()
    local memberships = _playerGroups[player]
    if not memberships then return end

    for name in memberships do
        local set = _groups[name]
        if set then
            set[player] = nil
        end
    end

    _playerGroups[player] = nil
end

Players.PlayerRemoving:Connect(onPlayerRemoving)

local function getSetOrError(name: string): { [Player]: true }
    local set = _groups[name]
    if not set then error(`[Lync] Group does not exist: {name}`) end
    return set
end

-- Public -----------------------------------------------------------------

local Group = {}

function Group.create(name: string): ()
    if _groups[name] then error(`[Lync] Group already exists: {name}`) end
    _groups[name] = {}
end

function Group.destroy(name: string): ()
    local set = getSetOrError(name)

    for player in set do
        local memberships = _playerGroups[player]
        if memberships then
            memberships[name] = nil
        end
    end

    _groups[name] = nil
end

function Group.add(name: string, player: Player): boolean
    local set = getSetOrError(name)

    if set[player] then return false end

    set[player] = true

    local memberships = _playerGroups[player]
    if not memberships then
        memberships = {}
        _playerGroups[player] = memberships
    end
    memberships[name] = true

    return true
end

function Group.remove(name: string, player: Player): ()
    local set = getSetOrError(name)

    set[player] = nil

    local memberships = _playerGroups[player]
    if memberships then
        memberships[name] = nil
    end
end

function Group.has(name: string, player: Player): boolean
    local set = getSetOrError(name)
    return set[player] == true
end

function Group.getSet(name: string): { [Player]: true }
    return getSetOrError(name)
end

function Group.forEach(name: string, fn: (player: Player) -> ()): ()
    for player in getSetOrError(name) do
        fn(player)
    end
end

return table.freeze(Group)
