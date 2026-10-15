--!strict

--[=[
	Deliveries

	Sends a finished report out of Studio, and asks the receiver in the terminal how to run.

	A report goes out two ways. Its summary is always printed to Output, for a person to read. And
	when HTTP is on, the report is posted to the receiver in the terminal. Only when the post fails,
	or HTTP is off, are the report's lines printed too (H-70), so that `judge --from-log` can read
	them from the log; when the post succeeded they are not printed (H-128), since they run to
	hundreds of lines.

	The last report is kept as text, for a driver to read with `take` in a driven run.

	At the start of a run, `loadOptions` asks whether the receiver answers and reads the options it
	serves, which a run takes over its defaults. `ping` is the question alone.

	Everything that reaches the engine comes through the ports given to each call, so the module
	touches no service. The operations that send or ask yield.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Endpoints    = require("./Endpoints")
local Printouts    = require("./Printouts")
local Properties   = require("./Properties")
local RandomSource = require("./RandomSource")
local Reports      = require("./Reports")
local Types        = require("./Types")
local Values       = require("./Values")


-- Module ------------------------------------------------------------------------------------------

local Deliveries = {}


-- Types -------------------------------------------------------------------------------------------

type Method =
	| "GET"
	| "POST"


--[=[
	How the receiver answered a request.

	@field status the HTTP status code
	@field body   the text of the answer
]=]
export type Reply = {
	read status: number,
	read body:   string,
}


--[=[
	How the module reaches the engine.

	@field isHttpEnabled tells whether HTTP requests are allowed
	@field request       sends one request and returns the answer, or why there was none; yields
	@field decode        reads JSON text into a value, and raises when the text is not JSON
	@field print         writes one line to Output
	@field warn          writes one line to Output as a warning
]=]
export type Ports = {
	read isHttpEnabled: () -> boolean,
	read request:       (method: Method, url: string, body: string?) -> Types.Result<Reply>,
	read decode:        (text: string) -> unknown,
	read print:         (line: string) -> (),
	read warn:          (line: string) -> (),
}


--[=[
	The options the receiver serves, each given only when the user set it.

	@field filter  narrows the run to the tests whose ids hold this text
	@field seed    the seed of the run, a whole number from 0 to 4294967295
	@field profile how many cases a property runs
	@field tape    one tape to replay alone in the properties the filter keeps
	@field clients how many clients to wait for, from 0 to 8
]=]
export type RunOptions = {
	read filter:  string?,
	read seed:    number?,
	read profile: Properties.Profile?,
	read tape:    { number }?,
	read clients: number?,
}


--- How a report left: posted to the receiver as well as printed, or printed alone.
export type Delivery =
	| "Posted"
	| "Printed"


-- Constants ---------------------------------------------------------------------------------------

--- The most clients a run waits for, which a multi-client session allows.
const MAX_CLIENTS = 8


--- The lowest status code that means the receiver took the report.
const FIRST_SUCCESS_STATUS = 200


--- The first status code above those that mean success.
const FIRST_FAILURE_STATUS = 300


--- What a posted report is, as the header that says so names it.
const JSON_CONTENT_TYPE = "application/json"


-- State -------------------------------------------------------------------------------------------

--- The text of the last report that `send` was given, for a driver to take.
local lastReport: string? = nil


-- Private -----------------------------------------------------------------------------------------

local function urlOf(route: string): string
	local address = Endpoints.ADDRESS

	return `http://{address.host}:{address.port}{route}`
end


local function isSuccess(reply: Reply): boolean
	return reply.status >= FIRST_SUCCESS_STATUS and reply.status < FIRST_FAILURE_STATUS
end


local function optionsOf(value: unknown): RunOptions
	local entries = Values.toEntries(value)
	if entries == nil then
		return {}
	end

	local filter  = Values.toText(entries.filter)
	local seed    = Values.toNumber(entries.seed)
	local clients = Values.toNumber(entries.clients)

	local profileWord = Values.toText(entries.profile)
	local profile     = nil
	if profileWord ~= nil then
		profile = Properties.toProfile(profileWord)
	end

	if
		seed ~= nil
		and not RandomSource.isWord(seed)
	then
		seed = nil
	end

	if
		clients ~= nil
		and (
			not math.isfinite(clients)
			or math.floor(clients) ~= clients
			or clients < 0
			or clients > MAX_CLIENTS
		)
	then
		clients = nil
	end

	return {
		filter  = filter,
		seed    = seed,
		profile = profile,
		tape    = Values.toTape(entries.tape),
		clients = clients,
	}
end


local function isAnswering(ports: Ports): boolean
	if not ports.isHttpEnabled() then
		return false
	end

	local asked = ports.request("GET", urlOf(Endpoints.ROUTE.ping), nil)
	if not asked.ok then
		return false
	end

	return isSuccess(asked.value)
end


local function printLines(ports: Ports, lines: { string }): ()
	for _, line in lines do
		ports.print(line)
	end
end


local function post(ports: Ports, json: string): Types.Result<Reply>
	if not ports.isHttpEnabled() then
		return { ok = false, error = "HttpService.HttpEnabled must be true to post, got false" }
	end

	local posted = ports.request("POST", urlOf(Endpoints.ROUTE.report), json)
	if not posted.ok then
		return posted
	end

	local reply = posted.value
	if not isSuccess(reply) then
		return { ok = false, error = `the receiver must answer with success, got {reply.status}` }
	end

	return posted
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Builds the ports of the engine from the HTTP service.

	@param  httpService the service that requests and JSON go through
	@return ports that send with `RequestAsync`, decode with `JSONDecode`, and print with the
	        engine's own `print` and `warn`
]=]
function Deliveries.enginePorts(httpService: HttpService): Ports
	local function request(method: Method, url: string, body: string?): Types.Result<Reply>
		local headers: { [string]: string | Secret }? = nil
		if body ~= nil then
			headers = { ["Content-Type"] = JSON_CONTENT_TYPE }
		end

		local ok, answer = pcall(function()
			return httpService:RequestAsync({
				Url     = url,
				Method  = method,
				Headers = headers,
				Body    = body,
			})
		end)

		if not ok then
			return { ok = false, error = `{method} {url} must be answered, got {tostring(answer)}` }
		end

		return { ok = true, value = { status = answer.StatusCode, body = answer.Body or "" } }
	end

	local function isHttpEnabled(): boolean
		return httpService.HttpEnabled
	end

	local function decode(text: string): unknown
		return httpService:JSONDecode(text)
	end

	local function printLine(line: string): ()
		print(line)
	end

	local function warnLine(line: string): ()
		warn(line)
	end

	return {
		isHttpEnabled = isHttpEnabled,
		request       = request,
		decode        = decode,
		print         = printLine,
		warn          = warnLine,
	}
end


--[=[
	Reads the options the receiver serves.

	The receiver is pinged first. One that does not answer, or answers with something that is not
	JSON, serves none; so does one that serves an option the run cannot use, such as a profile
	that does not exist.

	@param  ports how to reach the receiver
	@return the options the receiver gave; none of them when it gave none
]=]
function Deliveries.loadOptions(ports: Ports): RunOptions
	if not isAnswering(ports) then
		return {}
	end

	local asked = ports.request("GET", urlOf(Endpoints.ROUTE.options), nil)
	if not asked.ok then
		return {}
	end

	if not isSuccess(asked.value) then
		return {}
	end

	local ok, decoded = pcall(ports.decode, asked.value.body)
	if not ok then
		local action = "could not read the options of the receiver; using the defaults"
		ports.warn(`{action}: {tostring(decoded)}`)
		return {}
	end

	return optionsOf(decoded)
end


--[=[
	Asks whether the receiver in the terminal answers.

	@param  ports how to reach the receiver
	@return true when HTTP is on and the receiver answered the ping with success
]=]
function Deliveries.ping(ports: Ports): boolean
	return isAnswering(ports)
end


--[=[
	Sends a report out: its summary to Output, its text to the receiver, and its lines to Output
	only if the receiver did not take it.

	@param  report the report of a finished run
	@param  ports  how to reach Output and the receiver
	@return "Posted" when the receiver took the report, "Printed" when its lines went to Output
]=]
function Deliveries.send(report: Reports.Report, ports: Ports): Delivery
	local json = Reports.toJson(report)

	lastReport = json

	printLines(ports, Printouts.summaryOf(report))

	local posted = post(ports, json)
	if posted.ok then
		return "Posted"
	end

	printLines(ports, Printouts.linesOf(report))

	if ports.isHttpEnabled() then
		local consequence = "the report is in Output"
		ports.warn(`could not post the report to the receiver; {consequence}: {posted.error}`)
	end

	return "Printed"
end


--[=[
	Returns a function that sends each report it is given out through `ports`, as `send` does.

	@param  ports how to reach Output and the receiver
	@return the function, for a conductor to deliver its report with
]=]
function Deliveries.sender(ports: Ports): (report: Reports.Report) -> ()
	return function(report: Reports.Report): ()
		Deliveries.send(report, ports)
	end
end


--[=[
	Returns the last report that `send` was given, as the JSON text that was sent.

	@return the text, nil when no report has been sent
]=]
function Deliveries.take(): string?
	return lastReport
end


return table.freeze(Deliveries)
