--!strict

--[=[
	registry.spec

	The code registry lints itself (v5.md §7.1, §9): `codes.luau` and `docs/codes/*.md` list the
	same codes, every page's front matter and example are well formed, every code is named by a
	test, and every page's example is, byte for byte, the output Lync gives for it:
	- a thrown code's (declaration, caller, fault, internal) example is the message its trigger
	  module raises; a fault is the same message, reported natively;
	- a fact's example is the console line the console prints for it (v5.md §7.4), and its front
	  matter lists its evidence in `Codes.evidence`'s order;
	- an outcome's example is the result a request returns, and `src/types.luau`'s `Failure`
	  lists exactly the outcomes.

	A test names a thrown code as `code = "<code>"`, a fact as `reason = "<code>"` and an outcome
	as `error = "<code>"`. The codes in `RAISED_BY_UNIT_F` are raised only by milestone 2's views,
	configuration, validators and requests, which unit F builds (m2-plan.md §4): their triggers
	are written against that API and their tests are F's, so those two checks wait for it.

	A trigger runs as the module the page names, with `game:GetService` and `require` resolving
	`ReplicatedStorage.Packages.Lync` to this package. The examples are the only prose a test
	compares (v5.md §9).

	Paths are relative to the repo root, where the runner runs.
]=]

-- Imports -----------------------------------------------------------------------------------------

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local Check = require("../support/check")
local Codes = require("../../src/diag/codes")
local Console = require("../../src/diag/console")
local Lync = require("../../src")

-- Constants ---------------------------------------------------------------------------------------

const PAGES = "docs/codes"
const TESTS = "test"
const CODES_SOURCE = "src/diag/codes.luau"
const TYPES_SOURCE = "src/types.luau"
const SINCE = "5.0.0"

const MAX_BODY_BYTES = 200
const MESSAGE_PATTERN = "^(.-):(%d+): (%[Lync%] (%l%w*): (.*))$"
const LINE_PATTERN = "^%[Lync%] (%l%w*): (.*)$"
const SUPPRESSED_EVIDENCE = "one count per suppressed reason"
const JUDGEMENT_WORDS = { "suspicious", "illegal", "invalid", "bad", "exploit", "flagged" }

const THROWN_FAMILIES = table.freeze({
	declaration = true,
	caller = true,
	fault = true,
	internal = true,
})

const NEEDLE_KEY_BY_FAMILY = table.freeze({
	fact = "reason",
	outcome = "error",
})

const RAISED_BY_UNIT_F = table.freeze({
	wrongSide = true,
	configureRange = true,
	unknownTarget = true,
	validatorError = true,
	validatorYielded = true,
	timeout = true,
	rejected = true,
	unanswered = true,
	left = true,
	shutdown = true,
})

-- `ReplicatedStorage.Packages.Lync` in a trigger, with its submodules as paths under `src/`.
const LYNC_PACKAGE = table.freeze({
	wire = table.freeze({ bits = "wire/bits" }),
	codec = table.freeze({ rows = "codec/rows" }),
	diag = table.freeze({ fail = "diag/fail" }),
})

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

local function triggerOf(text: string): (string?, string?)
	local source = string.match(text, "\nThe module `([^`]+)`:\n")
	local trigger = string.match(text, "\n```luau\n(.-)\n```")
	return source, trigger
end

local function requireFromTrigger(path: unknown): any
	if path == LYNC_PACKAGE then
		return Lync
	end

	Check.expect(typeof(path) == "string", "a trigger must require only Lync and its modules")
	return (require :: any)(`../../src/{path}`)
end

-- Runs a trigger module and returns the message it raised, or nil when it returned.
local function messageOf(source: string, trigger: string): string?
	local services = { ReplicatedStorage = { Packages = { Lync = LYNC_PACKAGE } } }
	local environment = {
		game = {
			GetService = function(_game: any, name: string): any
				return services[name]
			end,
		},
		require = requireFromTrigger,
		Enum = Enum,
	}
	local chunk = luau.load(trigger, { debugName = `={source}`, environment = environment })
	local ok, message = pcall(chunk)
	if ok then
		return nil
	end

	return tostring(message)
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
	local key = (NEEDLE_KEY_BY_FAMILY :: any)[(Codes.family :: any)[code]] or "code"
	local needle = `{key} = "{code}"`
	for _, text in texts do
		if string.find(text, needle, 1, true) ~= nil then
			return true
		end
	end

	return false
end

-- The line the console prints for a fact's first occurrence.
local function consoleLineOf(code: string): string?
	local printed: string? = nil
	local host = {
		side = "server",
		warn = function(template: string)
			printed = template
		end,
	}
	Console.fact(Console.new(host :: any), code :: any, nil, nil, 0)

	return printed
end

local function outcomeOf(code: string): string
	return `\{ ok = false, error = "{code}" }`
end

local function expectWellFormed(code: string, message: string)
	Check.expect(string.find(message, "\n", 1, true) == nil, `{code}'s example must be one line`)

	local lowered = string.lower(message)
	for _, word in JUDGEMENT_WORDS do
		local isUsed = string.find(lowered, `%f[%a]{word}%f[%A]`) ~= nil
		Check.expect(not isUsed, `{code}'s example must not use the word "{word}"`)
	end
end

local function expectMessageGrammar(code: string, message: string)
	local _, line, body, exampleCode, rest = string.match(message, MESSAGE_PATTERN)
	Check.expect(line ~= nil, `{code}'s example must be "source:line: [Lync] code: ..."`)
	Check.expectEqual(exampleCode, code, `{code}'s example code`)
	Check.expect(#(body :: string) <= MAX_BODY_BYTES, `{code}'s example must be at most 200 bytes`)
	Check.expect(
		string.find(rest :: string, " must ", 1, true) ~= nil,
		`{code}'s example must say "must"`
	)
end

local function expectLineGrammar(code: string, message: string)
	local lineCode = string.match(message, LINE_PATTERN)
	Check.expectEqual(lineCode, code, `{code}'s example must be "[Lync] {code}: ..."`)
	Check.expect(#message <= MAX_BODY_BYTES, `{code}'s example must be at most 200 bytes`)
end

local function expectTriggerRaisesExample(code: string, text: string)
	local source, trigger = triggerOf(text)
	Check.expect(source ~= nil, `{code} must name its trigger module: "The module \`...\`:"`)
	Check.expect(trigger ~= nil, `{code} must have a luau trigger block`)
	if RAISED_BY_UNIT_F[code] then
		return
	end

	local message = messageOf(source :: string, trigger :: string)
	Check.expect(message ~= nil, `{code}'s trigger must raise`)
	Check.expectEqual(message, exampleOf(text), `{code}'s example`)
end

-- Tests -------------------------------------------------------------------------------------------

local tests = {
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
			if family ~= "fact" then
				continue
			end

			local evidence = (Codes.evidence :: any)[code]
			local listed = if evidence == nil
				then SUPPRESSED_EVIDENCE
				else table.concat(evidence, ", ")
			Check.expectEqual(fields.evidence, listed, `{code} evidence, in Codes.evidence's order`)
		end
	end,

	["every example follows its family's grammar (v5.md §7.1, §7.4)"] = function()
		for code, text in pageCodes() do
			local example = exampleOf(text)
			Check.expect(example ~= nil, `{code} must have an example block`)

			local message = example :: string
			local family = (Codes.family :: any)[code]
			expectWellFormed(code, message)
			if THROWN_FAMILIES[family] then
				expectMessageGrammar(code, message)
			elseif family == "fact" then
				expectLineGrammar(code, message)
			else
				Check.expectEqual(message, outcomeOf(code), `{code}'s example`)
			end
		end
	end,

	["the Failure type lists exactly the outcome codes"] = function()
		local source = fs.readFile(TYPES_SOURCE)
		local union = string.match(source, "export type Failure = ([^\n]+)")
		Check.expect(union ~= nil, "types.luau must declare export type Failure")

		local typed: { [string]: boolean } = {}
		for code in string.gmatch(union :: string, '"(%a+)"') do
			typed[code] = true
			Check.expectEqual((Codes.family :: any)[code], "outcome", `Failure's {code}`)
		end

		for code, family in Codes.family do
			if family == "outcome" then
				Check.expect(typed[code] == true, `{code} must be in the Failure type`)
			end
		end
	end,

	["every code is named by a test"] = function()
		local texts = {}
		specTexts(TESTS, texts)

		for code in Codes.family do
			if RAISED_BY_UNIT_F[code] then
				continue
			end

			Check.expect(isNamedByTest(code, texts), `{code} must be triggered by a test naming it`)
		end
	end,
}

for code, text in pageCodes() do
	local family = (Codes.family :: any)[code]
	tests[`{code}: the example is the output Lync gives`] = function()
		if THROWN_FAMILIES[family] then
			expectTriggerRaisesExample(code, text)
		elseif family == "fact" then
			Check.expectEqual(exampleOf(text), consoleLineOf(code), `{code}'s console line`)
		else
			Check.expectEqual(exampleOf(text), outcomeOf(code), `{code}'s result`)
		end
	end
end

return tests
