--!strict
--!optimize 2
-- Group.luau — Named player sets with auto-cleanup on PlayerRemoving.

local Players = game:GetService ("Players")

-- State ------------------------------------------------------------------

local _groups = {} :: { [string]: { [Player]: true } }
local _playerGroups = {} :: { [Player]: { [string]: true } }
local _isConnected = false

-- Private ----------------------------------------------------------------

local function onPlayerRemoving (player: Player): ()
    local memberships = _playerGroups[player]
    if not memberships then
        return
    end

    for name in memberships do
        local set = _groups[name]
        if set then
            set[player] = nil
        end
    end

    _playerGroups[player] = nil
end

-- Public -----------------------------------------------------------------

local Group = {}

function Group.create (name: string): ()
    if _groups[name] then
        error (`[Lync] Group already exists: {name}`)
    end

    _groups[name] = {}

    if not _isConnected then
        _isConnected = true
        Players.PlayerRemoving:Connect (onPlayerRemoving)
    end
end

function Group.destroy (name: string): ()
    local set = _groups[name]
    if not set then
        error (`[Lync] Group does not exist: {name}`)
    end

    for player in set do
        local memberships = _playerGroups[player]
        if memberships then
            memberships[name] = nil
        end
    end

    _groups[name] = nil
end

function Group.add (name: string, player: Player): ()
    local set = _groups[name]
    if not set then
        error (`[Lync] Group does not exist: {name}`)
    end

    set[player] = true

    local memberships = _playerGroups[player]
    if not memberships then
        memberships = {}
        _playerGroups[player] = memberships
    end
    memberships[name] = true
end

function Group.remove (name: string, player: Player): ()
    local set = _groups[name]
    if not set then
        error (`[Lync] Group does not exist: {name}`)
    end

    set[player] = nil

    local memberships = _playerGroups[player]
    if memberships then
        memberships[name] = nil
    end
end

function Group.players (name: string): { Player }
    local set = _groups[name]
    if not set then
        error (`[Lync] Group does not exist: {name}`)
    end

    local list = {}
    local n = 0
    for player in set do
        n += 1
        list[n] = player
    end
    return list
end

function Group.forEach (name: string, fn: (player: Player) -> ()): ()
    local set = _groups[name]
    if not set then
        error (`[Lync] Group does not exist: {name}`)
    end

    for player in set do
        fn (player)
    end
end

return table.freeze (Group)
