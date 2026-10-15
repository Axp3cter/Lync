--!strict

--[=[
	run

	Runs one command of the repository tooling, started from the repository root as
	`lute run scripts/run.luau <command> [words]`.

	This script turns the command word and the words after it into typed values, so a command
	module receives only values it can trust.

	A command that fails prints one line saying what failed and exits with code 1, and a run that
	`judge` finds incomplete exits with code 2.

	Lute has no standard-error writer, so every message goes through print.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Builds    = require("./commands/Builds")
local Claims    = require("./commands/Claims")
local Files     = require("./system/Files")
local Judgments = require("./commands/Judgments")
local Paths     = require("./project/Paths")
local Places    = require("./commands/Places")
local process   = require("@std/process")
local Sources   = require("./commands/Sources")
local Toolchain = require("./commands/Toolchain")
local Types     = require("./Types")
local Variants  = require("./project/Variants")


-- Types -------------------------------------------------------------------------------------------

--- A command of the repository tooling.
type Command =
	| "Setup"
	| "Check"
	| "Claims"
	| "Judge"
	| "Build"
	| "Dev"


--- How a command that did not fail ends: it passed, or it judged a run that proves nothing yet.
type Ending =
	| "Passed"
	| "Incomplete"


-- Constants ---------------------------------------------------------------------------------------

--- Positions in `process.args`, where 1 is the script's own path and the command words follow.
const SCRIPT_POSITION     = 1
const COMMAND_POSITION    = 2
const FIRST_WORD_POSITION = 3


--- The exit code with which each ending leaves the process.
const EXIT_CODE_BY_ENDING: Types.Complete<{ read [Ending]: number }> = {
	Passed     = 0,
	Incomplete = 2,
}
table.freeze(EXIT_CODE_BY_ENDING)


--- The word that a user types for each command.
const WORD_BY_COMMAND: Types.Complete<{ read [Command]: string }> = {
	Setup  = "setup",
	Check  = "check",
	Claims = "claims",
	Judge  = "judge",
	Build  = "build",
	Dev    = "dev",
}
table.freeze(WORD_BY_COMMAND)


-- Private -----------------------------------------------------------------------------------------

local function toCommand(word: string): Command?
	for command, commandWord in WORD_BY_COMMAND do
		if commandWord == word then
			return command
		end
	end

	return nil
end


local function usageOf(scriptPath: string, receivedText: string): string
	local words: { string } = {}
	for _, commandWord in WORD_BY_COMMAND do
		table.insert(words, commandWord)
	end

	table.sort(words)

	local wordList    = table.concat(words, ", ")
	local requirement = `command must be one of {wordList}, got {receivedText}`

	return `{requirement}; use lute run {scriptPath} <command> [words]`
end


local function inspectRoot(): Types.Result<nil>
	local inspected = Files.inspect(Paths.MANIFEST.rokit)
	if not inspected.ok then
		local clause = `could not look for {Paths.MANIFEST.rokit} here; stopping`
		return { ok = false, error = `{clause}: {inspected.error}` }
	end

	local requirement = `{Paths.MANIFEST.rokit} must be a file in the working directory`
	local fix         = "run from the repository root"

	local kind = inspected.value
	if kind == nil then
		return { ok = false, error = `{requirement}, got nothing; {fix}` }
	end

	if kind ~= "File" then
		return { ok = false, error = `{requirement}, got {kind}; {fix}` }
	end

	return { ok = true, value = nil }
end


--[=[
	Chooses the variants that the words ask for, or every variant when there are no words.

	@param  words the words after the command, each spelling one variant
	@return the names in the order asked, or the one line to print about the first unknown word
]=]
local function chooseVariants(words: { read string }): Types.Result<{ read Variants.Name }>
	if #words == 0 then
		return { ok = true, value = Variants.DEFAULT_ORDER }
	end

	local names = table.create(#words) :: { Variants.Name }
	for i, word in words do
		local name = Variants.toName(word)
		if name == nil then
			local wordList    = table.concat(Variants.WORDS, ", ")
			local requirement = `variant must be one of {wordList}`
			return { ok = false, error = `{requirement}, got "{word}"` }
		end

		names[i] = name
	end

	return { ok = true, value = names }
end


--[=[
	Frames the cause of a failure in the recovery mold.

	@param  action what the command was doing, worded to follow "could not"
	@param  cause  why it could not, as the command's clause says
	@return the failure that says so
]=]
local function frameFailure(action: string, cause: string): Types.Result<never>
	return { ok = false, error = `could not {action}; stopping: {cause}` }
end


--[=[
	Frames the failure of a command in the recovery mold.

	@param  action  what the command was doing, worded to follow "could not"
	@param  outcome what the command returned
	@return `outcome` itself when it succeeded, otherwise the framed failure
]=]
local function frame(action: string, outcome: Types.Result<nil>): Types.Result<nil>
	if outcome.ok then
		return outcome
	end

	return frameFailure(action, outcome.error)
end


local function confirmNoWords(commandWord: string, words: { read string }): Types.Result<nil>
	if #words > 0 then
		local requirement = `{commandWord} must take no words`
		return { ok = false, error = `{requirement}, got "{words[1]}"` }
	end

	return { ok = true, value = nil }
end


local function buildVariants(words: { read string }): Types.Result<nil>
	local chosen = chooseVariants(words)
	if not chosen.ok then
		return chosen
	end

	return frame("finish the build", Builds.make(chosen.value))
end


local function serveVariants(commandWord: string, words: { read string }): Types.Result<nil>
	if #words == 0 then
		local requirement = `{commandWord} must be given a variant`
		return { ok = false, error = `{requirement}, got none` }
	end

	local chosen = chooseVariants(words)
	if not chosen.ok then
		return chosen
	end

	return frame("serve the variants", Places.serve(chosen.value))
end


local function analyzeSources(commandWord: string, words: { read string }): Types.Result<nil>
	local confirmed = confirmNoWords(commandWord, words)
	if not confirmed.ok then
		return confirmed
	end

	return frame("finish the check", Sources.analyze())
end


local function auditClaims(commandWord: string, words: { read string }): Types.Result<nil>
	local confirmed = confirmNoWords(commandWord, words)
	if not confirmed.ok then
		return confirmed
	end

	return frame("finish the audit", Claims.audit())
end


local function passedWith(outcome: Types.Result<nil>): Types.Result<Ending>
	if not outcome.ok then
		return outcome
	end

	return { ok = true, value = "Passed" }
end


local function judgeReport(commandWord: string, words: { read string }): Types.Result<Ending>
	if #words ~= 1 then
		local requirement = `{commandWord} must be given one report file`
		return { ok = false, error = `{requirement}, got {#words}` }
	end

	local path = words[1]
	if not Files.isRelativePath(path) then
		local requirement = 'report file must be relative names joined by "/"'
		return { ok = false, error = `{requirement}, got "{path}"` }
	end

	local judged = Judgments.give(path)
	if not judged.ok then
		return frameFailure("finish the judgment", judged.error)
	end

	local ruling = judged.value
	if ruling == "Pass" then
		return { ok = true, value = "Passed" }
	elseif ruling == "Incomplete" then
		return { ok = true, value = "Incomplete" }
	end

	local unhandled: never = ruling
	return unhandled
end


local function installToolchain(commandWord: string, words: { read string }): Types.Result<nil>
	local confirmed = confirmNoWords(commandWord, words)
	if not confirmed.ok then
		return confirmed
	end

	return frame("finish the setup", Toolchain.install())
end


--[=[
	Dispatches the command line `arguments` to the module of the command that it names.

	The working directory must be the repository root, which is checked first.

	@param  arguments what the command line holds, starting with this script's own path
	@return how a command that succeeded ended, or the one line to print about why it did not
]=]
local function dispatch(arguments: { string }): Types.Result<Ending>
	local inspected = inspectRoot()
	if not inspected.ok then
		return inspected
	end

	local scriptPath = arguments[SCRIPT_POSITION]

	local commandWord: string? = arguments[COMMAND_POSITION]
	if commandWord == nil then
		return { ok = false, error = usageOf(scriptPath, "none") }
	end

	local command = toCommand(commandWord)
	if command == nil then
		return { ok = false, error = usageOf(scriptPath, `"{commandWord}"`) }
	end

	local words = { table.unpack(arguments, FIRST_WORD_POSITION) }

	if command == "Setup" then
		return passedWith(installToolchain(commandWord, words))
	elseif command == "Check" then
		return passedWith(analyzeSources(commandWord, words))
	elseif command == "Claims" then
		return passedWith(auditClaims(commandWord, words))
	elseif command == "Judge" then
		return judgeReport(commandWord, words)
	elseif command == "Build" then
		return passedWith(buildVariants(words))
	elseif command == "Dev" then
		return passedWith(serveVariants(commandWord, words))
	end

	local unhandled: never = command
	return unhandled
end


-- Main --------------------------------------------------------------------------------------------

local dispatched = dispatch(process.args)
if dispatched.ok then
	process.exit(EXIT_CODE_BY_ENDING[dispatched.value])
else
	print(dispatched.error)
	process.exit(1)
end
