--!strict

--[=[
	Runs

	Reads the version that the darklua runs of variants need, and rewrites the runs of a variant.

	A run is given the package version or not, as its version source says, so the version is read
	only when some run of the variants in hand is given it.

	Every operation here yields.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Files    = require("../system/Files")
local Tools    = require("../system/Tools")
local Types    = require("../Types")
local Variants = require("./Variants")
local Versions = require("./Versions")


-- Module ------------------------------------------------------------------------------------------

local Runs = {}


-- Private -----------------------------------------------------------------------------------------

local function hasRunGivenVersion(variant: Variants.Variant): boolean
	for _, run in variant.runs do
		if Variants.isGivenPackageVersion(run) then
			return true
		end
	end

	return false
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Reads the package version when some run of `variants` is given it.

	@param  variants the variants whose runs are about to be rewritten
	@return the version, nil when no run is given it, or why the manifest could not be read
]=]
function Runs.readNeededVersion(variants: { read Variants.Variant }): Types.Result<string?>
	for _, variant in variants do
		if hasRunGivenVersion(variant) then
			return Versions.read()
		end
	end

	return { ok = true, value = nil }
end


--[=[
	Rewrites each run of `variant` once, in order, and removes what its variant does not ship.

	@param  variant the variant whose runs are about to be rewritten
	@param  version the package version, nil when no run of `variant` is given it
	@return nothing, or why a run could not be rewritten or what its variant omits not removed
	@error  when a run of `variant` is given the package version and `version` is nil or empty
]=]
function Runs.rewrite(variant: Variants.Variant, version: string?): Types.Result<nil>
	if hasRunGivenVersion(variant) then
		if version == nil then
			error('version must not be nil for a "Package" run, got nil', 2)
		end

		if version == "" then
			error('version must not be empty, got ""', 2)
		end
	end

	for _, run in variant.runs do
		local changeByVariable = Variants.environmentChangesOf(run, version)
		local rewritten        = Tools.rewrite(run.input, run.output, run.config, changeByVariable)
		if not rewritten.ok then
			return rewritten
		end

		for _, removal in run.removals do
			local removed = Files.remove(removal)
			if not removed.ok then
				return removed
			end
		end
	end

	return { ok = true, value = nil }
end


return table.freeze(Runs)
