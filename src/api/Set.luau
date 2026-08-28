--!strict
--!optimize 2
-- The set handle: the server's records, the client's view of them, and the one key that splits.

local Base = require ("@src/codec/Base")
local Define = require ("@src/api/Define")
local Handles = require ("@src/runtime/Handles")
local Serial = require ("@src/shape/Serial")
local Sync = require ("@src/state/Sync")
local Types = require ("@src/Types")

local Set = {}
Set.__index = Set

-- Private -------------------------------------------------------------

-- The set this handle mutates. Only the server holds records in one.
local function owning (self: any, said: string): Sync.Sync
    local live = self.live
    return Define.reach (live, said, true):set (live.id :: number)
end

--[[
    The set this handle reads, or nothing where its namespace has not opened one.

    Nothing rather than a refusal, because a read is what a caller does to find out whether there is
    anything there, and a set before start holds nothing in exactly the way an empty one does.
]]
local function viewing (self: any): Sync.Sync?
    local live = self.live
    local session = live.session
    if session == nil then return nil end

    return session:set (live.id :: number)
end

-- What a set that has not opened iterates, so a walk before start is a walk and not a refusal.
local function barren (): (number?, any) return nil end

--[[
    A callback, attached whenever the caller liked.

    Set callbacks attach at any time for the reason listeners do, and the one that most needs it is
    `onAdded`: a client attaching after start would miss the seeding its own join asked for.
]]
local function watches (
    self: any,
    attach: (Sync.Sync, any) -> Types.Connection,
    fn: any
): Types.Connection
    local live = self.live
    return Handles.later (
        live,
        function (session) return attach (session:set (live.id :: number), fn) end
    )
end

-- Public --------------------------------------------------------------

-- What clears an optional field, since nothing else can.
Set.NONE = Sync.NONE

--[[
    The key is not here. A set is split by a field a caller names afterwards, and until they do,
    this declares one that goes whole to everybody.
]]
function Set.new <T>(of: Types.Codec<T>): Types.Set<T>
    --[[
        Level two is the caller, so a set refused at start is named against the line that declared
        it rather than against the start that did the refusing.
    ]]
    local file, line = debug.info (2, "sl")
    local self = {
        kind = "set" :: "set",
        of = of,
        keyField = nil :: string?,
        at = { file = file, line = line },
        live = Handles.live (),
    }

    return (setmetatable (self, Set) :: any) :: Types.Set<T>
end

--[[
    The field records are split by, and what an audience is later assigned against.

    Whether the field exists and whether its codec can be a key is settled at start against the
    compiled record, since there is no record to look in at the declaration.
]]
function Set.keyBy (self: any, field: string): any
    Define.declaring (self.live, "keyBy")
    self.keyField = field
    return self
end

-- The full record, under an id nothing else in this set holds.
function Set.add (self: any, id: number, record: any)
    local of = owning (self, "add")
    Sync.add (of, id, record)
end

-- Only the fields named, and only to whoever can already see the record they are on.
function Set.update (self: any, id: number, fields: any)
    local of = owning (self, "update")
    Sync.update (of, id, fields)
end

function Set.remove (self: any, id: number)
    local of = owning (self, "remove")
    Sync.remove (of, id)
end

--[[
    Everything at once, sent as one marker a partition rather than a removal an id. A listener is
    still told once a record, under a cause naming the clear that did it.
]]
function Set.clear (self: any)
    local of = owning (self, "clear")
    Sync.clear (of)
end

--[[
    Who sees the records under one key. An unkeyed set has no key to say it about.

    Refused rather than ignored: an audience on a set that goes to everybody is a caller who
    believes they have restricted something and has not.
]]
function Set.audience (self: any, key: any, to: Types.Recipient)
    local of = owning (self, "audience")
    if self.keyField == nil then
        Define.refuse (
            "audience is for a set split by keyBy, and this one goes to everybody",
            Define.naming (self.live, "audience")
        )
    end

    Sync.audience (of, key, to)
end

--[[
    The live record under an id, borrowed rather than copied.

    Nothing where this machine holds no record under it. On a client that is every id its audiences
    do not reach, as well as every id nobody has added.
]]
function Set.get (self: any, id: number): any?
    local of = viewing (self)
    if of == nil then return nil end

    return Sync.get (of, id)
end

function Set.__len (self: any): number
    local of = viewing (self)
    if of == nil then return 0 end

    return Sync.size (of)
end

-- Every record this machine holds, in no order a caller may rely on.
function Set.__iter (self: any): (any, any, any)
    local of = viewing (self)
    if of == nil then return barren, self, nil end

    return Sync.walk (of), self, nil
end

function Set.onAdded (self: any, fn: (number, any) -> ()): Types.Connection
    return watches (self, Sync.onAdded, fn)
end

function Set.onChanged (self: any, fn: (number, any, any?) -> ()): Types.Connection
    return watches (self, Sync.onChanged, fn)
end

function Set.onRemoved (self: any, fn: (number, Types.Cause) -> ()): Types.Connection
    return watches (self, Sync.onRemoved, fn)
end

-- The same for a set, which is the field it keys by and then the record under it.
function Set.describe (self: any): string
    return Serial.frame ({
        kind = "set",
        of = { cell = Base.cell (self.of) },
        keyField = self.keyField,
    })
end

return table.freeze (Set)
