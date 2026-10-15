--!strict
-- review-2 t2: `t.enum(Enum.Material)` typed `Enum.Material` (§3.3)? Run with --roblox.
-- The v5 attempt found type functions cannot read extern types; try structural inference via GetEnumItems.
type Codec<T> = { read _value: T }
local function make(): any return {} end
local function enumOf<T>(e: { GetEnumItems: (self: any) -> { T } }): Codec<T> return make() end
local c = enumOf(Enum.Material)
local _r: "REVEAL_enum" = c
