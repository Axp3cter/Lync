--!strict

--[=[
	Lync

	Typed buffer networking for Roblox. Milestone 1's surface: the schema language (`types`,
	`event`, `request`, `collection`) and `schema`, which plans a namespace into its IR.

	A schema module returns `Lync.schema(name, definitions)`. Declaration mistakes throw at the
	constructor's line, with a code from `docs/codes/`.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Dsl = require("@self/plan/dsl")
local Planner = require("@self/plan/planner")
local Types = require("@self/types")


-- Module ------------------------------------------------------------------------------------------

local Lync = {}


-- Private ----------------------------------------------------------------------------------------

local function atOf(source: string, line: number): { line: number, source: string }
	return { line = line, source = source }
end


-- Public ------------------------------------------------------------------------------------------

-- The constructors are untyped inside Lync; their types come from type functions the checker
-- cannot relate to the implementation, so each is cast once here.

--- The `t` table of codec constructors (v5.md §3.3).
Lync.types = (Dsl.types :: any) :: Types.T

--- Declares a collection (v5.md §3.4).
Lync.collection = (Dsl.collection :: any) :: Types.Collection

--- Declares an event (v5.md §3.4).
Lync.event = (Dsl.event :: any) :: Types.Event

--- Declares a request (v5.md §3.4).
Lync.request = (Dsl.request :: any) :: Types.Request


--[=[
	Plans a schema: checks every definition and computes its IR (v5.md §3.4, §4.6, §4.7).

	@param  name        the namespace's name, 1 to 64 bytes
	@param  definitions the definitions by name, each from `Lync.event`, `Lync.request` or
	                    `Lync.collection`
	@return the schema, holding its IR as `ir`
	@error  a declaration error at the line of the constructor that declared the mistake
]=]
function Lync.schema<Defs>(name: string, definitions: Defs): Types.Schema<Defs>
	local namespace = Planner.plan(name, definitions :: any, atOf(debug.info(2, "sl")))

	-- `_definitions` exists only in the type, for the views.
	return table.freeze({ ir = namespace }) :: any
end


return table.freeze(Lync)
