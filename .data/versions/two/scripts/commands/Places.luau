--!strict

--[=[
	Places

	Serves variants to Roblox Studio while their source changes, so that Studio follows every edit.

	Serving a variant removes its output folder, rewrites each of its runs once, and then keeps a
	darklua watcher on every run and a rojo server on the variant's project.

	The first rewrite comes before rojo starts, because rojo refuses a project whose folder is
	missing.

	Only the variants that Studio syncs during development are served, each one once, because a
	second rojo server on the same project finds its port busy.

	The package version is read once, and only when a served variant has a run that is given it.

	A receiver listens beside the tools for the harness that runs in Studio. It answers a report
	that Studio posts by saving it as `build/reports/<kind>-<runId>.json` and printing the judgment
	of its claims, and serving goes on after every report. When another session holds the receiver's
	port, serving goes on without it.

	Lute 1.0.0 cannot stop a child process, so when one tool stops, the others keep running until
	the user presses Ctrl+C, which reaches every process of the terminal.

	Every operation here yields.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Endpoints = require("../project/Endpoints")
local Files     = require("../system/Files")
local Judgments = require("./Judgments")
local Paths     = require("../project/Paths")
local Receivers = require("../system/Receivers")
local Reports   = require("../project/Reports")
local Runs      = require("../project/Runs")
local task      = require("@std/task")
local Tools     = require("../system/Tools")
local Types     = require("../Types")
local Variants  = require("../project/Variants")


-- Module ------------------------------------------------------------------------------------------

local Places = {}


-- Types -------------------------------------------------------------------------------------------

--[=[
	What the tools of one serving session share.

	@field pendingCount the tools that have not stopped yet
	@field waiting      the thread that waits for every tool to stop, nil until it begins to wait
]=]
type Session = {
	pendingCount: number,
	waiting:      thread?,
}


--- One tool to start: a darklua watcher on a run, or the rojo server of a project.
type Launch =
	| {
		read kind:             "Watch",
		read run:              Variants.Run,
		read changeByVariable: Tools.EnvironmentChanges,
	}
	| { read kind: "Serve", read project: string }


--[=[
	What a serving session starts for one variant.

	@field variant  the variant that Studio syncs
	@field project  the Rojo project that its server serves
	@field launches the watcher of each run of the variant, then its server
]=]
type Plan = {
	read variant:  Variants.Variant,
	read project:  string,
	read launches: { read Launch },
}


-- Constants ---------------------------------------------------------------------------------------

--- The statuses with which the receiver answers.
const OK_STATUS                 = 200
const BAD_REQUEST_STATUS        = 400
const NOT_FOUND_STATUS          = 404
const METHOD_NOT_ALLOWED_STATUS = 405


--- The options that the harness is given: none, so that it takes its own defaults.
const NO_OPTIONS = "{}"


-- Private -----------------------------------------------------------------------------------------

local function servedWordList(): string
	local variantByName     = Variants.VARIANT_BY_NAME
	local words: { string } = {}
	for _, name in Variants.DEFAULT_ORDER do
		local variant = variantByName[name]
		if not variant.isServed then
			continue
		end

		table.insert(words, variant.word)
	end

	return table.concat(words, ", ")
end


local function confirmServed(names: { read Variants.Name }): Types.Result<nil>
	local variantByName                        = Variants.VARIANT_BY_NAME
	local seenNames: { [Variants.Name]: true } = {}
	for _, name in names do
		local variant = variantByName[name]
		if not variant.isServed then
			local requirement = `variant to serve must be one of {servedWordList()}`
			return { ok = false, error = `{requirement}, got "{variant.word}"` }
		end

		if seenNames[name] then
			local requirement = "variants to serve must be distinct"
			return { ok = false, error = `{requirement}, got "{variant.word}" twice` }
		end

		seenNames[name] = true
	end

	return { ok = true, value = nil }
end


local function prepareVariant(variant: Variants.Variant, version: string?): Types.Result<nil>
	local removed = Files.remove(variant.output)
	if not removed.ok then
		return removed
	end

	return Runs.rewrite(variant, version)
end


local function launchesOf(variant: Variants.Variant, project: string, version: string?): { Launch }
	local launches: { Launch } = {}
	for _, run in variant.runs do
		local watchLaunch: Launch = {
			kind             = "Watch",
			run              = run,
			changeByVariable = Variants.environmentChangesOf(run, version),
		}
		table.insert(launches, watchLaunch)
	end

	local serveLaunch: Launch = { kind = "Serve", project = project }
	table.insert(launches, serveLaunch)

	return launches
end


--[=[
	Returns what to start for each of `variants` that has a Rojo project to serve.

	Every tool of the session is listed here and nowhere else, so the plans are also how the tools
	are counted.

	@param  variants the variants to serve
	@param  version  the package version, nil when no run of `variants` is given it
	@return the plans, in the order of `variants`
	@error  when a run of `variants` is given the package version and `version` is nil or empty
]=]
local function plansOf(variants: { read Variants.Variant }, version: string?): { read Plan }
	local plans: { Plan } = {}
	for _, variant in variants do
		local project = variant.rojoProject
		if project == nil then
			continue
		end

		table.insert(plans, {
			variant  = variant,
			project  = project,
			launches = launchesOf(variant, project, version),
		})
	end

	return plans
end


local function toolCountOf(plans: { read Plan }): number
	local toolCount = 0
	for _, plan in plans do
		toolCount += #plan.launches
	end

	return toolCount
end


-- Lute 1.0.0 has no way to wait for several threads, so `waitForStops` suspends the thread that
-- serves, and the last tool to stop wakes it through `notifyStop`.
local function waitForStops(session: Session): ()
	-- Tools that all stopped while they were starting leave nothing to wake this thread.
	if session.pendingCount == 0 then
		return
	end

	session.waiting = coroutine.running()
	coroutine.yield()
end


--[=[
	Notifies the user, and the waiting thread when no tool is left, that a tool stopped.

	Every stop is printed, and the last one also wakes the thread that `waitForStops` suspended.

	@param session the session that the tool belongs to
	@param clause  the clause naming the tool and why it stopped
]=]
local function notifyStop(session: Session, clause: string): ()
	session.pendingCount -= 1
	if session.pendingCount > 0 then
		print(`a tool stopped; Lute cannot stop the others, so press Ctrl+C to end them: {clause}`)
		return
	end

	print(clause)

	-- When every tool stopped while starting, the waiting thread has not begun to wait.
	local waiting = session.waiting
	if waiting == nil then
		return
	end

	task.spawn(waiting)
end


local function watchRun(
	run:              Variants.Run,
	changeByVariable: Tools.EnvironmentChanges,
	session:          Session
): ()
	local stopped = Tools.watch(run.input, run.output, run.config, changeByVariable)
	notifyStop(session, stopped.error)
end


local function serveProject(project: string, session: Session): ()
	local stopped = Tools.serve(project)
	notifyStop(session, stopped.error)
end


local function startTool(launch: Launch, session: Session): ()
	if launch.kind == "Watch" then
		task.spawn(watchRun, launch.run, launch.changeByVariable, session)
	elseif launch.kind == "Serve" then
		task.spawn(serveProject, launch.project, session)
	else
		local _: never = launch
	end
end


local function startTools(plans: { read Plan }, session: Session): ()
	for _, plan in plans do
		for _, launch in plan.launches do
			startTool(launch, session)
		end

		local variant  = plan.variant
		local runCount = #variant.runs
		local noun     = if runCount == 1 then "run" else "runs"
		print(`variant {variant.word} started: {runCount} {noun} watched, {plan.project} served`)
	end
end


local function receiveReport(request: Receivers.Request): Receivers.Reply
	if request.method ~= "POST" then
		return { status = METHOD_NOT_ALLOWED_STATUS, body = "a report must be sent with POST" }
	end

	local parsed = Reports.parse(request.body, "received report")
	if not parsed.ok then
		print(`could not accept a report; replying {BAD_REQUEST_STATUS}: {parsed.error}`)
		return { status = BAD_REQUEST_STATUS, body = parsed.error }
	end

	local report = parsed.value
	local path   = `{Paths.OUTPUT.reports}/{report.kind}-{report.runId}.json`

	local written = Files.write(path, request.body)
	if not written.ok then
		print(`could not save a report; it is not judged: {written.error}`)
		return { status = Receivers.INTERNAL_ERROR_STATUS, body = written.error }
	end

	print(`report received: saved to {path}`)

	local judged = Judgments.give(path)
	if not judged.ok then
		print(judged.error)
		return { status = OK_STATUS, body = judged.error }
	end

	return { status = OK_STATUS, body = judged.value }
end


local function answerRequest(request: Receivers.Request): Receivers.Reply
	if request.route == Endpoints.ROUTE.ping then
		return { status = OK_STATUS, body = "pong" }
	elseif request.route == Endpoints.ROUTE.options then
		return { status = OK_STATUS, body = NO_OPTIONS }
	elseif request.route == Endpoints.ROUTE.report then
		return receiveReport(request)
	end

	return { status = NOT_FOUND_STATUS, body = `no route {request.route}` }
end


local function startReceiver(): Receivers.Receiver?
	local address  = Endpoints.ADDRESS
	local listened = Receivers.listen(address.host, address.port, answerRequest)
	if not listened.ok then
		local consequence = "reports will not reach this terminal"
		print(`could not start the receiver; {consequence}: {listened.error}`)
		return nil
	end

	local receiver = listened.value
	print(`receiver started: listening on {receiver.host}:{receiver.port}`)

	return receiver
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Serves each of the variants `names` until the user stops it with Ctrl+C.

	The call returns only when every tool has stopped, which is always a failure.

	@param  names the variants to serve: each named once, and each one that Studio syncs
	@return why serving ended: a refused variant, a failed first rewrite, or that every tool stopped
	@error  when `names` is empty
]=]
function Places.serve(names: { read Variants.Name }): Types.Result<never>
	if #names == 0 then
		error("names must not be empty, got none", 2)
	end

	local confirmed = confirmServed(names)
	if not confirmed.ok then
		return confirmed
	end

	local variants = Variants.variantsOf(names)

	local read = Runs.readNeededVersion(variants)
	if not read.ok then
		return read
	end

	local version = read.value
	for _, variant in variants do
		local prepared = prepareVariant(variant, version)
		if not prepared.ok then
			return prepared
		end
	end

	local plans = plansOf(variants, version)

	local session: Session = {
		pendingCount = toolCountOf(plans),
		waiting      = nil,
	}

	local receiver = startReceiver()

	startTools(plans, session)
	waitForStops(session)

	if receiver ~= nil then
		receiver.close()
	end

	return { ok = false, error = "every tool has stopped" }
end


return table.freeze(Places)
