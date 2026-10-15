--!strict

--[=[
	Spec

	Reads the spec: the claims in the claim files of `spec/`, and what the README of `spec/` says
	about them, which is the prefix of each file, the measurements, and how a claim is proved.

	A claim file is every `.md` file in `spec/` except the README, and the README lists each one
	with the prefix that its ids start with.

	A claim is a table row `| <id> | <statement> |` under the header `| ID | Claim |`. Its id is the
	prefix letter, a hyphen and a positive whole number, and a pipe inside a statement is written
	`\|`.

	A claim whose statement starts "Withdrawn." stays in its file as a row, so its number is never
	used again, and it is not counted as a claim.

	A provisional statement ends with "(provisional M-n)." or "(provisional M-n, M-m).", naming the
	measurements of the README's register that settle it.

	A statement may end with "(waived: <reason>).", which records why a Waived claim is not proved
	yet, and every report of the claim shows the reason.

	Every id in a statement, and every claim that the register or the proof kinds list, must name a
	claim or a measurement that exists.

	What breaks these rules is not a failure of reading: it comes back as problems, one finding
	each.

	Every operation here yields, except countedClaimsOf, locationOf, numbersOf, spellByArea,
	spellIds and withdrawnCountOf.

	A failure outside the scripts, such as a file that cannot be read, comes back as a Result.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Files     = require("../system/Files")
local Paths     = require("./Paths")
local stringext = require("@std/stringext")
local Types     = require("../Types")


-- Module ------------------------------------------------------------------------------------------

local Spec = {}


-- Types -------------------------------------------------------------------------------------------

--- One of the ways that the spec says a claim is proved.
export type ProofKind =
	| "Tested"
	| "Scripted"
	| "Typed"
	| "Inferred"
	| "Declared"
	| "Reviewed"
	| "Waived"


--- Who judges that a claim is proved: a test that cites it, a type runner, tsc, or a reviewer.
type Judge =
	| "Test"
	| "TypeRunner"
	| "Tsc"
	| "Review"


--[=[
	A claim file of the spec, and the prefix that every id in it starts with.

	@field file   the path of the claim file
	@field prefix the one uppercase letter that begins each id of the file
]=]
export type Area = {
	read file:   string,
	read prefix: string,
}


--[=[
	One claim: a row of a claim file.

	@field id          the claim's id, such as "A-36"
	@field prefix      the letter that begins `id`
	@field number      the positive whole number that ends `id`
	@field location    the file and line of the row, such as "spec/api.md:78"
	@field isWithdrawn whether the statement starts "Withdrawn.", so that the claim is not counted
	@field proofKind   how the spec says the claim is proved
	@field reason      why the claim is waived, from the marker that ends its statement, else nil
]=]
export type Claim = {
	read id:          string,
	read prefix:      string,
	read number:      number,
	read location:    string,
	read isWithdrawn: boolean,
	read proofKind:   ProofKind,
	read reason:      string?,
}


--[=[
	Everything that the spec holds.

	@field areas     the claim files, in the order that the README lists them
	@field claims    every claim row, withdrawn ones included, file by file in the order of `areas`
	@field claimById the same claims, by id
	@field problems  what breaks the spec's rules, one finding each, empty when the spec is sound
]=]
export type Contents = {
	read areas:     { read Area },
	read claims:    { read Claim },
	read claimById: { read [string]: Claim },
	read problems:  { string },
}


--[=[
	A row of a table, below its header.

	@field cells the cells without the outer pipes, each trimmed
	@field line  the line of the file that holds the row
]=]
type Row = {
	read cells: { string },
	read line:  number,
}


--[=[
	An id that stands as a whole word in a text.

	@field id     the id as written, such as "A-36"
	@field prefix the letter that begins `id`
	@field number the number that ends `id`
]=]
type Token = {
	read id:     string,
	read prefix: string,
	read number: number,
}


--[=[
	Ids from one to another, such as "A-34 to A-36", or a single id as a range of one.

	@field first the id that the range starts at
	@field last  the id that the range ends at
]=]
type IdRange = {
	read first: Token,
	read last:  Token,
}


--[=[
	Claim numbers from `first` to `last`, both included.

	@field first the lowest number
	@field last  the highest number
]=]
type NumberRange = {
	read first: number,
	read last:  number,
}


--[=[
	An id that the README or a statement names, to be found among the claims and measurements.

	@field id       the id as written
	@field location the file and line that name it
	@field owner    what names it, such as "claim A-5", which a problem names
]=]
type Reference = {
	read id:       string,
	read location: string,
	read owner:    string,
}


--[=[
	The claims of one prefix that the README gives one proof kind.

	@field kind   the proof kind
	@field prefix the letter that begins the ids
	@field first  the lowest number covered
	@field last   the highest number covered
]=]
type ProofRange = {
	read kind:   ProofKind,
	read prefix: string,
	read first:  number,
	read last:   number,
}


--[=[
	What the README says, apart from the claims.

	@field areas          the claim files with their prefixes
	@field idPrefixes     the letters that begin an id: each file's prefix, and the measurements'
	@field measurementIds the ids in the register of measurements
	@field proofRanges    the proof kinds and the claims that each covers
	@field references     the ids that the register and the proof kinds name
]=]
type Readme = {
	read areas:          { read Area },
	read idPrefixes:     { read [string]: true },
	read measurementIds: { read [string]: true },
	read proofRanges:    { read ProofRange },
	read references:     { read Reference },
}


--[=[
	What reading the claim files has found so far.

	@field claims     the claims read
	@field claimById  the same claims, by id
	@field references the ids that statements name
	@field problems   the findings so far
]=]
type Reading = {
	read claims:     { Claim },
	read claimById:  { [string]: Claim },
	read references: { Reference },
	read problems:   { string },
}


-- Constants ---------------------------------------------------------------------------------------

--- Matches the carriage return that a Windows checkout leaves before the end of a line.
const CARRIAGE_RETURN_PATTERN = "\r$"


--- Matches a backslash and a pipe, which together are a pipe that belongs to a cell.
const ESCAPED_PIPE_PATTERN = "\\|"


--- Captures the letter and the digits of an id that stands as a whole word in a text.
const ID_WORD_PATTERN = "%f[%w](%u)%-(%d+)%f[%W]"


--- Captures the prefix letter and the number of an id, whose number has no leading zero.
const ID_PATTERN = "^(%u)%-([1-9]%d*)$"


--- Captures the text of a link, such as "api.md" in "[api.md](api.md)".
const LINK_TEXT_PATTERN = "^%[(.-)%]%(.-%)$"


--- Matches the id of a measurement, which begins with M.
const MEASUREMENT_ID_PATTERN = "^M%-[1-9]%d*$"


--- Matches a prefix: one uppercase letter.
const PREFIX_PATTERN = "^%u$"


--- Captures the reason in the marker that ends the statement of a waived claim.
const WAIVER_PATTERN = "%(waived: (.+)%)%.$"


--- Matches the end of a provisional statement that names one measurement.
const PROVISIONAL_ONE_PATTERN = "%(provisional M%-[1-9]%d*%)%.$"


--- Matches the end of a provisional statement that names two measurements.
const PROVISIONAL_TWO_PATTERN = "%(provisional M%-[1-9]%d*, M%-[1-9]%d*%)%.$"


--- Captures the letters and the digits of the two ids in a range such as "A-34 to A-36".
const RANGE_PATTERN = "%f[%w](%u)%-(%d+) to (%u)%-(%d+)%f[%W]"


--- Matches a cell of the row under a table's header, such as "---" or ":-:".
const SEPARATOR_CELL_PATTERN = "^:?%-+:?$"


--- Stands for an escaped pipe while a row is split at its pipes.
const PIPE_MARK = "\x01"


--- Begins every row of a table.
const ROW_MARK = "|"


--- The text that begins the marker of a provisional statement.
const PROVISIONAL_MARK = "(provisional"


--- The text that begins the statement of a withdrawn claim.
const WITHDRAWN_MARK = "Withdrawn."


--- The letter that begins the id of a measurement, which no file may take as its prefix.
const MEASUREMENT_PREFIX = "M"


--- The fewest consecutive ids that are written as a range.
const MIN_RANGE_LENGTH = 3


--[=[
	The first piece of a row split at its pipes that holds a cell.

	The piece before the leading pipe is empty.
]=]
const FIRST_CELL_PIECE = 2


--- The lines that a table's header and the separator row below it take.
const HEADER_LINE_COUNT = 2


--- The positions of the cells that are read by position: statement, prefix, claims, and suits.
const CLAIM_STATEMENT_CELL    = 2
const FILE_PREFIX_CELL        = 2
const MEASUREMENT_CLAIMS_CELL = 4
const PROOF_SUITS_CELL        = 3


--- How a claim is proved when the README gives it no other proof kind.
const DEFAULT_PROOF_KIND: ProofKind = "Tested"


--- The cells of the header of a claim table.
const CLAIM_HEADER: { read string } = { "ID", "Claim" }
table.freeze(CLAIM_HEADER)


--- The cells of the header of the README's table of claim files.
const FILE_HEADER: { read string } = {
	"File",
	"Prefix",
	"Area",
}
table.freeze(FILE_HEADER)


--- The cells of the header of the README's register of measurements.
const MEASUREMENT_HEADER: { read string } = {
	"M",
	"Settles",
	"Rule",
	"Claims",
}
table.freeze(MEASUREMENT_HEADER)


--- The cells of the header of the README's table of proof kinds.
const PROOF_HEADER: { read string } = {
	"Kind",
	"Proof",
	"Suits",
}
table.freeze(PROOF_HEADER)


--- Every proof kind, in the order that the README lists them.
const PROOF_KINDS: { read ProofKind } = {
	"Tested",
	"Scripted",
	"Typed",
	"Inferred",
	"Declared",
	"Reviewed",
	"Waived",
}
table.freeze(PROOF_KINDS)


--- Who judges that a claim of each proof kind is proved.
const JUDGE_BY_KIND: Types.Complete<{ read [ProofKind]: Judge }> = {
	Tested   = "Test",
	Scripted = "Test",

	Typed    = "TypeRunner",
	Inferred = "TypeRunner",

	Declared = "Tsc",

	Reviewed = "Review",
	Waived   = "Review",
}
table.freeze(JUDGE_BY_KIND)


-- Private -----------------------------------------------------------------------------------------

local function locationOf(path: string, line: number): string
	return `{path}:{line}`
end


local function linesOf(text: string): { string }
	local pieces = string.split(text, "\n")
	local lines  = table.create(#pieces) :: { string }
	for i, piece in pieces do
		local line = string.gsub(piece, CARRIAGE_RETURN_PATTERN, "")
		lines[i]   = line
	end

	return lines
end


--[=[
	Splits a table row into its cells.

	@param  line a line that begins with a pipe, whose escaped pipes belong to its cells
	@return the cells without the outer pipes, each trimmed, with its escaped pipes written plainly
]=]
local function cellsOf(line: string): { string }
	local masked = string.gsub(line, ESCAPED_PIPE_PATTERN, PIPE_MARK)
	local pieces = string.split(masked, "|")

	local lastPiece = #pieces
	if stringext.trim(pieces[lastPiece]) == "" then
		lastPiece -= 1
	end

	local cells: { string } = {}
	for i = FIRST_CELL_PIECE, lastPiece do
		local plain = string.gsub(pieces[i], PIPE_MARK, "|")
		table.insert(cells, stringext.trim(plain))
	end

	return cells
end


local function hasHeader(line: string, header: { read string }): boolean
	if not stringext.hasPrefix(line, ROW_MARK) then
		return false
	end

	local cells = cellsOf(line)
	if #cells ~= #header then
		return false
	end

	for i, name in header do
		if cells[i] ~= name then
			return false
		end
	end

	return true
end


local function isSeparator(line: string): boolean
	if not stringext.hasPrefix(line, ROW_MARK) then
		return false
	end

	local cells = cellsOf(line)
	if #cells == 0 then
		return false
	end

	for _, cell in cells do
		if string.find(cell, SEPARATOR_CELL_PATTERN) == nil then
			return false
		end
	end

	return true
end


--[=[
	Collects the rows of every table whose header is `header`.

	A table is its header, a separator row, and the rows that follow until a line that is not a row.

	@param  path     the file that `lines` came from, which a problem names
	@param  lines    the lines of the file
	@param  header   the cells that the header of a wanted table has
	@param  problems where a row with the wrong number of cells is reported and left out
	@return the rows of those tables, in the order of the file
]=]
local function rowsUnder(
	path:     string,
	lines:    { read string },
	header:   { read string },
	problems: { string }
): { Row }
	local rows: { Row } = {}
	local i             = 1
	while i <= #lines do
		local nextLine = lines[i + 1] or ""
		local isTable  = hasHeader(lines[i], header) and isSeparator(nextLine)
		if not isTable then
			i += 1
			continue
		end

		i += HEADER_LINE_COUNT
		while
			i <= #lines
			and stringext.hasPrefix(lines[i], ROW_MARK)
		do
			local cells = cellsOf(lines[i])
			if #cells == #header then
				table.insert(rows, { cells = cells, line = i })
			else
				local requirement = `row must have {#header} cells`
				local advice      = "a pipe inside a cell is written \\|"
				local location    = locationOf(path, i)
				table.insert(problems, `{location}: {requirement}, got {#cells}; {advice}`)
			end

			i += 1
		end
	end

	return rows
end


local function tokenOf(letter: string, digits: string): Token
	return {
		id     = `{letter}-{digits}`,
		prefix = letter,
		number = assert(tonumber(digits), "the digits of an id must be a number"),
	}
end


local function tokensIn(text: string): { Token }
	local tokens: { Token } = {}
	for letter, digits in string.gmatch(text, ID_WORD_PATTERN) do
		table.insert(tokens, tokenOf(letter, digits))
	end

	return tokens
end


--[=[
	Finds the ids in `text`, each range of two ids as one entry.

	@param  text the text to search, such as the cell that lists the claims of a proof kind
	@return the ranges first, then every id that is not part of one
]=]
local function idRangesIn(text: string): { IdRange }
	local idRanges: { IdRange } = {}
	for firstLetter, firstDigits, lastLetter, lastDigits in string.gmatch(text, RANGE_PATTERN) do
		table.insert(idRanges, {
			first = tokenOf(firstLetter, firstDigits),
			last  = tokenOf(lastLetter, lastDigits),
		})
	end

	local alone = string.gsub(text, RANGE_PATTERN, "")
	for _, token in tokensIn(alone) do
		table.insert(idRanges, { first = token, last = token })
	end

	return idRanges
end


local function addReferences(
	references: { Reference },
	text:       string,
	location:   string,
	owner:      string,
	idPrefixes: { read [string]: true }
): ()
	for _, token in tokensIn(text) do
		if idPrefixes[token.prefix] then
			table.insert(references, {
				id       = token.id,
				location = location,
				owner    = owner,
			})
		end
	end
end


local function toProofKind(word: string): ProofKind?
	for _, kind in PROOF_KINDS do
		if kind == word then
			return kind
		end
	end

	return nil
end


local function spellNumberRange(prefix: string, numberRange: NumberRange): string
	if numberRange.last - numberRange.first + 1 < MIN_RANGE_LENGTH then
		local spelled: { string } = {}
		for i = numberRange.first, numberRange.last do
			table.insert(spelled, `{prefix}-{i}`)
		end

		return table.concat(spelled, ", ")
	end

	return `{prefix}-{numberRange.first} to {prefix}-{numberRange.last}`
end


local function spellNumberRanges(prefix: string, numberRanges: { read NumberRange }): string
	local spelled = table.create(#numberRanges) :: { string }
	for i, numberRange in numberRanges do
		spelled[i] = spellNumberRange(prefix, numberRange)
	end

	return table.concat(spelled, ", ")
end


local function numberRangesOf(numbers: { read number }): { NumberRange }
	local numberRanges: { NumberRange } = {}
	local rangeStart                    = 1
	for i, number in numbers do
		local nextNumber = numbers[i + 1] or 0
		if nextNumber == number + 1 then
			continue
		end

		table.insert(numberRanges, { first = numbers[rangeStart], last = number })
		rangeStart = i + 1
	end

	return numberRanges
end


local function gapsOf(numbers: { read number }): { NumberRange }
	local gaps: { NumberRange } = {}
	local expected              = 1
	for _, number in numbers do
		if number > expected then
			table.insert(gaps, { first = expected, last = number - 1 })
		end

		expected = number + 1
	end

	return gaps
end


local function readAreas(path: string, lines: { read string }, problems: { string }): { Area }
	local areas:        { Area }           = {}
	local seenPrefixes: { [string]: true } = {}
	for _, row in rowsUnder(path, lines, FILE_HEADER, problems) do
		local location = locationOf(path, row.line)

		local fileName = string.match(row.cells[1], LINK_TEXT_PATTERN)
		if fileName == nil then
			table.insert(problems, `{location}: file must be a link, got "{row.cells[1]}"`)
			continue
		end

		local prefix = row.cells[FILE_PREFIX_CELL]
		if string.find(prefix, PREFIX_PATTERN) == nil then
			local requirement = "prefix must be one uppercase letter"
			table.insert(problems, `{location}: {requirement}, got "{prefix}"`)
			continue
		end

		if prefix == MEASUREMENT_PREFIX then
			local requirement = "prefix must not be the letter of the measurements"
			table.insert(problems, `{location}: {requirement}, got "{prefix}"`)
			continue
		end

		if seenPrefixes[prefix] then
			local requirement = "prefix must belong to one file"
			table.insert(problems, `{location}: {requirement}, got "{prefix}" again`)
			continue
		end

		seenPrefixes[prefix] = true
		table.insert(areas, { file = `{Paths.FOLDER.spec}/{fileName}`, prefix = prefix })
	end

	if #areas == 0 then
		local requirement = `{path} must list the claim files in a table headed File, Prefix, Area`
		table.insert(problems, `{requirement}, got none`)
	end

	return areas
end


local function idPrefixesOf(areas: { read Area }): { [string]: true }
	local idPrefixes: { [string]: true } = { [MEASUREMENT_PREFIX] = true }
	for _, area in areas do
		idPrefixes[area.prefix] = true
	end

	return idPrefixes
end


local function readMeasurements(
	path:       string,
	lines:      { read string },
	idPrefixes: { read [string]: true },
	references: { Reference },
	problems:   { string }
): { [string]: true }
	local measurementIds: { [string]: true } = {}
	for _, row in rowsUnder(path, lines, MEASUREMENT_HEADER, problems) do
		local location = locationOf(path, row.line)

		local id = row.cells[1]
		if string.find(id, MEASUREMENT_ID_PATTERN) == nil then
			local requirement = "measurement id must be M-n for a whole n"
			table.insert(problems, `{location}: {requirement}, got "{id}"`)
			continue
		end

		if measurementIds[id] then
			table.insert(problems, `{location}: measurement must be listed once, got "{id}" again`)
			continue
		end

		measurementIds[id] = true
		local claimsText   = row.cells[MEASUREMENT_CLAIMS_CELL]
		addReferences(references, claimsText, location, `measurement {id}`, idPrefixes)
	end

	return measurementIds
end


local function readProofRanges(
	path:       string,
	lines:      { read string },
	idPrefixes: { read [string]: true },
	references: { Reference },
	problems:   { string }
): { ProofRange }
	local proofRanges: { ProofRange } = {}
	for _, row in rowsUnder(path, lines, PROOF_HEADER, problems) do
		local location = locationOf(path, row.line)

		local kindWord = row.cells[1]
		local kind     = toProofKind(kindWord)
		if kind == nil then
			local requirement = "proof kind must be a known one"
			table.insert(problems, `{location}: {requirement}, got "{kindWord}"`)
			continue
		end

		local owner = `proof kind {kind}`
		for _, idRange in idRangesIn(row.cells[PROOF_SUITS_CELL]) do
			local first = idRange.first
			local last  = idRange.last
			if not idPrefixes[first.prefix] then
				continue
			end

			if
				first.prefix ~= last.prefix
				or first.number > last.number
			then
				local requirement = "range of ids must run upward within one prefix"
				table.insert(problems, `{location}: {requirement}, got {first.id} to {last.id}`)
				continue
			end

			table.insert(references, {
				id       = first.id,
				location = location,
				owner    = owner,
			})

			if last.id ~= first.id then
				table.insert(references, {
					id       = last.id,
					location = location,
					owner    = owner,
				})
			end

			table.insert(proofRanges, {
				kind   = kind,
				prefix = first.prefix,
				first  = first.number,
				last   = last.number,
			})
		end
	end

	return proofRanges
end


local function readReadme(text: string, problems: { string }): Readme
	local path  = Paths.FILE.specReadme
	local lines = linesOf(text)

	local areas      = readAreas(path, lines, problems)
	local idPrefixes = idPrefixesOf(areas)

	local references: { Reference } = {}

	local measurementIds = readMeasurements(path, lines, idPrefixes, references, problems)
	local proofRanges    = readProofRanges(path, lines, idPrefixes, references, problems)

	return {
		areas          = areas,
		idPrefixes     = idPrefixes,
		measurementIds = measurementIds,
		proofRanges    = proofRanges,
		references     = references,
	}
end


--[=[
	Finds the proof kind that the README gives to a claim.

	@param  proofRanges the proof kinds that the README lists, with the claims each one covers
	@param  id          the claim's id, which a problem names
	@param  location    where the claim's row is, which a problem names
	@param  prefix      the letter that begins the claim's id
	@param  number      the number that ends the claim's id
	@param  problems    where a claim that two proof kinds cover is reported
	@return the kind that covers the claim, or the default kind when none does
]=]
local function proofKindOf(
	proofRanges: { read ProofRange },
	id:          string,
	location:    string,
	prefix:      string,
	number:      number,
	problems:    { string }
): ProofKind
	local coveringKinds: { ProofKind } = {}
	for _, proofRange in proofRanges do
		if
			proofRange.prefix == prefix
			and number >= proofRange.first
			and number <= proofRange.last
		then
			table.insert(coveringKinds, proofRange.kind)
		end
	end

	local kind = coveringKinds[1]
	if kind == nil then
		return DEFAULT_PROOF_KIND
	end

	for _, coveringKind in coveringKinds do
		if coveringKind ~= kind then
			local requirement = "claim must have one proof kind"
			local both        = `{kind} and {coveringKind}`
			table.insert(problems, `{location}: {requirement}, got {id} under {both}`)
			break
		end
	end

	return kind
end


local function confirmProvisional(location: string, statement: string, problems: { string }): ()
	if string.find(statement, PROVISIONAL_MARK, 1, true) == nil then
		return
	end

	if
		string.find(statement, PROVISIONAL_ONE_PATTERN) ~= nil
		or string.find(statement, PROVISIONAL_TWO_PATTERN) ~= nil
	then
		return
	end

	local requirement = 'a provisional statement must end with "(provisional M-n)."'
	table.insert(problems, `{location}: {requirement}, got "{statement}"`)
end


--[=[
	Adds the claim in `row` to `reading`, when the row is one that the rules accept.

	@param reading what the claim joins, and where its problems and references are added
	@param readme  what the README says about proof kinds and prefixes
	@param area    the claim file that holds the row
	@param row     the row to read, whose first cell is the id and whose second is the statement
]=]
local function addClaim(reading: Reading, readme: Readme, area: Area, row: Row): ()
	local location = locationOf(area.file, row.line)
	local problems = reading.problems

	local idText    = row.cells[1]
	local statement = row.cells[CLAIM_STATEMENT_CELL]

	local prefix, digits = string.match(idText, ID_PATTERN)
	if
		prefix == nil
		or digits == nil
	then
		table.insert(problems, `{location}: first cell must be a claim id, got "{idText}"`)
		return
	end

	if prefix ~= area.prefix then
		local requirement = `claim id must start with the prefix of {area.file}`
		table.insert(problems, `{location}: {requirement}, got "{prefix}"`)
		return
	end

	local existing = reading.claimById[idText]
	if existing ~= nil then
		local requirement = "claim must be listed once"
		local firstPlace  = existing.location
		table.insert(problems, `{location}: {requirement}, got {idText} also at {firstPlace}`)
		return
	end

	local number = assert(tonumber(digits), "the digits of an id must be a number")
	local claim: Claim = {
		id          = idText,
		prefix      = prefix,
		number      = number,
		location    = location,
		isWithdrawn = stringext.hasPrefix(statement, WITHDRAWN_MARK),
		proofKind   = proofKindOf(readme.proofRanges, idText, location, prefix, number, problems),
		reason      = string.match(statement, WAIVER_PATTERN),
	}

	table.insert(reading.claims, claim)
	reading.claimById[idText] = claim

	confirmProvisional(location, statement, problems)
	addReferences(reading.references, statement, location, `claim {idText}`, readme.idPrefixes)
end


local function findGaps(areas: { read Area }, claims: { read Claim }, problems: { string }): ()
	local numbersByPrefix: { [string]: { number } } = {}
	for _, claim in claims do
		local numbers = numbersByPrefix[claim.prefix]
		if numbers == nil then
			numbers                       = {}
			numbersByPrefix[claim.prefix] = numbers
		end

		table.insert(numbers, claim.number)
	end

	for _, area in areas do
		local numbers = numbersByPrefix[area.prefix] or {}
		table.sort(numbers)

		local gaps = gapsOf(numbers)
		if #gaps == 0 then
			continue
		end

		local requirement = "claims must be numbered from 1 without a gap"
		local missing     = spellNumberRanges(area.prefix, gaps)
		table.insert(problems, `{area.file}: {requirement}, got none of {missing}`)
	end
end


local function isResolved(
	reference:      Reference,
	claimById:      { read [string]: Claim },
	measurementIds: { read [string]: true }
): boolean
	if string.sub(reference.id, 1, 1) == MEASUREMENT_PREFIX then
		return measurementIds[reference.id] ~= nil
	end

	return claimById[reference.id] ~= nil
end


local function findUnresolved(
	references:     { read Reference },
	claimById:      { read [string]: Claim },
	measurementIds: { read [string]: true },
	problems:       { string }
): ()
	for _, reference in references do
		if isResolved(reference, claimById, measurementIds) then
			continue
		end

		local requirement = `{reference.owner} must name only claims and measurements that exist`
		table.insert(problems, `{reference.location}: {requirement}, got {reference.id}`)
	end
end


--[=[
	Lists the claim files that stand in `spec/`.

	@return the `.md` files directly in `spec/` except the README, or why they could not be listed
]=]
local function listClaimFiles(): Types.Result<{ string }>
	local inspected = Files.inspect(Paths.FOLDER.spec)
	if not inspected.ok then
		return inspected
	end

	local kind = inspected.value
	if kind ~= "Folder" then
		local requirement = `{Paths.FOLDER.spec} must be a folder in the working directory`
		local found       = if kind == nil then "nothing" else kind
		return { ok = false, error = `{requirement}, got {found}` }
	end

	local listed = Files.list(Paths.FOLDER.spec)
	if not listed.ok then
		return listed
	end

	local folderPrefix      = `{Paths.FOLDER.spec}/`
	local files: { string } = {}
	for _, path in listed.value do
		local name = stringext.removePrefix(path, folderPrefix)
		if
			stringext.hasSuffix(name, ".md")
			and string.find(name, "/", 1, true) == nil
			and path ~= Paths.FILE.specReadme
		then
			table.insert(files, path)
		end
	end

	return { ok = true, value = files }
end


--[=[
	Reads the claim files that the README lists, and reports the files that it and the folder
	disagree about.

	@param  reading what the claims join, and where the problems are added
	@param  readme  what the README says, whose areas are the files to read
	@param  files   the claim files that stand in `spec/`
	@return a success once every listed file in `spec/` is read, or why one could not be
]=]
local function readClaimFiles(
	reading: Reading,
	readme:  Readme,
	files:   { read string }
): Types.Result<nil>
	local presentPaths: { [string]: true } = {}
	for _, path in files do
		presentPaths[path] = true
	end

	local listedPaths: { [string]: true } = {}
	for _, area in readme.areas do
		listedPaths[area.file] = true

		if not presentPaths[area.file] then
			local requirement = "listed claim file must exist"
			local location    = Paths.FILE.specReadme
			table.insert(reading.problems, `{location}: {requirement}, got {area.file}`)
			continue
		end

		local read = Files.read(area.file)
		if not read.ok then
			return read
		end

		local rows = rowsUnder(area.file, linesOf(read.value), CLAIM_HEADER, reading.problems)
		for _, row in rows do
			addClaim(reading, readme, area, row)
		end
	end

	for _, path in files do
		if listedPaths[path] then
			continue
		end

		local requirement = `claim file must be listed in {Paths.FILE.specReadme}`
		table.insert(reading.problems, `{path}: {requirement}, got none`)
	end

	return { ok = true, value = nil }
end


-- Public ------------------------------------------------------------------------------------------

--- Who judges that a claim of each proof kind is proved.
Spec.JUDGE_BY_KIND = JUDGE_BY_KIND


--- Every proof kind, in the order that the README of the spec lists them.
Spec.PROOF_KINDS = PROOF_KINDS


--[=[
	Returns the counted claims of one proof kind, which are those that are not withdrawn.

	@param  contents the spec to take the claims from
	@param  kind     the proof kind whose claims are wanted
	@return the claims of `kind`, in the order of `contents.claims`
]=]
function Spec.countedClaimsOf(contents: Contents, kind: ProofKind): { Claim }
	local claims: { Claim } = {}
	for _, claim in contents.claims do
		if claim.isWithdrawn then
			continue
		end

		if claim.proofKind ~= kind then
			continue
		end

		table.insert(claims, claim)
	end

	return claims
end


--[=[
	Spells where a line of a file is.

	@param  path the file
	@param  line the line, counted from 1
	@return the place as `path:line`, such as "spec/api.md:78"
]=]
function Spec.locationOf(path: string, line: number): string
	return locationOf(path, line)
end


--[=[
	Collects the numbers of the claims that have one prefix.

	@param  claims the claims to look through
	@param  prefix the letter that begins the wanted ids
	@return their numbers, each once, in ascending order
]=]
function Spec.numbersOf(claims: { read Claim }, prefix: string): { number }
	local numbers: { number } = {}
	for _, claim in claims do
		if claim.prefix == prefix then
			table.insert(numbers, claim.number)
		end
	end

	table.sort(numbers)

	return numbers
end


--[=[
	Reads the README and the claim files of the spec, and finds what breaks the spec's rules.

	Every file is read even when an earlier one has problems, so that the problems come all at once.

	@return the spec and its problems, or why a file could not be read or listed
]=]
function Spec.read(): Types.Result<Contents>
	local listed = listClaimFiles()
	if not listed.ok then
		return listed
	end

	local readmeRead = Files.read(Paths.FILE.specReadme)
	if not readmeRead.ok then
		return readmeRead
	end

	local reading: Reading = {
		claims     = {},
		claimById  = {},
		references = {},
		problems   = {},
	}

	local readme = readReadme(readmeRead.value, reading.problems)

	local filesRead = readClaimFiles(reading, readme, listed.value)
	if not filesRead.ok then
		return filesRead
	end

	findGaps(readme.areas, reading.claims, reading.problems)

	for _, reference in readme.references do
		table.insert(reading.references, reference)
	end

	findUnresolved(reading.references, reading.claimById, readme.measurementIds, reading.problems)

	return {
		ok    = true,
		value = {
			areas     = readme.areas,
			claims    = reading.claims,
			claimById = reading.claimById,
			problems  = reading.problems,
		},
	}
end


--[=[
	Spells the ids of some claims file by file, as a line for each file that has any.

	@param  contents the spec whose files the claims belong to
	@param  claims   the claims to spell
	@return the lines, in the order of the files, such as "  A: A-1 to A-3, A-5"
]=]
function Spec.spellByArea(contents: Contents, claims: { read Claim }): { string }
	local lines: { string } = {}
	for _, area in contents.areas do
		local numbers = Spec.numbersOf(claims, area.prefix)
		if #numbers == 0 then
			continue
		end

		table.insert(lines, `  {area.prefix}: {Spec.spellIds(area.prefix, numbers)}`)
	end

	return lines
end


--[=[
	Spells ids of one prefix as a list, writing each stretch of three or more as a range.

	@param  prefix  the letter that begins every id
	@param  numbers the numbers that end the ids, each once, in ascending order
	@return the ids, such as "A-1 to A-3, A-5"
]=]
function Spec.spellIds(prefix: string, numbers: { read number }): string
	return spellNumberRanges(prefix, numberRangesOf(numbers))
end


--[=[
	Counts the claims that are withdrawn.

	@param  contents the spec whose claims are counted
	@return how many of the claims are withdrawn
]=]
function Spec.withdrawnCountOf(contents: Contents): number
	local withdrawnCount = 0
	for _, claim in contents.claims do
		if claim.isWithdrawn then
			withdrawnCount += 1
		end
	end

	return withdrawnCount
end


return table.freeze(Spec)
