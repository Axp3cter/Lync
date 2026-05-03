--!strict
--!optimize 2
-- Named player sets with __iter and auto-cleanup on PlayerRemoving.

local Players = game:GetService("Players")

local Array = require(script.Parent.Parent.util.Array)
local Log = require(script.Parent.Parent.util.Log)

-- Public types -----------------------------------------------------------

export type GroupHandle = {
    add: (self: GroupHandle, player: Player) -> boolean,
    remove: (self: GroupHandle, player: Player) -> boolean,
    has: (self: GroupHandle, player: Player) -> boolean,
    count: (self: GroupHandle) -> number,
    destroy: (self: GroupHandle) -> (),
    _lyncKind: "group",
    _members: { [Player]: boolean },
}

type GroupInternal = GroupHandle & { _count: number, _name: string }

-- State ------------------------------------------------------------------

local _groups: { [string]: GroupInternal } = {}
-- Reverse index used by PlayerRemoving so we don't scan every group on disconnect.
local _playerCleanup: { [Player]: { Group } } = {}
local _cleanupConnected = false

-- Private ----------------------------------------------------------------

local swapRemove = Array.swapRemove

-- Connect once on the first Group.create; subsequent creates reuse the same connection.
local function ensureCleanup(): ()
    if _cleanupConnected then
        return
    end
    _cleanupConnected = true

    Players.PlayerRemoving:Connect(function(player: Player)
        local groups = _playerCleanup[player]
        if not groups then
            return
        end
        for _, group in groups do
            group._members[player] = nil
            group._count -= 1
        end
        _playerCleanup[player] = nil
    end)
end

local function untrackCleanup(player: Player, group: GroupInternal): ()
    local cleanup = _playerCleanup[player]
    if not cleanup then
        return
    end
    local idx = table.find(cleanup, group)
    if idx then
        swapRemove(cleanup, idx)
    end
end

-- Public -----------------------------------------------------------------

local Group = {}

local GroupMeta = {}
GroupMeta.__index = GroupMeta

-- __iter lets `for player in group do` skip the explicit :members() call.
function GroupMeta.__iter(self: GroupInternal): (any, any, any)
    return next, self._members, nil
end

function GroupMeta.add(self: GroupInternal, player: Player): boolean
    if self._members[player] then
        return false
    end

    self._members[player] = true
    self._count += 1

    local cleanup = _playerCleanup[player]
    if not cleanup then
        cleanup = {}
        _playerCleanup[player] = cleanup
    end
    table.insert(cleanup, self)
    return true
end

function GroupMeta.remove(self: GroupInternal, player: Player): boolean
    if not self._members[player] then
        return false
    end

    self._members[player] = nil
    self._count -= 1
    untrackCleanup(player, self)
    return true
end

function GroupMeta.has(self: GroupInternal, player: Player): boolean
    return self._members[player] == true
end

function GroupMeta.count(self: GroupInternal): number
    return self._count
end

function GroupMeta.destroy(self: GroupInternal): ()
    if _groups[self._name] == self then
        _groups[self._name] = nil
    end

    for player in self._members do
        untrackCleanup(player, self)
    end

    table.clear(self._members)
    self._count = 0
end

table.freeze(GroupMeta)

function Group.create(name: string): GroupHandle
    if _groups[name] then
        Log.error(`"{name}" already exists`)
    end

    ensureCleanup()

    local group = setmetatable({
        _lyncKind = "group" :: "group",
        _members = {} :: { [Player]: boolean },
        _count = 0,
        _name = name,
    }, GroupMeta) :: any

    _groups[name] = group
    return group
end

function Group.reset(): ()
    for _, group in _groups do
        table.clear(group._members)
        group._count = 0
    end
    table.clear(_groups)
    table.clear(_playerCleanup)
end

return table.freeze(Group)
