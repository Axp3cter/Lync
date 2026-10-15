--!strict

--[=[
	Builds

	Builds each requested variant, one after another, into the variant's output folder.

	Building a variant removes its output folder, rewrites each of its darklua runs in order, and
	audits the output.

	The audit finds the requires that Roblox cannot resolve: a module that is missing, spelled in
	another case on disk, or outside the output folder.

	The package version is read once, and only when a requested variant has a run that is given it.

	The first variant that fails stops the rest.

	Every operation here yields.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Files    = require("../system/Files")
local Requires = require("../project/Requires")
local Runs     = require("../project/Runs")
local Types    = require("../Types")
local Variants = require("../project/Variants")


-- Module ------------------------------------------------------------------------------------------

local Builds = {}


-- Private -----------------------------------------------------------------------------------------

local function auditOutput(variant: Variants.Variant): Types.Result<nil>
	local audited = Requires.audit(variant.output)
	if not audited.ok then
		return audited
	end

	local problems     = audited.value
	local problemCount = #problems
	if problemCount > 0 then
		local noun        = if problemCount == 1 then "problem" else "problems"
		local problemList = table.concat(problems, "; ")
		local requirement = `"{variant.output}" must pass the requires audit`
		return { ok = false, error = `{requirement}, got {problemCount} {noun}: {problemList}` }
	end

	return { ok = true, value = nil }
end


local function buildVariant(variant: Variants.Variant, version: string?): Types.Result<nil>
	local removed = Files.remove(variant.output)
	if not removed.ok then
		return removed
	end

	local rewritten = Runs.rewrite(variant, version)
	if not rewritten.ok then
		return rewritten
	end

	return auditOutput(variant)
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Builds each of the variants `names`, in the order given.

	@param  names the variants to build
	@return nothing, or why the first variant that failed could not be built
]=]
function Builds.make(names: { read Variants.Name }): Types.Result<nil>
	local variants = Variants.variantsOf(names)

	local read = Runs.readNeededVersion(variants)
	if not read.ok then
		return read
	end

	local version = read.value
	for _, variant in variants do
		local built = buildVariant(variant, version)
		if not built.ok then
			local subject = `variant {variant.word} could not be built`
			return { ok = false, error = `{subject}: {built.error}` }
		end

		local runCount = #variant.runs
		local noun     = if runCount == 1 then "run" else "runs"
		print(`variant {variant.word} built from {runCount} {noun} into {variant.output}`)
	end

	return { ok = true, value = nil }
end


return table.freeze(Builds)
