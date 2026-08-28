--!strict
--!optimize 2
-- A membership set a caller mutates and an audience holds, and the sweep that thins one.

local Log = require ("@src/kernel/Log")
local Types = require ("@src/Types")

local Group = {}

-- Types ---------------------------------------------------------------

--[[
    A set kept as both an array and the place each member sits in it. The array is what a walk and a
    count read, and the index is what a membership test and a removal read, and neither is derivable
    from the other in constant time.
]]
type Held = {
    members: { Player },
    at: { [Player]: number },
}

-- Private -------------------------------------------------------------

local Members = {}
Members.__index = Members

--[[
    What a group becomes when it is released. Every read and every write goes through a metamethod
    that raises, so a caller holding a stale reference is told rather than answered: a destroyed
    group that reported an empty membership would let them fire at nobody forever and never learn
    why.
]]
local Dead = {}

local function gone (): any return Log.refuse ("this group was destroyed") end

Dead.__index = gone
Dead.__len = gone
Dead.__iter = gone

-- State ---------------------------------------------------------------

-- Every group not yet destroyed. A leave sweep walks this to find them.
local live: { [Held]: true } = {}

-- Public --------------------------------------------------------------

--[[
    Adding a member twice leaves one and removing an absent one is nothing. A caller adds on every
    join and removes on every leave from code that has no idea what the group held, so counting
    duplicates or refusing an absent removal would make each of those sites read it first.
]]
function Members.add (self: Held, player: Player)
    if self.at[player] ~= nil then return end

    table.insert (self.members, player)
    self.at[player] = #self.members
end

-- The last member fills the gap, so a removal costs nothing and the order is not one to rely on.
function Members.remove (self: Held, player: Player)
    local index = self.at[player]
    if index == nil then return end

    local last = #self.members
    local moved = self.members[last]

    self.members[index] = moved
    self.at[moved] = index

    self.members[last] = nil
    self.at[player] = nil
end

function Members.has (self: Held, player: Player): boolean return self.at[player] ~= nil end

--[[
    Emptied and let go, in that order. The emptying is what releases the members: a group is the
    only thing holding some of them by the time a caller is done with it, and waiting for the
    collector to notice is exactly the timing this library never rides.
]]
function Members.destroy (self: Held)
    live[self] = nil

    table.clear (self.members)
    table.clear (self.at)
    setmetatable (self :: any, Dead)
end

function Members.__len (self: Held): number return #self.members end

function Members.__iter (self: Held) return ipairs (self.members) end

function Group.new (): Types.Group
    local self: Held = setmetatable ({ members = {}, at = {} }, Members) :: any
    live[self] = true

    return (self :: any) :: Types.Group
end

--[[
    A destroyed group never reaches this test. Every recipient form is told apart by reading a
    field off it first, and reading any field off a destroyed one is already the raise that says
    so.
]]
function Group.is (value: unknown): boolean return getmetatable (value :: any) == Members end

--[[
    Every group a departed player was in, thinned. Called once a leave, from the same sweep that
    releases every other structure keyed by them.
]]
function Group.dropped (player: Player)
    for of in live do
        (of :: any):remove (player)
    end
end

return table.freeze (Group)
