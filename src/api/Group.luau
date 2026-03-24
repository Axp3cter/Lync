--!strict
--!optimize 2
-- Named player sets with __iter, auto-cleanup on PlayerRemoving.

local Players = game:GetService("Players")

local Types = require(script.Parent.Parent.Types)

-- State ---------------------------------------------------------------

local _groups: { [string]: any } = {}
local _playerCleanup: { [Player]: { any } } = {}
local _cleanupConnected = false

-- Private -------------------------------------------------------------

local function ensureCleanup(): ()
    if _cleanupConnected then return end
    _cleanupConnected = true

    Players.PlayerRemoving:Connect(function(player: Player)
        local groups = _playerCleanup[player]
        if not groups then return end

        for _, group in groups do
            group._members[player] = nil
            group._count -= 1
        end

        _playerCleanup[player] = nil
    end)
end

-- Public --------------------------------------------------------------

local Group = {}

export type GroupHandle = {
    add: (self: GroupHandle, player: Player) -> boolean,
    remove: (self: GroupHandle, player: Player) -> boolean,
    has: (self: GroupHandle, player: Player) -> boolean,
    count: (self: GroupHandle) -> number,
    destroy: (self: GroupHandle) -> (),
    _lyncGroup: boolean,
    _members: { [Player]: boolean },
}

local GroupMeta = {}
GroupMeta.__index = GroupMeta

function GroupMeta.__iter(self: any): () -> (Player?, boolean?)
    local members = self._members
    local key: Player? = nil

    return function(): (Player?, boolean?)
        local nextKey, nextVal = next(members, key)
        key = nextKey
        if nextKey then
            return nextKey, nextVal
        end
        return nil, nil
    end
end

function GroupMeta.add(self: any, player: Player): boolean
    if self._members[player] then return false end

    self._members[player] = true
    self._count += 1

    -- Track for auto-cleanup
    local cleanup = _playerCleanup[player]
    if not cleanup then
        cleanup = {}
        _playerCleanup[player] = cleanup
    end
    table.insert(cleanup, self)

    return true
end

function GroupMeta.remove(self: any, player: Player): boolean
    if not self._members[player] then return false end

    self._members[player] = nil
    self._count -= 1

    -- Remove from cleanup tracking
    local cleanup = _playerCleanup[player]
    if cleanup then
        local idx = table.find(cleanup, self)
        if idx then
            local last = #cleanup
            cleanup[idx] = cleanup[last]
            cleanup[last] = nil
        end
    end

    return true
end

function GroupMeta.has(self: any, player: Player): boolean
    return self._members[player] == true
end

function GroupMeta.count(self: any): number
    return self._count
end

function GroupMeta.destroy(self: any): ()
    local name = self._name
    if name then
        _groups[name] = nil
    end

    -- Remove all members from cleanup tracking
    for player in self._members do
        local cleanup = _playerCleanup[player]
        if cleanup then
            local idx = table.find(cleanup, self)
            if idx then
                local last = #cleanup
                cleanup[idx] = cleanup[last]
                cleanup[last] = nil
            end
        end
    end

    table.clear(self._members)
    self._count = 0
end

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
    }, GroupMeta)

    _groups[name] = group
    return group :: any
end

return table.freeze(Group)
