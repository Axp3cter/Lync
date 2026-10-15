--!strict

--[=[
	Tools

	Runs the pinned command-line tools for the repository scripts and turns each run into a Result.

	Every operation here yields.

	A tool is started by its plain name, which rokit resolves to the version that `rokit.toml` pins.

	Rokit must already be installed, because it provides a shim for every tool.

	The scripts must therefore start in the repository root: from another folder rokit may resolve
	a different version, or none.

	What a tool prints is captured while it runs. Once the tool has finished, its standard output
	and then its standard error are printed through `print`, each without its final line break,
	except what `diagnose` reads from luau-lsp, which it returns.

	The two operations that keep a tool running, `watch` and `serve`, do not capture: the tool
	writes straight to the terminal.

	Lute 1.0.0 cannot stop a tool that has been started, because `process.run` has no timeout and
	no handle to stop a child. A tool that hangs, or that outlives the script, is ended by Ctrl+C,
	which reaches every process of the terminal.

	A failure outside the scripts, such as a tool that does not start, exits with an error, or logs
	a warning, comes back as a Result.

	A mistake by the caller throws.
]=]


-- Imports -----------------------------------------------------------------------------------------

local process   = require("@std/process")
local stringext = require("@std/stringext")
local Types     = require("../Types")


-- Module ------------------------------------------------------------------------------------------

local Tools = {}


-- Types -------------------------------------------------------------------------------------------

--[=[
	A command-line tool, and how to read what it prints.

	@field name         the tool's plain name, which rokit resolves
	@field causePattern which line of the output a failure quotes, preferably
	@field dropPattern  which lines are left out when the output is forwarded, nil for none
]=]
type Tool = {
	read name:         string,
	read causePattern: string,
	read dropPattern:  string?,
}


--- A platform that luau-lsp can analyze code for.
type Platform = "Roblox" | "Standard"


--[=[
	How luau-lsp analyzes: which platform the code is for, and what it reads besides its own files.

	@field platform         the platform whose globals the code reads
	@field definitionByName the definition files to load, by the name that the code reads them under
	@field baseLuaurc       the absolute path of the configuration that the code's own one builds on
	@field ignores          the globs of the files whose errors are not reported
]=]
export type AnalysisOptions = {
	read platform:         Platform,
	read definitionByName: { read [string]: string },
	read baseLuaurc:       string?,
	read ignores:          { read string },
}


--[=[
	One finding that luau-lsp reported: a type error, a syntax error, or a lint warning.

	@field path    the file it is about, spelled as luau-lsp spells it
	@field line    the line where it starts, counted from 1
	@field column  the column where it starts, counted from 1
	@field name    what luau-lsp calls it: "TypeError" or "SyntaxError", or the name of the lint
	@field isError whether it is a type error or a syntax error, not a lint warning
	@field message the first line of what luau-lsp says about it
]=]
export type Diagnostic = {
	read path:    string,
	read line:    number,
	read column:  number,
	read name:    string,
	read isError: boolean,
	read message: string,
}


type Clearing = {
	callCount:       number,
	read savedValue: string?,
}


--[=[
	What a call does to one environment variable of the tool it starts.

	@field kind  whether the tool is given the variable ("Set") or left without it ("Unset")
	@field value what "Set" gives the tool, whatever this process holds; absent for "Unset"
]=]
type EnvironmentChange =
	| { read kind: "Set", read value: string }
	| { read kind: "Unset" }


--[=[
	Changes to the environment of the tool that a call starts, by the name of the variable.

	A variable that is not listed reaches the tool as this process holds it.

	Lute starts a tool with this process's environment plus the values it is given, which cannot
	remove a variable.

	An "Unset" variable is therefore cleared from this process while the call runs and put back when
	it ends.

	Any other tool started meanwhile lacks the variable too.
]=]
export type EnvironmentChanges = { read [string]: EnvironmentChange }


-- Constants ---------------------------------------------------------------------------------------

--- Matches every line, so that the first line of an output is the one a failure quotes.
const ANY_LINE_PATTERN = ""


--- Matches the escape sequences that set colors, which a tool writes when a user forces color on.
const COLOR_PATTERN = "\x1B%[[%d;]*m"


--- Captures the folder in the line that `lute setup` prints before it writes the definitions.
const DEFINITIONS_FOLDER_PATTERN = "^Writing definitions at (.+)$"


--[=[
	Captures the file, line, column, name and first line of a finding in a line that luau-lsp
	prints, such as "test/types/A.luau(4,19): TypeError: Expected this to be 'number'".
]=]
const DIAGNOSTIC_PATTERN = "^(.+)%((%d+),(%d+)%): (%w+): (.*)$"


--- Matches a line that darklua logs as an error.
const ERROR_PATTERN = "^ERROR > "


--- Matches the line break that ends a text.
const FINAL_NEWLINE_PATTERN = "\r?\n$"


--- Matches a progress line that luau-lsp prints, which the forwarded output leaves out.
const INFO_PATTERN = "^%[INFO%] "


--- Matches one line of a text, without its line break.
const LINE_PATTERN = "[^\r\n]+"


--- Matches the position that luau-lsp prints before each error, such as "(12,5): ".
const LOCATION_PATTERN = "%(%d+,%d+%): "


--- Captures the number of files in the line that darklua prints when it finishes.
const PROCESSED_PATTERN = "successfully processed (%d+) files?"


--[=[
	Captures libuv's cause in the error that `process.run` throws when a tool does not start.

	The standard library puts its own position in front of Lute's message, so the pattern is not
	anchored.
]=]
const SPAWN_FAILURE_PATTERN = "Failed to spawn process: (.+)$"


--- Matches a line that darklua logs as a warning.
const WARNING_PATTERN = "^WARN > "


--- What `lute setup` writes for the home folder, at the start of a path.
const HOME_MARK = "~"


--- The names that luau-lsp gives the findings that are errors, not lint warnings.
const ERROR_NAMES: { read [string]: true } = {
	TypeError   = true,
	SyntaxError = true,
}
table.freeze(ERROR_NAMES)


--- The word that the `--platform` option of luau-lsp takes for each platform.
const WORD_BY_PLATFORM: Types.Complete<{ read [Platform]: string }> = {
	Roblox   = "roblox",
	Standard = "standard",
}
table.freeze(WORD_BY_PLATFORM)


const NO_CHANGES: EnvironmentChanges = {}
table.freeze(NO_CHANGES)


const DARKLUA: Tool = {
	name         = "darklua",
	causePattern = ERROR_PATTERN,
	dropPattern  = nil,
}


const LUAU_LSP: Tool = {
	name         = "luau-lsp",
	causePattern = LOCATION_PATTERN,
	dropPattern  = INFO_PATTERN,
}


const LUTE: Tool = {
	name         = "lute",
	causePattern = ANY_LINE_PATTERN,
	dropPattern  = nil,
}


const ROJO: Tool = {
	name         = "rojo",
	causePattern = ANY_LINE_PATTERN,
	dropPattern  = nil,
}


const ROKIT: Tool = {
	name         = "rokit",
	causePattern = ANY_LINE_PATTERN,
	dropPattern  = nil,
}


-- State -------------------------------------------------------------------------------------------

-- Calls can overlap, so the first call that needs a variable gone clears it and keeps its value
-- here, and the last of them to finish puts the value back.
local clearingByVariable: { [string]: Clearing } = {}


-- Private -----------------------------------------------------------------------------------------

local function stripColors(text: string): string
	local plain = string.gsub(text, COLOR_PATTERN, "")
	return plain
end


local function linesOf(text: string): { string }
	local lines: { string } = {}
	for line in string.gmatch(stripColors(text), LINE_PATTERN) do
		local content = stringext.trim(line)
		if content == "" then
			continue
		end

		table.insert(lines, content)
	end

	return lines
end


--[=[
	Returns the line of `text` that a failure quotes as what went wrong.

	@param  text         what a tool printed to one of its streams
	@param  causePattern which line to prefer
	@return the first line that matches `causePattern`, otherwise the first line, nil for no line
]=]
local function detailOf(text: string, causePattern: string): string?
	local lines = linesOf(text)
	for _, line in lines do
		if string.find(line, causePattern) ~= nil then
			return line
		end
	end

	if #lines == 0 then
		return nil
	end

	return lines[1]
end


local function isProblem(line: string): boolean
	local isWarning = string.find(line, WARNING_PATTERN) ~= nil
	local isError   = string.find(line, ERROR_PATTERN) ~= nil
	return isWarning or isError
end


local function firstProblemOf(text: string): string?
	for _, line in linesOf(text) do
		if isProblem(line) then
			return line
		end
	end

	return nil
end


--[=[
	Returns how many files darklua says it processed.

	@param  text what darklua printed to standard output
	@return the count, nil when `text` has no line that says it
]=]
local function processedCountOf(text: string): number?
	local digits = string.match(text, PROCESSED_PATTERN)
	if digits == nil then
		return nil
	end

	return tonumber(digits)
end


--[=[
	Returns the folder that `lute setup` says it writes the definitions to.

	@param  text what `lute setup` printed to standard output
	@return the folder as printed, nil when `text` has no line that says it
]=]
local function definitionsFolderOf(text: string): string?
	for _, line in linesOf(text) do
		local folder = string.match(line, DEFINITIONS_FOLDER_PATTERN)
		if folder ~= nil then
			return folder
		end
	end

	return nil
end


local function expandHome(path: string): string
	if stringext.hasPrefix(path, HOME_MARK) then
		local homePath = tostring(process.homedir())
		local rest     = stringext.removePrefix(path, HOME_MARK)
		return `{homePath}{rest}`
	end

	return path
end


--[=[
	Returns the failure whose clause reads "`tool` could not `action`: `cause`".

	@param  tool   the tool that failed
	@param  action what the tool was asked to do, worded to follow "could not"
	@param  cause  why the tool could not, worded to follow a colon
	@return the failed Result that carries the clause
]=]
local function failureOf(tool: Tool, action: string, cause: string): Types.Result<never>
	return { ok = false, error = `{tool.name} could not {action}: {cause}` }
end


local function spawnCauseOf(message: string): string
	local cause = string.match(message, SPAWN_FAILURE_PATTERN) or message
	return `it did not start: {cause}`
end


local function exitCauseOf(processResult: process.ProcessResult, causePattern: string): string
	local signal = processResult.signal
	if signal ~= nil then
		return `it was stopped by signal {signal}`
	end

	local errorLine  = detailOf(processResult.stderr, causePattern)
	local outputLine = detailOf(processResult.stdout, causePattern)
	local detail     = errorLine or outputLine
	if detail ~= nil then
		return `it exited with code {processResult.exitcode}: {detail}`
	end

	return `it exited with code {processResult.exitcode}`
end


--[=[
	Returns `text` without the lines that match `dropPattern`.

	@param  text        what a tool printed to one of its streams
	@param  dropPattern which lines to leave out, nil to keep every line
	@return the remaining lines, joined as they were
]=]
local function withoutDropped(text: string, dropPattern: string?): string
	if dropPattern == nil then
		return text
	end

	local kept: { string } = {}
	for _, line in string.split(text, "\n") do
		if string.find(line, dropPattern) == nil then
			table.insert(kept, line)
		end
	end

	return table.concat(kept, "\n")
end


local function forward(text: string, dropPattern: string?): ()
	local shown = withoutDropped(text, dropPattern)
	if shown == "" then
		return
	end

	-- Lute 1.0.0 cannot write to standard error, and io.write hangs when standard output is a file,
	-- so every stream goes through print, whose final newline is dropped here.
	local withoutFinalNewline = string.gsub(shown, FINAL_NEWLINE_PATTERN, "")
	print(withoutFinalNewline)
end


--[=[
	Splits `changeByVariable` into the values to give a tool and the variables to take from it.

	@param  changeByVariable what each listed variable becomes for the tool
	@return the values to give the tool, by variable name
	@return the names of the variables to leave the tool without
]=]
local function partition(changeByVariable: EnvironmentChanges): ({ [string]: string }, { string })
	local valueByVariable: { [string]: string } = {}
	local unsetNames:      { string }           = {}
	for name, change in changeByVariable do
		if change.kind == "Set" then
			valueByVariable[name] = change.value
		elseif change.kind == "Unset" then
			table.insert(unsetNames, name)
		else
			local _: never = change
		end
	end

	return valueByVariable, unsetNames
end


--[=[
	Runs `tool` with some variables cleared from this process, and puts them back afterwards.

	@param  tool          the tool to start
	@param  arguments     the words that follow the tool's name on its command line
	@param  action        what the tool is asked to do, worded to follow "could not" in a failure
	@param  variableNames the variables to clear while the tool runs
	@param  options       how to start the tool
	@return what the tool left behind, or why it did not start
]=]
local function runWithout(
	tool:          Tool,
	arguments:     { string },
	action:        string,
	variableNames: { read string },
	options:       process.ProcessRunOptions
): Types.Result<process.ProcessResult>
	local commandWords = { tool.name, table.unpack(arguments) }

	for _, name in variableNames do
		local clearing = clearingByVariable[name]
		if clearing == nil then
			clearingByVariable[name] = { callCount = 1, savedValue = process.env[name] }
			process.env[name]        = nil
		else
			clearing.callCount += 1
		end
	end

	local ok, result = pcall(process.run, commandWords, options)

	for _, name in variableNames do
		local clearing = assert(clearingByVariable[name], "a restored variable must be cleared")

		clearing.callCount -= 1
		if clearing.callCount == 0 then
			clearingByVariable[name] = nil
			process.env[name]        = clearing.savedValue
		end
	end

	if not ok then
		local cause = spawnCauseOf(tostring(result))
		return failureOf(tool, action, cause)
	end

	return { ok = true, value = result }
end


--[=[
	Runs `tool` to the end and prints what it wrote.

	@param  tool             the tool to start, with how to read what it prints
	@param  arguments        the words that follow the tool's name on its command line
	@param  action           what the tool is asked to do, worded to follow "could not" in a failure
	@param  changeByVariable what each listed variable becomes for the tool
	@return what the tool left behind, or why it did not start or did not exit with code 0
]=]
local function run(
	tool:             Tool,
	arguments:        { string },
	action:           string,
	changeByVariable: EnvironmentChanges
): Types.Result<process.ProcessResult>
	local valueByVariable, unsetNames = partition(changeByVariable)

	local options: process.ProcessRunOptions = {
		cwd   = nil,
		stdio = "default",
		env   = valueByVariable,
	}

	local ran = runWithout(tool, arguments, action, unsetNames, options)
	if not ran.ok then
		return ran
	end

	local processResult = ran.value
	forward(processResult.stdout, tool.dropPattern)
	forward(processResult.stderr, tool.dropPattern)

	if not processResult.ok then
		return failureOf(tool, action, exitCauseOf(processResult, tool.causePattern))
	end

	return ran
end


--[=[
	Runs `tool` to the end, and succeeds when it exits with code 0.

	@param  tool      the tool to start, with how to read what it prints
	@param  arguments the words that follow the tool's name on its command line
	@param  action    what the tool is asked to do, worded to follow "could not" in a failure
	@return nothing, or why the tool did not start or did not exit with code 0
]=]
local function runByExitCode(tool: Tool, arguments: { string }, action: string): Types.Result<nil>
	local ran = run(tool, arguments, action, NO_CHANGES)
	if not ran.ok then
		return ran
	end

	return { ok = true, value = nil }
end


--[=[
	Runs `tool` until it exits, which is always a failure, because it was meant to keep running.

	The tool writes straight to the terminal, so nothing is captured and only the way it exited is
	judged.

	@param  tool             the tool to start, with how to read what it prints
	@param  arguments        the words that follow the tool's name on its command line
	@param  action           what the tool is asked to do, worded to follow "could not" in a failure
	@param  changeByVariable what each listed variable becomes for the tool, for as long as it runs
	@return why the tool stopped
]=]
local function runLive(
	tool:             Tool,
	arguments:        { string },
	action:           string,
	changeByVariable: EnvironmentChanges
): Types.Result<never>
	local valueByVariable, unsetNames = partition(changeByVariable)

	local options: process.ProcessRunOptions = {
		cwd   = nil,
		stdio = "inherit",
		env   = valueByVariable,
	}

	local ran = runWithout(tool, arguments, action, unsetNames, options)
	if not ran.ok then
		return ran
	end

	return failureOf(tool, action, exitCauseOf(ran.value, tool.causePattern))
end


--[=[
	Reads the findings that luau-lsp printed.

	@param  text what luau-lsp printed to one of its streams
	@return the findings, in the order printed, leaving out every line that is not the first of one
]=]
local function diagnosticsOf(text: string): { Diagnostic }
	local diagnostics: { Diagnostic } = {}
	for _, line in linesOf(text) do
		local path, lineText, columnText, name, message = string.match(line, DIAGNOSTIC_PATTERN)
		if
			path == nil
			or lineText == nil
			or columnText == nil
			or name == nil
			or message == nil
		then
			continue
		end

		table.insert(diagnostics, {
			path    = path,
			line    = assert(tonumber(lineText), "the digits of a line must be a number"),
			column  = assert(tonumber(columnText), "the digits of a column must be a number"),
			name    = name,
			isError = ERROR_NAMES[name] == true,
			message = message,
		})
	end

	return diagnostics
end


local function processArgumentsOf(input: string, output: string, config: string): { string }
	return {
		"process",
		input,
		output,
		"--config",
		config,
	}
end


local function analyzeArgumentsOf(paths: { read string }, options: AnalysisOptions): { string }
	local platformWord = WORD_BY_PLATFORM[options.platform]

	local arguments = {
		"analyze",
		"--flag:LuauSolverV2=true",
		`--platform={platformWord}`,
	}

	local names: { string } = {}
	for name in options.definitionByName do
		table.insert(names, name)
	end

	table.sort(names)
	for _, name in names do
		local definitionPath = options.definitionByName[name]
		table.insert(arguments, `--definitions:@{name}={definitionPath}`)
	end

	local baseLuaurc = options.baseLuaurc
	if baseLuaurc ~= nil then
		table.insert(arguments, "--base-luaurc")
		table.insert(arguments, baseLuaurc)
	end

	for _, ignore in options.ignores do
		table.insert(arguments, "--ignore")
		table.insert(arguments, ignore)
	end

	for _, path in paths do
		table.insert(arguments, path)
	end

	return arguments
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Analyzes Luau files with luau-lsp, which is evidence of what its type checker and linter report.

	The new type solver is always on.

	An error fails the call, and what luau-lsp printed is forwarded, without its `[INFO]` progress
	lines.

	@param  paths   the files and folders to analyze
	@param  options how luau-lsp analyzes them
	@return nothing, or why luau-lsp did not start or reported an error
	@error  when `paths` is empty
]=]
function Tools.analyze(paths: { string }, options: AnalysisOptions): Types.Result<nil>
	if #paths == 0 then
		error("paths must not be empty, got none", 2)
	end

	local arguments = analyzeArgumentsOf(paths, options)
	local pathList  = table.concat(paths, " ")

	return runByExitCode(LUAU_LSP, arguments, `analyze "{pathList}"`)
end


--[=[
	Analyzes Luau files with luau-lsp like `analyze`, and returns what it reported.

	A file that has errors is not a failure of the call, so the findings are the answer: it fails
	only when luau-lsp reported nothing and still exited with an error.

	Nothing luau-lsp printed is forwarded.

	@param  paths   the files and folders to analyze
	@param  options how luau-lsp analyzes them
	@return the findings in the order printed, empty for code with none, or why luau-lsp failed
	@error  when `paths` is empty
]=]
function Tools.diagnose(paths: { string }, options: AnalysisOptions): Types.Result<{ Diagnostic }>
	if #paths == 0 then
		error("paths must not be empty, got none", 2)
	end

	local arguments = analyzeArgumentsOf(paths, options)
	local pathList  = table.concat(paths, " ")
	local action    = `analyze "{pathList}"`

	local runOptions: process.ProcessRunOptions = {
		cwd   = nil,
		stdio = "default",
		env   = {},
	}

	local ran = runWithout(LUAU_LSP, arguments, action, {}, runOptions)
	if not ran.ok then
		return ran
	end

	local processResult = ran.value

	local diagnostics = diagnosticsOf(processResult.stdout)
	for _, diagnostic in diagnosticsOf(processResult.stderr) do
		table.insert(diagnostics, diagnostic)
	end

	if
		#diagnostics == 0
		and not processResult.ok
	then
		return failureOf(LUAU_LSP, action, exitCauseOf(processResult, LUAU_LSP.causePattern))
	end

	return { ok = true, value = diagnostics }
end


--[=[
	Generates the type definitions of the pinned Lute, which `Tools.analyze` reads for Lute code.

	Lute decides the version and the folder, so no script keeps a second copy of that fact.

	@return the folder that holds the definitions, or why lute did not generate them
]=]
function Tools.generateLuteDefinitions(): Types.Result<string>
	local action = "generate the Lute type definitions"
	local ran    = run(LUTE, { "setup" }, action, NO_CHANGES)
	if not ran.ok then
		return ran
	end

	local processResult  = ran.value
	local reportedFolder = definitionsFolderOf(processResult.stdout)
	if reportedFolder == nil then
		return failureOf(LUTE, action, "it did not say where it wrote them")
	end

	return { ok = true, value = expandHome(reportedFolder) }
end


--[=[
	Installs every tool that `rokit.toml` pins.

	@return nothing, or why rokit did not install them
]=]
function Tools.install(): Types.Result<nil>
	return runByExitCode(ROKIT, { "install" }, "install the pinned tools")
end


--[=[
	Rewrites the Luau source at `input` into `output`, as the darklua configuration `config` says.

	`input` and `output` are both files or both folders.

	A folder is rewritten with everything under it, and `output` and the folders above it are
	created.

	Files already in `output` stay, so a folder that must hold only this run's files is removed
	first.

	The rewrite fails when darklua does not start, exits with an error, logs a warning or an error,
	or processes no file.

	darklua does the last two without changing its exit code, so the call reads its log and its
	count of files.

	@param  input            the file or folder to rewrite
	@param  output           where the rewritten source is written
	@param  config           the darklua configuration file that says how to rewrite
	@param  changeByVariable how the environment of darklua differs from this process's
	@return nothing, or why the rewrite failed
	@error  when `input`, `output` or `config` is empty
]=]
function Tools.rewrite(
	input:            string,
	output:           string,
	config:           string,
	changeByVariable: EnvironmentChanges
): Types.Result<nil>
	if input == "" then
		error('input must not be empty, got ""', 2)
	end

	if output == "" then
		error('output must not be empty, got ""', 2)
	end

	if config == "" then
		error('config must not be empty, got ""', 2)
	end

	local action    = `process "{input}"`
	local arguments = processArgumentsOf(input, output, config)

	local ran = run(DARKLUA, arguments, action, changeByVariable)
	if not ran.ok then
		return ran
	end

	local processResult = ran.value

	local problem = firstProblemOf(processResult.stderr)
	if problem ~= nil then
		return failureOf(DARKLUA, action, `its log has "{problem}"`)
	end

	local processedCount = processedCountOf(processResult.stdout)
	if processedCount == nil then
		return failureOf(DARKLUA, action, "it did not say how many files it processed")
	end

	if processedCount == 0 then
		return failureOf(DARKLUA, action, "it processed no files")
	end

	return { ok = true, value = nil }
end


--[=[
	Serves the Rojo project `project` to Roblox Studio, and returns only when rojo stops.

	Rojo writes straight to the terminal, and the call yields for as long as it runs.

	@param  project the Rojo project file to serve
	@return why rojo stopped, which it only does by failing
	@error  when `project` is empty
]=]
function Tools.serve(project: string): Types.Result<never>
	if project == "" then
		error('project must not be empty, got ""', 2)
	end

	return runLive(ROJO, { "serve", project }, `serve "{project}"`, NO_CHANGES)
end


--[=[
	Rewrites the Luau source at `input` into `output` like `rewrite`, and again whenever it changes.

	The call yields for as long as darklua runs, and returns only when it stops.

	darklua writes straight to the terminal, so the warnings and errors in its log are not judged:
	the user reads them as they appear.

	@param  input            the file or folder to rewrite
	@param  output           where the rewritten source is written
	@param  config           the darklua configuration file that says how to rewrite
	@param  changeByVariable how the environment of darklua differs, for as long as it runs
	@return why darklua stopped, which it only does by failing
	@error  when `input`, `output` or `config` is empty
]=]
function Tools.watch(
	input:            string,
	output:           string,
	config:           string,
	changeByVariable: EnvironmentChanges
): Types.Result<never>
	if input == "" then
		error('input must not be empty, got ""', 2)
	end

	if output == "" then
		error('output must not be empty, got ""', 2)
	end

	if config == "" then
		error('config must not be empty, got ""', 2)
	end

	local arguments = processArgumentsOf(input, output, config)
	table.insert(arguments, "--watch")

	return runLive(DARKLUA, arguments, `watch "{input}" into "{output}"`, changeByVariable)
end


return table.freeze(Tools)
