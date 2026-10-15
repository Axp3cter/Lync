--!strict

--[=[
	Problems

	Words the problems that an audit found as one failure, so that every command that audits says
	them alike.

	A problem is one finding, worded as a requirement, such as one that `Spec` or `Citations` gives.

	Nothing here yields.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Types = require("../Types")


-- Module ------------------------------------------------------------------------------------------

local Problems = {}


-- Public ------------------------------------------------------------------------------------------

--[=[
	Words problems as one failure, such as `"spec" must pass the claims audit, got 2 problems: ...`.

	@param  subject  what the audit looked at, which the failure names
	@param  problems the findings of the audit, at least one
	@return the failure that says how many problems there are, and what each is
	@error  when `problems` is empty
]=]
function Problems.failureOf(subject: string, problems: { string }): Types.Result<never>
	if #problems == 0 then
		error("problems must not be empty, got none", 2)
	end

	local problemCount = #problems
	local noun         = if problemCount == 1 then "problem" else "problems"
	local problemList  = table.concat(problems, "; ")
	local requirement  = `{subject} must pass the claims audit`

	return { ok = false, error = `{requirement}, got {problemCount} {noun}: {problemList}` }
end


return table.freeze(Problems)
