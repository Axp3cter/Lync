--!strict

--[=[
	Fail

	Raises Lync's declaration and caller errors in the one message grammar of v5.md §7.1:
	`source:line: [Lync] <code>: <subject> must <requirement>[, got <value>][; <fix>]`.

	Messages are one line of at most 200 bytes after the position, raised as strings with
	`error(message, 0)`. Values are rendered by `show` (diagnostics §3.2), and only on the failure
	path.

	A declaration error is positioned at the line a schema constructor recorded; a caller error at
	the first frame outside Lync, found by walking `debug.info`, which holds at every optimisation
	level, where `error(message, 2)` does not (diagnostics §1.1).
]=]

-- Imports -----------------------------------------------------------------------------------------

local Codes = require("./codes")

-- Module ------------------------------------------------------------------------------------------

local Fail = {}

-- Types -------------------------------------------------------------------------------------------

--- Where a schema constructor was called.
export type At = { line: number, source: string }

-- Constants ---------------------------------------------------------------------------------------

const MAX_BODY_BYTES = 200
const MAX_SHOWN_BYTES = 40
const MAX_INTEGER_SHOWN = 2 ^ 63

-- Every Lync module's source starts with this prefix: this file's own source without its
-- extension and its place in the package (`diag/fail` in a file tree, `.diag.fail` on Roblox).
const OWN_SOURCE = (string.gsub(debug.info(1, "s"), "%.luau?$", ""))
const LYNC_PREFIX = assert(
	string.match(OWN_SOURCE, "^(.-)%.?diag[%./\\]fail$"),
	"Lync must be loaded from diag/fail"
)

const ESCAPE_BY_CHARACTER: { [string]: string } = {
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
	["\\"] = "\\\\",
	['"'] = '\\"',
}
table.freeze(ESCAPE_BY_CHARACTER)

-- Private -----------------------------------------------------------------------------------------

-- Backs a cut of `text` at `maxBytes` off to the start of a UTF-8 sequence, so valid text stays
-- valid.
local function cutOf(text: string, maxBytes: number): number
	local cut = maxBytes
	while cut > 0 do
		local nextByte = string.byte(text, cut + 1)
		if nextByte < 0x80 or nextByte >= 0xC0 then
			return cut
		end

		cut -= 1
	end

	return cut
end

local function showNumber(value: number): string
	if value ~= value then
		return "nan"
	end

	if value == math.huge then
		return "inf"
	end

	if value == -math.huge then
		return "-inf"
	end

	if value == 0 and 1 / value < 0 then
		return "-0"
	end

	if math.floor(value) == value and math.abs(value) < MAX_INTEGER_SHOWN then
		return string.format("%d", value)
	end

	return string.format("%.17g", value)
end

local function showTriple(typeName: string, a: number, b: number, c: number): string
	return `{typeName}({showNumber(a)}, {showNumber(b)}, {showNumber(c)})`
end

local function escapedOf(text: string): string
	local isValidUtf8 = utf8.len(text) ~= nil
	local escaped = string.gsub(text, '[%c\\"\128-\255]', function(character: string): string
		local named = ESCAPE_BY_CHARACTER[character]
		if named ~= nil then
			return named
		end

		local byte = string.byte(character)
		if byte >= 0x80 and isValidUtf8 then
			return character
		end

		return string.format("\\x%02X", byte)
	end)

	return escaped
end

local function showString(text: string): string
	if #text <= MAX_SHOWN_BYTES then
		return `"{escapedOf(text)}"`
	end

	local cut = cutOf(text, MAX_SHOWN_BYTES)
	local shown = escapedOf(string.sub(text, 1, cut))
	local restBytes = #text - cut

	return `"{shown}"…(+{restBytes} bytes)`
end

local function showTable(value: { [unknown]: unknown }): string
	local keyCount = 0
	for _ in next, value do
		keyCount += 1
	end

	return `table ({keyCount} keys)`
end

local function show(value: any): string
	local valueType = typeof(value)
	if valueType == "string" then
		return showString(value)
	end

	if valueType == "number" then
		return showNumber(value)
	end

	if valueType == "boolean" or valueType == "nil" then
		return tostring(value)
	end

	if valueType == "buffer" then
		return `buffer({buffer.len(value)} bytes)`
	end

	if valueType == "table" then
		return showTable(value)
	end

	if valueType == "Vector3" then
		return showTriple(valueType, value.X, value.Y, value.Z)
	end

	if valueType == "CFrame" then
		local position = value.Position
		return showTriple(valueType, position.X, position.Y, position.Z)
	end

	if valueType == "Color3" then
		return showTriple(valueType, value.R, value.G, value.B)
	end

	if valueType == "Instance" then
		return `Instance({value.ClassName})`
	end

	return valueType
end

local function bodyOf(
	code: Codes.Code,
	subject: string,
	requirement: string,
	got: unknown,
	fix: string?
): string
	local gotPart = if got == nil then "" else `, got {show(got)}`
	local fixPart = if fix == nil then "" else `; {fix}`
	local body = `[Lync] {code}: {subject} must {requirement}{gotPart}{fixPart}`
	if #body <= MAX_BODY_BYTES then
		return body
	end

	return string.sub(body, 1, cutOf(body, MAX_BODY_BYTES))
end

local function callerPosition(): string?
	local level = 2
	while true do
		local source, line = debug.info(level, "sl")
		if source == nil then
			return nil
		end

		local isOutsideLync = string.sub(source, 1, #LYNC_PREFIX) ~= LYNC_PREFIX
		if isOutsideLync and line > 0 then
			return `{source}:{line}`
		end

		level += 1
	end
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Raises a caller error, positioned at the first frame outside Lync.

	@param code        the error's code
	@param subject     what the requirement is about, in the user's names
	@param requirement what the subject must be, completing "<subject> must"
	@param got         the value given, rendered by `show`; nil leaves the clause out
	@param fix         the one fix, when there is exactly one
	@error always, with the message
]=]
function Fail.caller(
	code: Codes.Code,
	subject: string,
	requirement: string,
	got: any?,
	fix: string?
): never
	local body = bodyOf(code, subject, requirement, got, fix)
	local position = callerPosition()
	if position == nil then
		error(body, 0)
	end

	error(`{position}: {body}`, 0)
end

--[=[
	Raises a declaration error, positioned where a schema constructor was called.

	@param code        the error's code
	@param at          the line and source the constructor recorded
	@param subject     what the requirement is about, in the user's names
	@param requirement what the subject must be, completing "<subject> must"
	@param got         the value given, rendered by `show`; nil leaves the clause out
	@param fix         the one fix, when there is exactly one
	@error always, with the message
]=]
function Fail.declaration(
	code: Codes.Code,
	at: At,
	subject: string,
	requirement: string,
	got: any?,
	fix: string?
): never
	local body = bodyOf(code, subject, requirement, got, fix)
	error(`{at.source}:{at.line}: {body}`, 0)
end

--[=[
	Renders a value for a message: strings quoted, escaped and cut at 40 bytes; buffers and
	tables by their size; instances by their class, never their names.

	@param  value the value to render
	@return one line of text
]=]
function Fail.show(value: any): string
	return show(value)
end

return table.freeze(Fail)
