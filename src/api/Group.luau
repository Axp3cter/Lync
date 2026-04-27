--!strict
--!optimize 2
-- Named player sets with __iter, auto-cleanup on PlayerRemoving.

local Players = game:GetService("Players")

local Util = require(script.Parent.Parent.internal.Util)

-- Public types -----------------------------------------------------------

export type GroupHandle = {
    add: (self: GroupHandle, player: Player) -> boolean,
    remove: (self: GroupHandle, player: Player) -> boolean,
    has: (self: GroupHandle, player: Player) -> boolean,
    count: (self: GroupHandle) -> number,
    destroy: (self: GroupHandle) -> (),
    _lyncGroup: boolean,
    _members: { [Player]: boolean },
}

type Group = GroupHandle & { _count: number, _name: string }

-- State ------------------------------------------------------------------

local _groups: { [string]: Group } = {}
local _playerCleanup: { [Player]: { Group } } = {}
local _cleanupConnected = false

-- Private ----------------------------------------------------------------

local swapRemove = Util.swapRemove

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

-- Public -----------------------------------------------------------------

local Group = {}

local GroupMeta = {}
GroupMeta.__index = GroupMeta

--[[
    __iter returns the standard 3-tuple iterator so `for player in group do`
    uses Luau's builtin path (luaH_next) with zero closure allocation.
]]
function GroupMeta.__iter(self: Group): (any, any, any)
    return next, self._members, nil
end

function GroupMeta.add(self: Group, player: Player): boolean
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

function GroupMeta.remove(self: Group, player: Player): boolean
    if not self._members[player] then
        return false
    end

    self._members[player] = nil
    self._count -= 1

    local cleanup = _playerCleanup[player]
    if cleanup then
        local idx = table.find(cleanup, self)
        if idx then
            swapRemove(cleanup, idx)
        end
    end
    return true
end

function GroupMeta.has(self: Group, player: Player): boolean
    return self._members[player] == true
end

function GroupMeta.count(self: Group): number
    return self._count
end

function GroupMeta.destroy(self: Group): ()
    if _groups[self._name] == self then
        _groups[self._name] = nil
    end

    for player in self._members do
        local cleanup = _playerCleanup[player]
        if cleanup then
            local idx = table.find(cleanup, self)
            if idx then
                swapRemove(cleanup, idx)
            end
        end
    end

    table.clear(self._members)
    self._count = 0
end

table.freeze(GroupMeta)

function Group.create(name: string): GroupHandle
    if _groups[name] then
        error(`[Lync] Lync.group: "{name}" already exists`)
    end

    ensureCleanup()

    local group = setmetatable({
        _lyncGroup = true,
        _members = {} :: { [Player]: boolean },
        _count = 0,
        _name = name,
    }, GroupMeta) :: any

    _groups[name] = group
    return group
end

return table.freeze(Group)
