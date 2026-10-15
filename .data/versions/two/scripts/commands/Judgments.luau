--!strict

--[=[
	Judgments

	Judges a saved report of a Studio run against the spec: which claims the run proves, which tests
	failed, and whether the run passes.

	The spec and what the tests cite are read first, because a report can only be judged against a
	spec that holds together. The first step that finds a problem stops the rest.

	A report of benchmarks is refused: comparing it with the baselines is staged for later, and so
	are the coverage gate and the judging of reports that arrive as Output lines.

	The Typed and Inferred claims are judged by the type tests that `claims` runs, the Declared
	claims by tsc, which is not built yet, and the Reviewed claims by review, so a report says
	nothing of them.

	Every operation here yields.

	A failure comes back as a Result whose clause names the problems. A run that fails is one of
	them, but a run that proves nothing yet is a success that says so.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Citations = require("../project/Citations")
local Files     = require("../system/Files")
local Paths     = require("../project/Paths")
local Problems  = require("../project/Problems")
local Reports   = require("../project/Reports")
local Spec      = require("../project/Spec")
local Types     = require("../Types")


-- Module ------------------------------------------------------------------------------------------

local Judgments = {}


-- Private -----------------------------------------------------------------------------------------

local function printFailure(outcome: Reports.Outcome): ()
	local failure = outcome.failure or "no message"
	local lines   = string.split(failure, "\n")
	local place   = `{outcome.id} [{outcome.dataModel}]`
	print(`  {place} {outcome.verdict}: {lines[1]}`)
end


local function printSkip(outcome: Reports.Outcome): ()
	local reason = outcome.reason or "no reason"
	local lines  = string.split(reason, "\n")
	print(`  {outcome.id} [{outcome.dataModel}]: {lines[1]}`)
end


local function printWaiver(claim: Spec.Claim): ()
	local reason = claim.reason or "no reason recorded"
	print(`  {claim.id}: {reason}`)
end


local function printUnjudged(spec: Spec.Contents): ()
	for _, kind in Spec.PROOF_KINDS do
		local judge = Spec.JUDGE_BY_KIND[kind]
		if judge == "Test" then
			continue
		end

		if kind == "Waived" then
			continue
		end

		local claims = Spec.countedClaimsOf(spec, kind)
		if judge == "TypeRunner" then
			print(`{kind}: {#claims} judged by the type tests of claims`)
		elseif judge == "Tsc" then
			print(`{kind}: {#claims} checked by tsc, not yet built`)
		elseif judge == "Review" then
			print(`{kind}: {#claims} judged by review`)
		else
			local _: never = judge
		end
	end
end


local function whyNotFull(report: Reports.Report): string
	if report.filter ~= "" then
		return `the run was filtered by "{report.filter}"`
	end

	return "the run did not finish"
end


local function describe(report: Reports.Report, standing: Reports.Standing, spec: Spec.Contents): ()
	local buildPart = `build {report.buildId}`
	local runPart   = `seed {report.seed}; profile {report.profile}; outcomes: {#report.outcomes}`
	print(`report: {report.kind}; {buildPart}; {runPart}`)

	if standing.isFull then
		for _, state in Reports.CLAIM_STATES do
			local claims = standing.claimsByState[state]
			print(`{state}: {#claims}`)
			if state == "Waived" then
				for _, claim in claims do
					printWaiver(claim)
				end
			else
				for _, line in Spec.spellByArea(spec, claims) do
					print(line)
				end
			end
		end
	else
		print(`no claim is judged: {whyNotFull(report)}`)
	end

	if #standing.failures > 0 then
		print("failures:")
		for _, outcome in standing.failures do
			printFailure(outcome)
		end
	end

	if #standing.skips > 0 then
		print("skipped:")
		for _, outcome in standing.skips do
			printSkip(outcome)
		end
	end

	if #standing.problems > 0 then
		print("problems:")
		for _, problem in standing.problems do
			print(`  {problem}`)
		end
	end

	if #standing.staleClaims > 0 then
		local folder = Paths.FOLDER.test
		print(`stale: {#standing.staleClaims} cited in {folder} but absent from the report`)
		for _, line in Spec.spellByArea(spec, standing.staleClaims) do
			print(line)
		end
	end

	printUnjudged(spec)
	print(`ruling: {standing.ruling}`)
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Judges the saved report `path` against the spec, and prints where the claims stand.

	@param  path the JSON file of the report, relative to the working directory
	@return "Pass", "Incomplete" for a run that proves nothing yet, or why it failed or was refused
	@error  when `path` is not relative names joined by "/"
]=]
function Judgments.give(path: string): Types.Result<"Pass" | "Incomplete">
	if not Files.isRelativePath(path) then
		error(`path must be relative names joined by "/", got "{path}"`, 2)
	end

	local specRead = Spec.read()
	if not specRead.ok then
		return specRead
	end

	local spec = specRead.value
	if #spec.problems > 0 then
		return Problems.failureOf(`"{Paths.FOLDER.spec}"`, spec.problems)
	end

	local citedRead = Citations.read(spec)
	if not citedRead.ok then
		return citedRead
	end

	local cited = citedRead.value
	if #cited.problems > 0 then
		local subject = `"{Paths.FOLDER.test}" and "{Paths.FOLDER.bench}"`
		return Problems.failureOf(subject, cited.problems)
	end

	local textRead = Files.read(path)
	if not textRead.ok then
		return textRead
	end

	local parsed = Reports.parse(textRead.value, path)
	if not parsed.ok then
		return parsed
	end

	local report = parsed.value
	if report.kind == "bench" then
		local requirement = `"{path}" must be a report of tests`
		return { ok = false, error = `{requirement}, got a bench report, which is not judged yet` }
	end

	local standing = Reports.standingOf(report, spec, cited)
	describe(report, standing, spec)

	local ruling = standing.ruling
	if ruling == "Pass" then
		return { ok = true, value = "Pass" }
	elseif ruling == "Incomplete" then
		return { ok = true, value = "Incomplete" }
	elseif ruling == "Fail" then
		local counts = `failures: {#standing.failures}, problems: {#standing.problems}`
		return { ok = false, error = `"{path}" must pass its tests, got {counts}` }
	end

	local unhandled: never = ruling
	return unhandled
end


return table.freeze(Judgments)
