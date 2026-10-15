--!strict

--[=[
	registry.spec

	The code registry lints itself (v5.md §7.1, §9): `codes.luau` and `docs/codes/*.md` list the
	same codes, every page's front matter and example are well formed, and every code is named by
	a test.

	Paths are relative to the repo root, where the runner runs.
]=]

-- Imports -----------------------------------------------------------------------------------------

local fs = require("@lune/fs")

local Check = require("../support/check")
local Codes = require("../../src/diag/codes")

-- Constants ---------------------------------------------------------------------------------------

const PAGES = "docs/codes"
const TESTS = "test"
const CODES_SOURCE = "src/diag/codes.luau"
const SINCE = "5.0.0"

const MAX_BODY_BYTES = 200
const MESSAGE_PATTERN = "^(.-):(%d+): (%[Lync%] (%l%w*): (.*))$"
const JUDGEMENT_WORDS = { "suspicious", "illegal", "invalid", "bad", "exploit", "flagged" }

-- Private -----------------------------------------------------------------------------------------

local function pageCodes(): { [string]: string }
	local textByCode: { [string]: string } = {}
	for _, name in fs.readDir(PAGES) do
		local code = string.match(name, "^(.+)%.md$")
		Check.expect(code ~= nil, `{PAGES}/{name} must be a .md page`)
		textByCode[code :: string] = fs.readFile(`{PAGES}/{name}`)
	end

	return textByCode
end

local function frontMatterOf(text: string): { [string]: string }
	local block = string.match(text, "^%-%-%-\n(.-)\n%-%-%-\n")
	Check.expect(block ~= nil, "a page must start with front matter between --- lines")

	local fields: { [string]: string } = {}
	for line in string.gmatch(block :: string, "[^\n]+") do
		local key, value = string.match(line, "^(%a+): (.+)$")
		Check.expect(key ~= nil, `front matter line {line} must be "key: value"`)
		fields[key :: string] = value :: string
	end

	return fields
end

local function exampleOf(text: string): string?
	return string.match(text, "\n```example\n(.-)\n```")
end

local function specTexts(directory: string, into: { string })
	for _, name in fs.readDir(directory) do
		local path = `{directory}/{name}`
		if fs.isDir(path) then
			specTexts(path, into)
		elseif string.sub(name, -#".spec.luau") == ".spec.luau" then
			table.insert(into, fs.readFile(path))
		end
	end
end

local function isNamedByTest(code: string, texts: { string }): boolean
	local needle = `code = "{code}"`
	for _, text in texts do
		if string.find(text, needle, 1, true) ~= nil then
			return true
		end
	end

	return false
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["every code has a page, and every page a code"] = function()
		local textByCode = pageCodes()
		for code in Codes.family do
			Check.expect(textByCode[code] ~= nil, `{code} must have {PAGES}/{code}.md`)
		end

		for code in textByCode do
			Check.expect((Codes.family :: any)[code] ~= nil, `{PAGES}/{code}.md must name a code`)
		end
	end,

	["the Code type lists exactly the registered codes"] = function()
		local source = fs.readFile(CODES_SOURCE)
		local union = string.match(source, "export type Code =\n(.-)\n\n")
		Check.expect(union ~= nil, "codes.luau must declare export type Code")

		local typed: { [string]: boolean } = {}
		for code in string.gmatch(union :: string, '| "(%a+)"') do
			typed[code] = true
			Check.expect((Codes.family :: any)[code] ~= nil, `{code} must have a family`)
		end

		for code in Codes.family do
			Check.expect(typed[code] == true, `{code} must be in the Code type`)
		end
	end,

	["every page's front matter names its family and version"] = function()
		for code, text in pageCodes() do
			local fields = frontMatterOf(text)
			local family = (Codes.family :: any)[code]

			Check.expectEqual(fields.family, family, `{code} family`)
			Check.expectEqual(fields.since, SINCE, `{code} since`)
			if family == "fact" then
				Check.expect(fields.evidence ~= nil, `{code} is a fact and must list its evidence`)
			end
		end
	end,

	["every example follows the message grammar of v5.md §7.1"] = function()
		for code, text in pageCodes() do
			local example = exampleOf(text)
			Check.expect(example ~= nil, `{code} must have an example block`)

			local message = example :: string
			local _, line, body, exampleCode, rest = string.match(message, MESSAGE_PATTERN)
			Check.expect(line ~= nil, `{code}'s example must be "source:line: [Lync] code: ..."`)
			Check.expectEqual(exampleCode, code, `{code}'s example code`)
			Check.expect(
				string.find(message, "\n", 1, true) == nil,
				`{code}'s example must be one line`
			)
			Check.expect(
				#(body :: string) <= MAX_BODY_BYTES,
				`{code}'s example must be at most 200 bytes`
			)
			Check.expect(
				string.find(rest :: string, " must ", 1, true) ~= nil,
				`{code}'s example must say "must"`
			)

			local lowered = string.lower(message)
			for _, word in JUDGEMENT_WORDS do
				local isUsed = string.find(lowered, `%f[%a]{word}%f[%A]`) ~= nil
				Check.expect(not isUsed, `{code}'s example must not use the word "{word}"`)
			end
		end
	end,

	["every code is named by a test"] = function()
		local texts = {}
		specTexts(TESTS, texts)

		for code in Codes.family do
			Check.expect(isNamedByTest(code, texts), `{code} must be triggered by a test naming it`)
		end
	end,
}
