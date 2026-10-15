--!strict

--[=[
	Codes

	The registry of Lync's diagnostic codes: every code, the family that fixes its channel
	(v5.md §7.1, §7.2), and each fact's evidence fields (§7.3).

	`decoderRaised` and `schemaMismatch` are facts that are also reported natively (the first
	always, the second on a client), so their family is `fact`.

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
	| "notADefinition"
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
	| "vectorStep"
	| "messageTooLarge"
	| "unreliableTooLarge"
	| "valueRefused"
	| "wrongSide"
	| "configureRange"
	| "unknownTarget"
	| "overBudget"
	| "malformed"
	| "decoderRaised"
	| "tagMismatch"
	| "frameGap"
	| "desync"
	| "replayed"
	| "impossibleAck"
	| "repeatedHello"
	| "schemaMismatch"
	| "slotConflict"
	| "overLimit"
	| "unresolved"
	| "sendDropped"
	| "missedFlush"
	| "remotesMissing"
	| "suppressed"
	| "timeout"
	| "rejected"
	| "unanswered"
	| "left"
	| "shutdown"
	| "validatorError"
	| "validatorYielded"
	| "internal"
	| "zeroWidthElement"
	| "elementsTooMany"
	| "optionalPlacement"

-- Constants ---------------------------------------------------------------------------------------

const FAMILY: { [Code]: Family } = {
	unknownOption = "declaration",
	missingOption = "declaration",
	notACodec = "declaration",
	notADefinition = "declaration",
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
	vectorStep = "declaration",
	messageTooLarge = "declaration",
	unreliableTooLarge = "declaration",

	valueRefused = "caller",
	wrongSide = "caller",
	configureRange = "caller",
	unknownTarget = "caller",

	overBudget = "fact",
	malformed = "fact",
	decoderRaised = "fact",
	tagMismatch = "fact",
	frameGap = "fact",
	desync = "fact",
	replayed = "fact",
	impossibleAck = "fact",
	repeatedHello = "fact",
	schemaMismatch = "fact",
	slotConflict = "fact",
	overLimit = "fact",
	unresolved = "fact",
	sendDropped = "fact",
	missedFlush = "fact",
	remotesMissing = "fact",
	suppressed = "fact",

	timeout = "outcome",
	rejected = "outcome",
	unanswered = "outcome",
	left = "outcome",
	shutdown = "outcome",

	validatorError = "fault",
	validatorYielded = "fault",

	internal = "internal",

	zeroWidthElement = "declaration",
	elementsTooMany = "declaration",
	optionalPlacement = "declaration",
}
table.freeze(FAMILY)

-- Each fact's evidence fields, in the order `Facts.record` takes them; its registry page lists
-- the same order. `suppressed` has one field per suppressed reason instead.
const EVIDENCE: { [Code]: { string } } = {
	overBudget = table.freeze({ "lane", "bytes", "instances", "elements" }),
	malformed = table.freeze({ "lane", "rule" }),
	decoderRaised = table.freeze({ "lane" }),
	tagMismatch = table.freeze({ "lane", "expected" }),
	frameGap = table.freeze({ "skipped" }),
	desync = table.freeze({ "failures", "rekeySent" }),
	replayed = table.freeze({ "seq", "behind", "seen" }),
	impossibleAck = table.freeze({ "seq" }),
	repeatedHello = table.freeze({ "hashChanged" }),
	schemaMismatch = table.freeze({
		"version",
		"seedDiffers",
		"hashLow",
		"hashHigh",
		"unknownName",
	}),
	slotConflict = table.freeze({ "slot", "case" }),
	overLimit = table.freeze({ "perSecond", "burst" }),
	unresolved = table.freeze({ "what", "value" }),
	sendDropped = table.freeze({ "queue", "lane", "bytes" }),
	missedFlush = table.freeze({ "frames" }),
	remotesMissing = table.freeze({ "seconds" }),
}
table.freeze(EVIDENCE)

-- Public ------------------------------------------------------------------------------------------

--- The evidence fields of every fact but `suppressed`, in their registry order.
Codes.evidence = EVIDENCE

--- The family of every code.
Codes.family = FAMILY

return table.freeze(Codes)
