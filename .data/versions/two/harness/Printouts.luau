--!strict

--[=[
	Printouts

	Writes a report as a summary a person reads and as lines of Output text a program reads, and
	reads such lines back into the report's JSON.

	A line is `[LyncReport:<run>] <i>/<n> <crc> <piece>`: the run id, the index of the line and the
	count of lines, the CRC-32 of the report's JSON, and one piece of the payload, which is the
	base64 of that JSON. A piece is at most 3900 characters, so a line is far below the 4000 that
	Output keeps whole.

	The reader needs no particular order and forgives repeats. It takes every line that holds the
	line form, with anything before the marker, such as the time and the thread that the Studio log
	puts first, and ignores every other line. The lines of different runs are read apart. It says
	whether each run is complete, truncated, with the lines that are missing, or corrupt.

	The index of a line must not pass the line count, so a line that does is corrupt, not ignored:
	it belongs to a run that does not agree with itself.

	This module uses no engine global, so that the scripts may require it.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Reports = require("./Reports")
local Types   = require("./Types")


-- Module ------------------------------------------------------------------------------------------

local Printouts = {}


-- Types -------------------------------------------------------------------------------------------

type SextetPositions = {
	read first:  number,
	read second: number,
	read third:  number,
	read fourth: number,
}


type BytePositions = {
	read first:  number,
	read second: number,
	read third:  number,
}


type GroupOffsets = {
	read first:  number,
	read second: number,
	read third:  number,
	read fourth: number,
}


--[=[
	One line of a report, as the reader takes it from a text.

	@field runId     the run the line belongs to
	@field index     the place of the line in its report, from 1
	@field lineCount how many lines the report has
	@field checksum  the CRC-32 that the line gives for the report's JSON
	@field piece     the piece of the payload that the line carries
]=]
type Line = {
	read runId:     string,
	read index:     number,
	read lineCount: number,
	read checksum:  string,
	read piece:     string,
}


--[=[
	The lines of one run, as the reader gathers them.

	@field runId        the run the lines belong to
	@field lineCount    how many lines the first line of the run says the report has
	@field checksum     the CRC-32 that the first line of the run gives
	@field pieceByIndex the piece of each line seen, by its index
	@field indexes      the indexes seen, in the order they first came
	@field problem      why the lines contradict each other, nil while they agree
]=]
type Group = {
	read runId:        string,
	read lineCount:    number,
	read checksum:     string,
	read pieceByIndex: { [number]: string },
	read indexes:      { number },
	problem:           string?,
}


--[=[
	A run of consecutive lines that a truncated report lacks.

	@field first the index of the first missing line
	@field last  the index of the last missing line, which is `first` when only one is missing
]=]
export type Missing = {
	read first: number,
	read last:  number,
}


--[=[
	A run whose every line was read and whose checksum holds.

	@field kind  always "Complete"
	@field runId the run the report belongs to
	@field json  the JSON text of the report
]=]
export type CompleteReading = {
	read kind:  "Complete",
	read runId: string,
	read json:  string,
}


--[=[
	A run that lacks lines but whose lines agree with each other.

	@field kind      always "Truncated"
	@field runId     the run the lines belong to
	@field lineCount how many lines the report has
	@field missing   the lines that were not read, in order
]=]
export type TruncatedReading = {
	read kind:      "Truncated",
	read runId:     string,
	read lineCount: number,
	read missing:   { read Missing },
}


--[=[
	A run whose lines contradict each other, or whose payload fails its checksum.

	@field kind    always "Corrupt"
	@field runId   the run the lines belong to
	@field problem what is wrong, as a clause
]=]
export type CorruptReading = {
	read kind:    "Corrupt",
	read runId:   string,
	read problem: string,
}


--- What the reader found of one run.
export type Reading =
	| CompleteReading
	| TruncatedReading
	| CorruptReading


-- Constants ---------------------------------------------------------------------------------------

--- How many characters of the payload one line carries, the last line fewer.
const PIECE_LENGTH = 3900


--[=[
	Matches a line of a report, anywhere in a text, and captures its run id, index, count,
	checksum and piece.
]=]
const LINE_PATTERN = "%[LyncReport:([0-9a-f]+)%] ([1-9]%d*)/([1-9]%d*) ([0-9a-f]+) \z
	([A-Za-z0-9+/=]+)%s*$"


--- How many digits an index or a count of lines may have, which keeps a count a whole number.
const MAX_COUNT_DIGITS = 9


--- How many hexadecimal digits a checksum has.
const CHECKSUM_LENGTH = 8


--- The characters that base64 writes sextets with, in the order of their values.
const BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


--- The character that base64 pads a final group with, as a byte.
const PADDING_CODE = 0x3D


--- How many bits one base64 character holds.
const SEXTET_WIDTH = 6


--- How many base64 characters carry one group of three bytes.
const GROUP_LENGTH = 4


--- How many bytes one group of base64 characters carries.
const GROUP_BYTES = 3


--- The most `=` characters that end a base64 text: a group of one byte carries two characters.
const MAX_PADDING = 2


--- The place of the second and of the third byte in a group, counted from 1.
const SECOND_PLACE = 2
const THIRD_PLACE  = 3


--- Where each byte of a group, and each character that carries it, lies from the group's start.
const OFFSET: GroupOffsets = {
	first  = 0,
	second = 1,
	third  = 2,
	fourth = 3,
}


--- Where each character's sextet starts in the 24 bits of a group, counted from the low bit.
const SEXTET_START: SextetPositions = {
	first  = 18,
	second = 12,
	third  = 6,
	fourth = 0,
}


--- How many bits one byte holds, and how many values it can have.
const BYTE_WIDTH       = 8
const BYTE_VALUE_COUNT = 256


--- Keeps the low byte of a word.
const BYTE_MASK = 0xFF


--- Where each byte starts in the 24 bits of a group, counted from the low bit.
const BYTE_START: BytePositions = {
	first  = 16,
	second = 8,
	third  = 0,
}


--- The verdicts in the order a summary counts them.
const VERDICT_ORDER: { read Reports.Verdict } = {
	"Passed",
	"Failed",
	"Crashed",
	"TimedOut",
	"Skipped",
}
table.freeze(VERDICT_ORDER)


--- How a summary writes each verdict in the count of a run.
const COUNT_WORD_BY_VERDICT: Types.Complete<{ read [Reports.Verdict]: string }> = {
	Passed   = "passed",
	Failed   = "failed",
	Crashed  = "crashed",
	TimedOut = "timed out",
	Skipped  = "skipped",
}
table.freeze(COUNT_WORD_BY_VERDICT)


--- How a summary writes the verdict of a test that did not pass.
const HEADING_WORD_BY_VERDICT: Types.Complete<{ read [Reports.Verdict]: string }> = {
	Passed   = "PASSED",
	Failed   = "FAILED",
	Crashed  = "CRASHED",
	TimedOut = "TIMED OUT",
	Skipped  = "SKIPPED",
}
table.freeze(HEADING_WORD_BY_VERDICT)


--- How many lines of one test's failure a summary shows before it counts the rest.
const MAX_DETAIL_LINES = 40


--- What a summary puts before the detail lines of a test.
const DETAIL_INDENT = "    "


--- The reflected form of the CRC-32 polynomial 0x04C11DB7.
const CRC_POLYNOMIAL = 0xEDB88320


--- The value that the CRC-32 starts from, and that it is exclusive-ored with at the end.
const CRC_MASK = 0xFFFFFFFF


-- State -------------------------------------------------------------------------------------------

--- The remainder of every byte value for the CRC-32, built when the first checksum needs it.
local crcRemainders: { number }? = nil


--- The value of every base64 character by its byte, built when the first text is read.
local sextetByCode: { [number]: number }? = nil


-- Private -----------------------------------------------------------------------------------------

local function remaindersOf(): { number }
	if crcRemainders ~= nil then
		return crcRemainders
	end

	local built = table.create(BYTE_VALUE_COUNT) :: { number }
	for value = 0, BYTE_VALUE_COUNT - 1 do
		local remainder = value
		for _ = 1, BYTE_WIDTH do
			local shifted = bit32.rshift(remainder, 1)
			if bit32.btest(remainder, 1) then
				remainder = bit32.bxor(CRC_POLYNOMIAL, shifted)
			else
				remainder = shifted
			end
		end

		built[value + 1] = remainder
	end

	crcRemainders = built

	return built
end


local function sextetsOf(): { [number]: number }
	if sextetByCode ~= nil then
		return sextetByCode
	end

	local built: { [number]: number } = {}
	for sextet = 0, #BASE64_ALPHABET - 1 do
		local code  = string.byte(BASE64_ALPHABET, sextet + 1)
		built[code] = sextet
	end

	sextetByCode = built

	return built
end


local function checksumOf(bytes: string): string
	local remainders = remaindersOf()
	local input      = buffer.fromstring(bytes)
	local crc        = CRC_MASK
	for offset = 0, buffer.len(input) - 1 do
		local byte      = buffer.readu8(input, offset)
		local mixed     = bit32.bxor(crc, byte)
		local index     = bit32.band(mixed, BYTE_MASK)
		local remainder = remainders[index + 1]
		local shifted   = bit32.rshift(crc, BYTE_WIDTH)
		crc             = bit32.bxor(remainder, shifted)
	end

	return string.format("%08x", bit32.bxor(crc, CRC_MASK))
end


local function codeOf(sextet: number): number
	local code = string.byte(BASE64_ALPHABET, sextet + 1)

	return code
end


local function toBase64(bytes: string): string
	local input       = buffer.fromstring(bytes)
	local inputLength = buffer.len(input)
	local groupCount  = (inputLength + GROUP_BYTES - 1) // GROUP_BYTES
	local output      = buffer.create(groupCount * GROUP_LENGTH)
	for group = 0, groupCount - 1 do
		local inputOffset  = group * GROUP_BYTES
		local outputOffset = group * GROUP_LENGTH
		local remaining    = inputLength - inputOffset

		local hasSecondByte = remaining >= SECOND_PLACE
		local hasThirdByte  = remaining >= THIRD_PLACE

		local secondOffset = inputOffset + OFFSET.second
		local thirdOffset  = inputOffset + OFFSET.third

		local first  = buffer.readu8(input, inputOffset + OFFSET.first)
		local second = if hasSecondByte then buffer.readu8(input, secondOffset) else 0
		local third  = if hasThirdByte then buffer.readu8(input, thirdOffset) else 0

		local packed = bit32.replace(0, first, BYTE_START.first, BYTE_WIDTH)
		packed       = bit32.replace(packed, second, BYTE_START.second, BYTE_WIDTH)
		packed       = bit32.replace(packed, third, BYTE_START.third, BYTE_WIDTH)

		local firstSextet  = bit32.extract(packed, SEXTET_START.first, SEXTET_WIDTH)
		local secondSextet = bit32.extract(packed, SEXTET_START.second, SEXTET_WIDTH)
		local thirdSextet  = bit32.extract(packed, SEXTET_START.third, SEXTET_WIDTH)
		local fourthSextet = bit32.extract(packed, SEXTET_START.fourth, SEXTET_WIDTH)

		local firstCode  = codeOf(firstSextet)
		local secondCode = codeOf(secondSextet)
		local thirdCode  = if hasSecondByte then codeOf(thirdSextet) else PADDING_CODE
		local fourthCode = if hasThirdByte then codeOf(fourthSextet) else PADDING_CODE

		buffer.writeu8(output, outputOffset + OFFSET.first, firstCode)
		buffer.writeu8(output, outputOffset + OFFSET.second, secondCode)
		buffer.writeu8(output, outputOffset + OFFSET.third, thirdCode)
		buffer.writeu8(output, outputOffset + OFFSET.fourth, fourthCode)
	end

	return buffer.readstring(output, 0, buffer.len(output))
end


--[=[
	Counts the padding characters that end a base64 text.

	@param  text the base64 text, whose length is a multiple of 4 and above 0
	@return the number of `=` characters at the end, from 0 to MAX_PADDING
]=]
local function paddingOf(text: string): number
	if string.byte(text, #text) ~= PADDING_CODE then
		return 0
	end

	if string.byte(text, #text - 1) ~= PADDING_CODE then
		return 1
	end

	return MAX_PADDING
end


local function toBytes(text: string): string?
	local textLength = #text
	if textLength % GROUP_LENGTH ~= 0 then
		return nil
	end

	if textLength == 0 then
		return ""
	end

	local sextets    = sextetsOf()
	local padding    = paddingOf(text)
	local groupCount = textLength // GROUP_LENGTH
	local input      = buffer.fromstring(text)
	local output     = buffer.create(groupCount * GROUP_BYTES)
	for group = 0, groupCount - 1 do
		local isLast = group == groupCount - 1
		local packed = 0
		for position = 0, GROUP_LENGTH - 1 do
			local code = buffer.readu8(input, group * GROUP_LENGTH + position)
			if code == PADDING_CODE then
				if
					not isLast
					or position < GROUP_LENGTH - padding
				then
					return nil
				end

				packed = bit32.lshift(packed, SEXTET_WIDTH)
				continue
			end

			local sextet = sextets[code]
			if sextet == nil then
				return nil
			end

			local shifted = bit32.lshift(packed, SEXTET_WIDTH)
			packed        = bit32.bor(shifted, sextet)
		end

		if
			isLast
			and padding > 0
			and bit32.extract(packed, 0, BYTE_WIDTH * padding) ~= 0
		then
			return nil
		end

		local outputOffset = group * GROUP_BYTES
		local firstByte    = bit32.extract(packed, BYTE_START.first, BYTE_WIDTH)
		local secondByte   = bit32.extract(packed, BYTE_START.second, BYTE_WIDTH)
		local thirdByte    = bit32.extract(packed, BYTE_START.third, BYTE_WIDTH)

		buffer.writeu8(output, outputOffset + OFFSET.first, firstByte)
		buffer.writeu8(output, outputOffset + OFFSET.second, secondByte)
		buffer.writeu8(output, outputOffset + OFFSET.third, thirdByte)
	end

	return buffer.readstring(output, 0, groupCount * GROUP_BYTES - padding)
end


local function countLineOf(report: Reports.Report): string
	local countByVerdict: { [Reports.Verdict]: number } = {
		Passed   = 0,
		Failed   = 0,
		Crashed  = 0,
		TimedOut = 0,
		Skipped  = 0,
	}

	for _, outcome in report.outcomes do
		countByVerdict[outcome.verdict] += 1
	end

	local counts = table.create(#VERDICT_ORDER) :: { string }
	for i, verdict in VERDICT_ORDER do
		counts[i] = `{countByVerdict[verdict]} {COUNT_WORD_BY_VERDICT[verdict]}`
	end

	local joined = table.concat(counts, ", ")

	return `Lync {report.kind} run {report.runId}: {joined}`
end


local function settingsLineOf(report: Reports.Report): string
	local filter   = if report.filter == "" then "no filter" else `filter "{report.filter}"`
	local progress = if report.isComplete then "complete" else "incomplete"

	local settings = `seed {report.seed}, profile {report.profile}, {filter}`

	return `  {settings}, build {report.buildId}, {progress}`
end


local function detailLinesOf(outcome: Reports.Outcome): { string }
	local text = outcome.failure
	if text == nil then
		text = outcome.reason
	end

	if text == nil then
		return {}
	end

	local textLines  = string.split(text, "\n")
	local shownCount = math.min(#textLines, MAX_DETAIL_LINES)
	local lines      = table.create(shownCount) :: { string }
	for i = 1, shownCount do
		lines[i] = `{DETAIL_INDENT}{textLines[i]}`
	end

	if #textLines > shownCount then
		local hiddenCount = #textLines - shownCount
		table.insert(lines, `{DETAIL_INDENT}... {hiddenCount} more lines in the report`)
	end

	return lines
end


local function toLine(text: string): Line?
	local runId, indexText, countText, checksum, piece = string.match(text, LINE_PATTERN)
	if
		runId == nil
		or indexText == nil
		or countText == nil
		or checksum == nil
		or piece == nil
	then
		return nil
	end

	if not Reports.isRunId(runId) then
		return nil
	end

	if #checksum ~= CHECKSUM_LENGTH then
		return nil
	end

	if #indexText > MAX_COUNT_DIGITS then
		return nil
	end

	if #countText > MAX_COUNT_DIGITS then
		return nil
	end

	return {
		runId     = runId,
		index     = assert(tonumber(indexText), "an index of digits must read as a number"),
		lineCount = assert(tonumber(countText), "a count of digits must read as a number"),
		checksum  = checksum,
		piece     = piece,
	}
end


local function startGroup(line: Line): Group
	return {
		runId        = line.runId,
		lineCount    = line.lineCount,
		checksum     = line.checksum,
		pieceByIndex = {},
		indexes      = {},
		problem      = nil,
	}
end


local function addLine(group: Group, line: Line): ()
	if group.problem ~= nil then
		return
	end

	if line.lineCount ~= group.lineCount then
		local counts  = `{group.lineCount} and {line.lineCount}`
		group.problem = `lines disagree on the line count, {counts}`
		return
	end

	if line.checksum ~= group.checksum then
		local checksums = `{group.checksum} and {line.checksum}`
		group.problem   = `lines disagree on the checksum, {checksums}`
		return
	end

	if line.index > group.lineCount then
		group.problem = `line {line.index} lies beyond the {group.lineCount} lines of the report`
		return
	end

	local knownPiece = group.pieceByIndex[line.index]
	if knownPiece == nil then
		group.pieceByIndex[line.index] = line.piece
		table.insert(group.indexes, line.index)
		return
	end

	if knownPiece ~= line.piece then
		group.problem = `line {line.index} repeats with a different piece`
	end
end


local function missingOf(group: Group): { Missing }
	local indexes = table.clone(group.indexes)
	table.sort(indexes)

	local missing: { Missing } = {}
	local expected             = 1
	for _, index in indexes do
		if index > expected then
			table.insert(missing, { first = expected, last = index - 1 })
		end

		expected = index + 1
	end

	if expected <= group.lineCount then
		table.insert(missing, { first = expected, last = group.lineCount })
	end

	return missing
end


local function readingOf(group: Group): Reading
	if group.problem ~= nil then
		return {
			kind    = "Corrupt",
			runId   = group.runId,
			problem = group.problem,
		}
	end

	local missing = missingOf(group)
	if #missing > 0 then
		return {
			kind      = "Truncated",
			runId     = group.runId,
			lineCount = group.lineCount,
			missing   = missing,
		}
	end

	local pieces = table.create(group.lineCount) :: { string }
	for index = 1, group.lineCount do
		local piece = group.pieceByIndex[index]
		assert(piece, "a report that lacks no line must hold every line")

		pieces[index] = piece
	end

	local json = toBytes(table.concat(pieces))
	if json == nil then
		return {
			kind    = "Corrupt",
			runId   = group.runId,
			problem = "the payload is not base64",
		}
	end

	local actual = checksumOf(json)
	if actual ~= group.checksum then
		local checksums = `{actual}, not the {group.checksum} on its lines`
		return {
			kind    = "Corrupt",
			runId   = group.runId,
			problem = `the checksum of the report is {checksums}`,
		}
	end

	return {
		kind  = "Complete",
		runId = group.runId,
		json  = json,
	}
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Returns the CRC-32 of some bytes, as a line of a report writes it.

	@param  bytes the bytes to checksum, such as the UTF-8 text of a report's JSON
	@return the checksum as 8 lowercase hexadecimal digits
]=]
function Printouts.checksumOf(bytes: string): string
	return checksumOf(bytes)
end


--[=[
	Writes a report as the lines that carry it in Output.

	The lines are in order of their index, and each holds a piece of the base64 of the report's
	JSON, so that the reader can rebuild the JSON from them in any order.

	@param  report the report to write, whose run id names every line
	@return the lines, at least one
	@error  when `report.runId` is not 8 lowercase hexadecimal digits
]=]
function Printouts.linesOf(report: Reports.Report): { string }
	if not Reports.isRunId(report.runId) then
		local requirement = "report.runId must be 8 lowercase hexadecimal digits"
		error(`{requirement}, got "{report.runId}"`, 2)
	end

	local json      = Reports.toJson(report)
	local payload   = toBase64(json)
	local checksum  = checksumOf(json)
	local lineCount = (#payload + PIECE_LENGTH - 1) // PIECE_LENGTH

	local lines = table.create(lineCount) :: { string }
	for index = 1, lineCount do
		local first  = (index - 1) * PIECE_LENGTH + 1
		local piece  = string.sub(payload, first, first + PIECE_LENGTH - 1)
		lines[index] = `[LyncReport:{report.runId}] {index}/{lineCount} {checksum} {piece}`
	end

	return lines
end


--[=[
	Reads the reports that some lines of text carry.

	Lines that do not hold the line form are ignored, so `lines` may be a whole log. The lines of
	each run are gathered, in whatever order they come, and a run is read once for all its lines.

	@param  lines the lines of a log or of a pasted block of Output
	@return a reading for each run id, in order of first appearance; none if no line fits
]=]
function Printouts.readLines(lines: { read string }): { Reading }
	local groupByRunId: { [string]: Group } = {}
	local groups:       { Group }           = {}
	for _, text in lines do
		local line = toLine(text)
		if line == nil then
			continue
		end

		local group = groupByRunId[line.runId]
		if group == nil then
			group                    = startGroup(line)
			groupByRunId[line.runId] = group
			table.insert(groups, group)
		end

		addLine(group, line)
	end

	local readings = table.create(#groups) :: { Reading }
	for i, group in groups do
		readings[i] = readingOf(group)
	end

	return readings
end


--[=[
	Writes what a run came to as lines a person reads: the counts, the settings, and every test
	that did not pass with the text of what went wrong.

	@param  report the report to summarize
	@return the lines, with no line break in any; at least two
]=]
function Printouts.summaryOf(report: Reports.Report): { string }
	local lines = {
		countLineOf(report),
		settingsLineOf(report),
	}

	for _, outcome in report.outcomes do
		if outcome.verdict == "Passed" then
			continue
		end

		local heading = HEADING_WORD_BY_VERDICT[outcome.verdict]
		table.insert(lines, `  {heading} {outcome.id} [{outcome.dataModel}]`)

		for _, detail in detailLinesOf(outcome) do
			table.insert(lines, detail)
		end
	end

	return lines
end


--[=[
	Writes bytes as base64, as RFC 4648 section 4 does, with `=` padding.

	@param  bytes the bytes to write
	@return the base64 text, a multiple of 4 characters long
]=]
function Printouts.toBase64(bytes: string): string
	return toBase64(bytes)
end


--[=[
	Reads base64 text, as RFC 4648 section 4 writes it, into bytes.

	The text must be what `toBase64` would write: nothing outside the alphabet, padding only at the
	end, and no stray bits before it.

	@param  text the base64 text
	@return the bytes, nil when `text` is not base64
]=]
function Printouts.toBytes(text: string): string?
	return toBytes(text)
end


return table.freeze(Printouts)
