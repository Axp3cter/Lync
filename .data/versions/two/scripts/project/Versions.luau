--!strict

--[=[
	Versions

	Reads the package version, which is the one version that variants are given.

	The version is the `version` key of the `[package]` table in the Wally manifest, because that
	is the file Wally publishes from.

	This module is the only reader of the manifest.

	Every operation here yields.

	Lute has no TOML library, so the manifest is scanned line by line.

	Only a plain `version = "1.2.3"` line is understood: its value is a quoted string, and spaces
	around the key and a comment after the value are allowed.

	Dotted or quoted keys, inline tables, multi-line strings and arrays of arrays are not
	understood.

	A failure outside the scripts comes back as a Result whose clause names the manifest and says
	what is wrong with it.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Files     = require("../system/Files")
local Paths     = require("./Paths")
local stringext = require("@std/stringext")
local Types     = require("../Types")


-- Module ------------------------------------------------------------------------------------------

local Versions = {}


-- Types -------------------------------------------------------------------------------------------

--[=[
	One `version` line of the manifest, with the table it sits under.

	@field tableName the header of the table the line sits under, nil above the first header
	@field valueText the text after the `=`, which may still hold quotes and a comment
]=]
type Entry = {
	read tableName: string?,
	read valueText: string,
}


-- Constants ---------------------------------------------------------------------------------------

--- Matches a comment, from its "#" to the end of the line.
const COMMENT_PATTERN = "#.*$"


--- Matches the core of a version: three numbers separated by dots, and nothing else.
const CORE_PATTERN = "^%d+%.%d+%.%d+$"


--- Matches one identifier of a pre-release or of build metadata.
const IDENTIFIER_PATTERN = "^[%w%-]+$"


--- Captures the text after the "=" of a line that sets `version`.
const VERSION_PATTERN = "^version%s*=%s*(.*)$"


--- Matches one character of whitespace.
const WHITESPACE_PATTERN = "%s"


--- Matches a whole number written with leading zeros, such as "01".
const ZERO_PADDED_PATTERN = "^0%d+$"


const CORE_NUMBER_NAMES: { read string } = {
	"major",
	"minor",
	"patch",
}
table.freeze(CORE_NUMBER_NAMES)


--- The header of the table that holds the package version, written without whitespace.
const PACKAGE_TABLE = "[package]"


-- Private -----------------------------------------------------------------------------------------

--[=[
	Splits `text` at the first `separator`.

	@param  text      the text to split
	@param  separator the literal text to split at
	@return the text before the first `separator`, or all of `text` when it has none
	@return the text after the first `separator`, or nil when `text` has none
]=]
local function splitOnce(text: string, separator: string): (string, string?)
	local position = string.find(text, separator, 1, true)
	if position == nil then
		return text, nil
	end

	return string.sub(text, 1, position - 1), string.sub(text, position + 1)
end


local function isZeroPaddedNumber(text: string): boolean
	return string.find(text, ZERO_PADDED_PATTERN) ~= nil
end


--[=[
	Checks the dot-separated identifiers of one part of a version.

	@param  part        the part's name in a problem, such as "pre-release"
	@param  identifiers the identifiers of that part, in the order they are written
	@return the problem in the first identifier that has one, nil when every identifier is valid
]=]
local function problemOfIdentifiers(part: string, identifiers: { read string }): string?
	for _, identifier in identifiers do
		if identifier == "" then
			return `its {part} has an empty identifier`
		end

		if string.find(identifier, IDENTIFIER_PATTERN) == nil then
			local subject = `its {part} identifier "{identifier}"`
			return `{subject} has a character that is not an ASCII letter, digit or hyphen`
		end
	end

	return nil
end


local function problemOfCore(core: string): string?
	if string.find(core, CORE_PATTERN) == nil then
		local subject = `its core "{core}"`
		return `{subject} is not MAJOR.MINOR.PATCH, three whole numbers separated by dots`
	end

	for i, digits in string.split(core, ".") do
		if isZeroPaddedNumber(digits) then
			return `its {CORE_NUMBER_NAMES[i]} number "{digits}" has leading zeros`
		end
	end

	return nil
end


local function problemOfPreRelease(preRelease: string?): string?
	if preRelease == nil then
		return nil
	end

	local identifiers       = string.split(preRelease, ".")
	local identifierProblem = problemOfIdentifiers("pre-release", identifiers)
	if identifierProblem ~= nil then
		return identifierProblem
	end

	for _, identifier in identifiers do
		if isZeroPaddedNumber(identifier) then
			return `its pre-release identifier "{identifier}" has leading zeros`
		end
	end

	return nil
end


local function problemOfBuild(build: string?): string?
	if build == nil then
		return nil
	end

	local identifiers = string.split(build, ".")
	return problemOfIdentifiers("build metadata", identifiers)
end


--[=[
	Checks `version` as Semantic Versioning 2.0.0 text.

	@param  version the text to check
	@return the first problem in the text, as a clause that starts with "its", nil when it is valid
]=]
local function problemOf(version: string): string?
	local withoutBuild, build = splitOnce(version, "+")
	local core, preRelease    = splitOnce(withoutBuild, "-")

	local coreProblem = problemOfCore(core)
	if coreProblem ~= nil then
		return coreProblem
	end

	local preReleaseProblem = problemOfPreRelease(preRelease)
	if preReleaseProblem ~= nil then
		return preReleaseProblem
	end

	return problemOfBuild(build)
end


--[=[
	Returns the name of the table that a header line opens.

	@param  header a manifest line that starts with "["
	@return the name without whitespace or comment, such as "[package]"
]=]
local function headerNameOf(header: string): string
	local withoutComment = string.gsub(header, COMMENT_PATTERN, "")
	local compact        = string.gsub(withoutComment, WHITESPACE_PATTERN, "")
	return compact
end


--[=[
	Returns the text inside the quotes that open a value.

	@param  valueText the text after the `=` of a line
	@return the quoted text, nil unless `valueText` is a quoted string with at most a comment after
]=]
local function quotedTextOf(valueText: string): string?
	local quote = string.sub(valueText, 1, 1)
	if quote ~= '"' and quote ~= "'" then
		return nil
	end

	local textStart       = #quote + 1
	local closingPosition = string.find(valueText, quote, textStart, true)
	if closingPosition == nil then
		return nil
	end

	local afterQuote = string.sub(valueText, closingPosition + 1)
	local trailing   = stringext.trim(afterQuote)
	if
		trailing ~= ""
		and string.sub(trailing, 1, 1) ~= "#"
	then
		return nil
	end

	return string.sub(valueText, textStart, closingPosition - 1)
end


local function versionEntriesOf(manifestText: string): { Entry }
	local entries:   { Entry } = {}
	local tableName: string?   = nil
	for _, line in string.split(manifestText, "\n") do
		local content   = stringext.trim(line)
		local valueText = string.match(content, VERSION_PATTERN)
		if string.sub(content, 1, 1) == "[" then
			tableName = headerNameOf(content)
		elseif valueText ~= nil then
			table.insert(entries, { tableName = tableName, valueText = valueText })
		end
	end

	return entries
end


local function isUnderPackage(entry: Entry): boolean
	local tableName = entry.tableName
	if tableName == nil then
		return false
	end

	return tableName == PACKAGE_TABLE
end


--[=[
	Returns the clause for a manifest whose `[package]` table has no version.

	@param  strayEntries the `version` lines found outside `[package]`, in file order
	@param  path         names the manifest in the clause
	@return the clause, which says where the first stray line is, or that there is none
]=]
local function missingClauseOf(strayEntries: { read Entry }, path: string): string
	local requirement = `"{path}" must have a version under {PACKAGE_TABLE}`

	local strayEntry: Entry? = strayEntries[1]
	if strayEntry == nil then
		return `{requirement}, got none`
	end

	local strayTable = strayEntry.tableName
	if strayTable == nil then
		return `{requirement}, got one at the top of the file`
	end

	return `{requirement}, got one under {strayTable}`
end


--[=[
	Finds the version that a manifest sets under `[package]`, without validating it.

	@param  manifestText the contents of the manifest
	@param  path         names the manifest in a failure
	@return the text between the quotes, or why `manifestText` has no one quoted version there
]=]
local function extractVersion(manifestText: string, path: string): Types.Result<string>
	local packageEntries: { Entry } = {}
	local strayEntries:   { Entry } = {}
	for _, entry in versionEntriesOf(manifestText) do
		if isUnderPackage(entry) then
			table.insert(packageEntries, entry)
		else
			table.insert(strayEntries, entry)
		end
	end

	if #packageEntries > 1 then
		local requirement = `"{path}" must set version once under {PACKAGE_TABLE}`
		return { ok = false, error = `{requirement}, got {#packageEntries} times` }
	end

	local versionEntry: Entry? = packageEntries[1]
	if versionEntry == nil then
		return { ok = false, error = missingClauseOf(strayEntries, path) }
	end

	local versionText = quotedTextOf(versionEntry.valueText)
	if versionText == nil then
		local requirement = `"{path}" version must be a quoted string`
		return { ok = false, error = `{requirement}, got "{versionEntry.valueText}"` }
	end

	return { ok = true, value = versionText }
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Returns the package version, read from the Wally manifest and checked as Semantic Versioning
	2.0.0.

	The version is exactly the text between the quotes, such as "5.0.0" or "5.1.0-rc.1+build.7".

	Wally refuses any other text, so this refuses it before a variant is given it.

	@return the version, or why the manifest cannot be read or does not hold one valid version
]=]
function Versions.read(): Types.Result<string>
	local manifestPath = Paths.MANIFEST.wally
	local read         = Files.read(manifestPath)
	if not read.ok then
		return read
	end

	local extracted = extractVersion(read.value, manifestPath)
	if not extracted.ok then
		return extracted
	end

	local version = extracted.value
	local problem = problemOf(version)
	if problem ~= nil then
		local requirement = `"{manifestPath}" version must be a semantic version, got "{version}"`
		return { ok = false, error = `{requirement}: {problem}` }
	end

	return extracted
end


return table.freeze(Versions)
