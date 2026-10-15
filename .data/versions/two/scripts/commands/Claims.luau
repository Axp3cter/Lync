--!strict

--[=[
	Claims

	Audits the claims without Studio: first the spec's own ids, references and proof kinds, then the
	claims that the tests and benchmarks cite, then the type tests, and last it reports where the
	claims stand.

	The spec is audited before the citations, and the citations before the type tests, because each
	can only be checked against what comes before it. The first audit that finds a problem stops
	the rest.

	A claim that no test cites is not a problem: it is untested, and the report lists it under its
	proof kind. A claim proved by review or by waiver needs no citing test.

	The Typed and Inferred claims are judged by luau-lsp over `test/types`, and the report counts
	the ones proved, failing and untested. The Declared claims wait for tsc, which is not built yet.

	Every operation here yields.

	A failure comes back as a Result whose clause names the problems.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Citations = require("../project/Citations")
local Paths     = require("../project/Paths")
local Problems  = require("../project/Problems")
local Spec      = require("../project/Spec")
local Types     = require("../Types")
local TypeTests = require("../project/TypeTests")


-- Module ------------------------------------------------------------------------------------------

local Claims = {}


-- Private -----------------------------------------------------------------------------------------

local function summarize(spec: Spec.Contents, citationCount: number): ()
	local withdrawnCount = Spec.withdrawnCountOf(spec)
	local countedCount   = #spec.claims - withdrawnCount

	local claimPart    = `claims: {countedCount} counted, {withdrawnCount} withdrawn`
	local citationPart = `citations: {citationCount}`
	print(`spec files: {#spec.areas}; {claimPart}; {citationPart}`)
end


local function reportUncited(
	kind:   Spec.ProofKind,
	claims: { read Spec.Claim },
	spec:   Spec.Contents,
	cited:  Citations.Contents
): ()
	local uncited = Citations.uncitedOf(claims, cited)
	print(`{kind}: {#uncited} of {#claims} have no citing test`)
	for _, line in Spec.spellByArea(spec, uncited) do
		print(line)
	end
end


local function reportTyped(
	kind:   Spec.ProofKind,
	claims: { read Spec.Claim },
	spec:   Spec.Contents,
	typed:  TypeTests.Contents
): ()
	local provedCount              = 0
	local failingCount             = 0
	local untested: { Spec.Claim } = {}
	for _, claim in claims do
		local state = typed.stateByClaimId[claim.id]
		if state == nil then
			table.insert(untested, claim)
		elseif state == "Proved" then
			provedCount += 1
		elseif state == "Failing" then
			failingCount += 1
		else
			local _: never = state
		end
	end

	print(`{kind}: {provedCount} proved, {failingCount} failing, {#untested} untested`)
	for _, line in Spec.spellByArea(spec, untested) do
		print(line)
	end
end


local function reportKind(
	kind:  Spec.ProofKind,
	spec:  Spec.Contents,
	cited: Citations.Contents,
	typed: TypeTests.Contents
): ()
	local claims = Spec.countedClaimsOf(spec, kind)
	local judge  = Spec.JUDGE_BY_KIND[kind]
	if judge == "Test" then
		reportUncited(kind, claims, spec, cited)
	elseif judge == "TypeRunner" then
		reportTyped(kind, claims, spec, typed)
	elseif judge == "Tsc" then
		print(`{kind}: {#claims} checked by tsc, not yet built`)
	elseif judge == "Review" then
		print(`{kind}: {#claims} need no citing test`)
	else
		local _: never = judge
	end
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Audits the spec and its citations, then reports the claims that no test cites, by proof kind.

	@return nothing once the audits found no problem, or the clause that names the problems
]=]
function Claims.audit(): Types.Result<nil>
	local specRead = Spec.read()
	if not specRead.ok then
		return specRead
	end

	local spec = specRead.value
	if #spec.problems > 0 then
		return Problems.failureOf(`"{Paths.FOLDER.spec}"`, spec.problems)
	end

	local citationsRead = Citations.read(spec)
	if not citationsRead.ok then
		return citationsRead
	end

	local cited = citationsRead.value
	if #cited.problems > 0 then
		local subject = `"{Paths.FOLDER.test}" and "{Paths.FOLDER.bench}"`
		return Problems.failureOf(subject, cited.problems)
	end

	local typedRun = TypeTests.run(cited)
	if not typedRun.ok then
		return typedRun
	end

	local typed = typedRun.value
	if #typed.problems > 0 then
		return Problems.failureOf(`"{Paths.TEST.types}"`, typed.problems)
	end

	summarize(spec, #cited.citations)

	for _, kind in Spec.PROOF_KINDS do
		reportKind(kind, spec, cited, typed)
	end

	return { ok = true, value = nil }
end


return table.freeze(Claims)
