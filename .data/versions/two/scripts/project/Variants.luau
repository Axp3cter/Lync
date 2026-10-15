--!strict

--[=[
	Variants

	Describes the four variants as data: the darklua runs that make each one, its Rojo project, and
	whether it is served to Studio.

	A variant is one or more runs.

	A run rewrites one input into one output with one darklua configuration, so a command that
	builds a variant only walks its runs in order.

	A run writes under the `output` folder of its variant, in a place named like its input, except
	the one run of the bundle, which writes a single file.

	A run with the version source "Package" is given the package version in the environment
	variable LYNC_VERSION.

	A run with the version source "Default" is given none, even when the user's shell holds one, so
	the default in its darklua configuration applies.

	A variant has a name for code, such as "Bench", and a word for the command line, such as
	"bench".

	Turning a word into a name happens in `toName`, and nowhere else.

	Turning names into variants happens in `variantsOf`, and nowhere else.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Paths = require("./Paths")
local Tools = require("../system/Tools")
local Types = require("../Types")


-- Module ------------------------------------------------------------------------------------------

local Variants = {}


-- Types -------------------------------------------------------------------------------------------

--- Where the version in a run's output comes from: the package, or its configuration's default.
type VersionSource = "Package" | "Default"


--[=[
	One darklua run: one input rewritten into one output.

	@field input         the file or folder that darklua reads
	@field output        where darklua writes, laid out like `input`
	@field config        the darklua configuration that rewrites `input`
	@field versionSource where the version in the output comes from
	@field removals      the paths below `output` that the variant leaves out, removed once written
]=]
export type Run = {
	read input:         string,
	read output:        string,
	read config:        string,
	read versionSource: VersionSource,
	read removals:      { read string },
}


--- Names one of the four variants, and keys every table that has an entry for each of them.
export type Name =
	| "Test"
	| "Bench"
	| "Release"
	| "Bundle"


--[=[
	One variant: the runs that make it, and the folder and Rojo project that hold its output.

	@field word        how the command line spells the variant
	@field output      the folder that every run of the variant writes into
	@field rojoProject the Rojo project that serves or builds the output, nil for the bundle
	@field isServed    whether Studio syncs the variant during development, so it is one to serve
	@field runs        the darklua runs that make the variant, in the order they are made
]=]
export type Variant = {
	read word:        string,
	read output:      string,
	read rojoProject: string?,
	read isServed:    boolean,
	read runs:        { read Run },
}


-- Constants ---------------------------------------------------------------------------------------

--- The variants that `build` makes when it is given none, in the order it makes them.
const DEFAULT_ORDER: { read Name } = {
	"Test",
	"Bench",
	"Release",
	"Bundle",
}
table.freeze(DEFAULT_ORDER)


--- The environment variable that the darklua configurations read the version from.
const VERSION_VARIABLE = "LYNC_VERSION"


--- The removals of a run that ships everything it writes.
const NO_REMOVALS: { read string } = {}
table.freeze(NO_REMOVALS)


--- The type tests inside the test variant, which hold files for the checker and no suites.
const TYPE_TESTS_REMOVALS: { read string } = {
	`{Paths.OUTPUT.test}/{Paths.TEST.types}`,
}
table.freeze(TYPE_TESTS_REMOVALS)


-- Private -----------------------------------------------------------------------------------------

--[=[
	Returns the run that rewrites `input` with `config`.

	Its output is `variantOutput` and `input` joined by "/", laid out like the input, because
	darklua rewrites the aliases in a run's requires into paths that hold only for that layout.

	@param  variantOutput the folder that the run's variant writes into
	@param  input         the file or folder that darklua reads
	@param  config        the darklua configuration that rewrites `input`
	@param  versionSource where the version in the output comes from
	@param  removals      the paths below the output that the variant does not ship
	@return the run, ready to list in its variant
]=]
local function runOf(
	variantOutput: string,
	input:         string,
	config:        string,
	versionSource: VersionSource,
	removals:      { read string }
): Run
	return {
		input         = input,
		output        = `{variantOutput}/{input}`,
		config        = config,
		versionSource = versionSource,
		removals      = removals,
	}
end


local function wordsOf(names: { read Name }, variantByName: { read [Name]: Variant }): { string }
	local words = table.create(#names) :: { string }
	for i, name in names do
		local variant = variantByName[name]
		words[i]      = variant.word
	end

	return words
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Every variant, by name.

	Only the map is frozen: the records inside it are read-only through their types.
]=]
const VARIANT_BY_NAME: Types.Complete<{ read [Name]: Variant }> = {
	Test = {
		word        = "test",
		output      = Paths.OUTPUT.test,
		rojoProject = Paths.ROJO.test,
		isServed    = true,
		runs        = {
			runOf(
				Paths.OUTPUT.test,
				Paths.FOLDER.source,
				Paths.DARKLUA.test,
				"Default",
				NO_REMOVALS
			),
			runOf(
				Paths.OUTPUT.test,
				Paths.FOLDER.test,
				Paths.DARKLUA.test,
				"Default",
				TYPE_TESTS_REMOVALS
			),
			runOf(
				Paths.OUTPUT.test,
				Paths.FOLDER.harness,
				Paths.DARKLUA.test,
				"Default",
				NO_REMOVALS
			),
		},
	},

	Bench = {
		word        = "bench",
		output      = Paths.OUTPUT.bench,
		rojoProject = Paths.ROJO.bench,
		isServed    = true,
		runs        = {
			-- The bench times what ships, so its source is the release's: same configuration and
			-- same version.
			runOf(
				Paths.OUTPUT.bench,
				Paths.FOLDER.source,
				Paths.DARKLUA.release,
				"Package",
				NO_REMOVALS
			),
			runOf(
				Paths.OUTPUT.bench,
				Paths.FOLDER.bench,
				Paths.DARKLUA.bench,
				"Default",
				NO_REMOVALS
			),
			runOf(
				Paths.OUTPUT.bench,
				Paths.FOLDER.harness,
				Paths.DARKLUA.bench,
				"Default",
				NO_REMOVALS
			),
		},
	},

	Release = {
		word        = "release",
		output      = Paths.OUTPUT.release,
		rojoProject = Paths.ROJO.release,
		isServed    = false,
		runs        = {
			runOf(
				Paths.OUTPUT.release,
				Paths.FOLDER.source,
				Paths.DARKLUA.release,
				"Package",
				NO_REMOVALS
			),
		},
	},

	Bundle = {
		word        = "bundle",
		output      = Paths.OUTPUT.bundle,
		rojoProject = nil,
		isServed    = false,
		runs        = {
			-- This run is spelled out because its output is one file, not a layout of its input.
			{
				input         = Paths.FILE.entry,
				output        = Paths.FILE.bundle,
				config        = Paths.DARKLUA.bundle,
				versionSource = "Package",
				removals      = NO_REMOVALS,
			},
		},
	},
}
table.freeze(VARIANT_BY_NAME)


Variants.DEFAULT_ORDER   = DEFAULT_ORDER
Variants.VARIANT_BY_NAME = VARIANT_BY_NAME


--- The command-line words of `DEFAULT_ORDER`, in the same order, for a message that lists them.
Variants.WORDS = table.freeze(wordsOf(DEFAULT_ORDER, VARIANT_BY_NAME))


--[=[
	Returns the change to a tool's environment that `run` needs when its variant is built with
	`version`.

	@param  run     the darklua run about to start
	@param  version the package version, nil when no run of the build is given it
	@return the change that sets LYNC_VERSION to `version`, or clears it for a "Default" run
	@error  when `version` is nil or empty for a "Package" run
]=]
function Variants.environmentChangesOf(run: Run, version: string?): Tools.EnvironmentChanges
	if run.versionSource == "Package" then
		if version == nil then
			error('version must not be nil for a "Package" run, got nil', 2)
		end

		if version == "" then
			error('version must not be empty, got ""', 2)
		end

		return {
			[VERSION_VARIABLE] = { kind = "Set", value = version },
		}
	elseif run.versionSource == "Default" then
		return {
			[VERSION_VARIABLE] = { kind = "Unset" },
		}
	end

	local unhandled: never = run.versionSource
	return unhandled
end


--[=[
	Returns whether `run` is given the package version.

	@param  run the darklua run to ask about
	@return true for a "Package" run, false for a "Default" run
]=]
function Variants.isGivenPackageVersion(run: Run): boolean
	if run.versionSource == "Package" then
		return true
	elseif run.versionSource == "Default" then
		return false
	end

	local unhandled: never = run.versionSource
	return unhandled
end


--[=[
	Returns the name of the variant that a command-line word spells.

	A word must match exactly, so "Test" is not "test".

	@param  word the word a user typed to choose a variant
	@return the name of the variant whose `word` it is, nil when no variant has that word
]=]
function Variants.toName(word: string): Name?
	for name, variant in VARIANT_BY_NAME do
		if variant.word == word then
			return name
		end
	end

	return nil
end


--[=[
	Returns the variant for each of `names`, in the same order.

	@param  names the variants to look up, in the order to return them
	@return the variants, one for each name, a repeated name giving the same variant again
]=]
function Variants.variantsOf(names: { read Name }): { read Variant }
	local variants = table.create(#names) :: { Variant }
	for i, name in names do
		variants[i] = VARIANT_BY_NAME[name]
	end

	return variants
end


return table.freeze(Variants)
