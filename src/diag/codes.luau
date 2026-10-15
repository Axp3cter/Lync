--!strict

--[=[
	Codes

	The registry of Lync's diagnostic codes: every code and the family that fixes its channel
	(v5.md §7.1, §7.2).

	The codes are kept equal to the pages in `docs/codes/`, and `test/diag/registry.spec.luau`
	fails when they differ. Codes are never renamed or reused; later milestones only add them.
]=]

-- Module ------------------------------------------------------------------------------------------

local Codes = {}

-- Types -------------------------------------------------------------------------------------------

--- The kind of mistake or event a code reports, which fixes how it reaches the developer.
export type Family =
	| "declaration"
	| "caller"
	| "fact"
	| "outcome"
	| "fault"
	| "build"
	| "internal"

--- Every code Lync raises or reports.
export type Code =
	| "unknownOption"
	| "missingOption"
	| "notACodec"
	| "intBounds"
	| "numberStep"
	| "numberStepIsInt"
	| "paramRange"
	| "enumItems"
	| "mapKey"
	| "newestPlacement"
	| "newestWidth"
	| "unionKindField"
	| "duplicateName"
	| "nameLength"
	| "messageTooLarge"
	| "unreliableTooLarge"
	| "valueRefused"

-- Constants ---------------------------------------------------------------------------------------

const FAMILY: { [Code]: Family } = {
	unknownOption = "declaration",
	missingOption = "declaration",
	notACodec = "declaration",
	intBounds = "declaration",
	numberStep = "declaration",
	numberStepIsInt = "declaration",
	paramRange = "declaration",
	enumItems = "declaration",
	mapKey = "declaration",
	newestPlacement = "declaration",
	newestWidth = "declaration",
	unionKindField = "declaration",
	duplicateName = "declaration",
	nameLength = "declaration",
	messageTooLarge = "declaration",
	unreliableTooLarge = "declaration",

	valueRefused = "caller",
}
table.freeze(FAMILY)

-- Public ------------------------------------------------------------------------------------------

--- The family of every code.
Codes.family = FAMILY

return table.freeze(Codes)
