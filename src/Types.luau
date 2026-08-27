--!strict
--!optimize 2
-- The public type vocabulary: every type a consumer names, and the inference behind it.

-- Types ---------------------------------------------------------------

export type LogKind = "warn" | "error" | "debug"
export type Cause = "removed" | "cleared"
export type OutcomeCode = "timeout" | "unanswered" | "leave" | "shutdown"

--[[
    The three sentinels. Each carries a phantom field so the checker keeps them apart from one
    another and from any table a caller might pass instead.
]]
export type All = { read _all: true }
export type Except = { read _except: true }
export type None = { read _none: true }

export type Recipient = All | Except | Group | Player | { Player }

--[[
    What `define` takes, keyed by the names the definitions are reached under. Named rather than
    written inline so a caller assembling a namespace has something to annotate.
]]
export type Definition = Packet<unknown> | Query<unknown, unknown> | Set<unknown>
export type Definitions = { [string]: Definition }

export type Connection = {
    read connected: boolean,
    read disconnect: (self: Connection) -> (),
}

--[[
    Reused between decodes, so anything kept from it must be copied. `last` is stamped on every
    arrival, accepted or not.
]]
export type ValidateContext = {
    read player: Player?,
    read now: number,
    read last: number?,
}

export type LogData = {
    read file: string,
    read line: number,
    read player: Player?,
    read definition: string?,
    read [string]: unknown,
}

export type OutcomeData = {
    read definition: string,
    read elapsed: number?,
}

export type DefinitionStats = {
    read sent: number,
    read sentBytes: number,
    read received: number,
    read receivedBytes: number,
    read drops: number,
}

export type Stats = {
    read flushes: number,
    read sentBytes: number,
    read receivedBytes: number,
    read drops: number,
    read definitions: { [string]: DefinitionStats },
}

--[[
    The phantom `_T` is the whole inference story: it never exists at run time and Infer reads it
    back out below. `monotonic` takes any codec because a generic type may not name itself with a
    different argument. No trend marker sits beside it, an order being derived rather than
    declared.
]]
export type Codec<T> = {
    read _T: T,
    read validate: (
        self: Codec<T>,
        check: (value: T, ctx: ValidateContext) -> string?
    ) -> Codec<T>,
    read as: <U>(self: Codec<T>, to: (value: T) -> U, from: (value: U) -> T) -> Codec<U>,
    read monotonic: (self: Codec<T>) -> Codec<T>,
    read newest: (self: Codec<T>, hz: number?) -> Codec<T>,
}

--[[
    The value a codec carries. `Infer<Codec<Vector3>>` is `Vector3`, which is what lets a handler
    signature fall out of the schema with nothing annotated.
]]
export type function Infer (codec) return codec:readproperty (types.singleton ("_T")) end

--[[
    A table of codecs read as the record it describes, mapping each field to the value its codec
    carries. This is what `struct` returns the codec of.
]]
export type function Schema (fields)
    local record = types.newtable ()
    for key, property in fields:properties () do
        local codec = property.read or property.write
        record:setproperty (key, codec:readproperty (types.singleton ("_T")))
    end
    return record
end

--[[
    Every field is optional so a caller may omit it, and the clear sentinel is accepted on exactly
    the fields the record declares optional.
]]
export type function Update (record, none)
    if not (record:is ("table") or record:is ("class")) then return types.any end

    local fields = types.newtable ()
    for key, property in record:properties () do
        local field = property.read or property.write
        local isClearable = false
        if field:is ("union") then
            for _, part in field:components () do
                if part:is ("nil") then isClearable = true end
            end
        end
        local value = if isClearable then types.unionof (field, none) else field
        fields:setproperty (key, types.optional (value))
    end
    return fields
end

export type Packet<T> = {
    read unreliable: (self: Packet<T>) -> Packet<T>,
    read newest: (self: Packet<T>, hz: number?) -> Packet<T>,
    read timestamped: (self: Packet<T>) -> Packet<T>,
    read fireServer: (self: Packet<T>, value: T) -> (),
    read fireClient: (self: Packet<T>, recipient: Recipient, value: T) -> (),
    read onServer: (
        self: Packet<T>,
        fn: (value: T, player: Player, sent: number?) -> ()
    ) -> Connection,
    read onClient: (self: Packet<T>, fn: (value: T, sent: number?) -> ()) -> Connection,
    read describe: (self: Packet<T>) -> string,
}

--[[
    The client form yields for the reply. The server form takes a completion callback and never
    yields. Both answer `(true, reply)` or `(false, code, data)`, so a request never throws and
    never hangs.
]]
export type Outcome<R> = (ok: boolean, result: R | OutcomeCode, data: OutcomeData?) -> ()

export type Query<Q, R> = {
    read onServer: (self: Query<Q, R>, fn: (value: Q, player: Player) -> R) -> (),
    read onClient: (self: Query<Q, R>, fn: (value: Q) -> R) -> (),
    read request: ((
        self: Query<Q, R>,
        value: Q,
        timeout: number?
    ) -> (boolean, R | OutcomeCode, OutcomeData?)) & ((
        self: Query<Q, R>,
        client: Player,
        value: Q,
        complete: Outcome<R>,
        timeout: number?
    ) -> ()),
    read describe: (self: Query<Q, R>) -> string,
}

type SetFields<T> = {
    read keyBy: (self: Set<T>, field: string) -> Set<T>,
    read onAdded: (self: Set<T>, fn: (id: number, record: T) -> ()) -> Connection,
    read onChanged: (self: Set<T>, fn: (id: number, record: T, old: T?) -> ()) -> Connection,
    read onRemoved: (self: Set<T>, fn: (id: number, cause: Cause) -> ()) -> Connection,
    read add: (self: Set<T>, id: number, record: T) -> (),
    read update: (self: Set<T>, id: number, fields: Update<T, None>) -> (),
    read remove: (self: Set<T>, id: number) -> (),
    read clear: (self: Set<T>) -> (),
    read audience: (self: Set<T>, key: unknown, recipient: Recipient) -> (),
    read get: (self: Set<T>, id: number) -> T?,
    read describe: (self: Set<T>) -> string,
}

--[[
    `#set` counts the local view and `for id, record in set do` walks it, so both reads sit on the
    metatable rather than the record.
]]
type SetMeta<T> = {
    __len: (self: Set<T>) -> number,
    __iter: (
        self: Set<T>
    ) -> (({ [number]: T }, number) -> (number?, T), { [number]: T }, number),
}

--[[
    No key parameter. Luau widens a string argument to `string` rather than its singleton, a
    declaration inside the define literal has no annotation site, and a generic type may not name
    itself with a different argument, so a key type could never be carried here. A key on an unkeyed
    set is a programmer error the runtime throws on.
]]
export type Set<T> = typeof(setmetatable ({} :: SetFields<T>, {} :: SetMeta<T>))

type GroupFields = {
    read add: (self: Group, player: Player) -> (),
    read remove: (self: Group, player: Player) -> (),
    read has: (self: Group, player: Player) -> boolean,
    read destroy: (self: Group) -> (),
}

type GroupMeta = {
    __len: (self: Group) -> number,
    __iter: (self: Group) -> (({ Player }, number) -> (number?, Player), { Player }, number),
}

export type Group = typeof(setmetatable ({} :: GroupFields, {} :: GroupMeta))

return nil
