--!strict

--[=[
	Receivers

	Listens for HTTP requests on the local machine, for the repository scripts, and answers each one
	with the reply that a handler gives.

	The scripts reach the network as a server only through this module.

	`listen` returns at once. The handler then runs for each request as it arrives, in a thread of
	its own, so it may yield.

	A handler that throws is answered with status 500 and reported through print, so one bad request
	never stops the receiver.

	A failure outside the scripts, such as a port that another program holds, comes back as a
	Result. A mistake by the caller throws.
]=]


-- Imports -----------------------------------------------------------------------------------------

local net   = require("@lute/net")
local Types = require("../Types")


-- Module ------------------------------------------------------------------------------------------

local Receivers = {}


-- Types -------------------------------------------------------------------------------------------

--[=[
	One HTTP request, as a handler sees it.

	@field method the HTTP method, such as "POST"
	@field route  the path that was asked for, without its query, such as "/report"
	@field body   the bytes of the request body, empty when there is none
]=]
export type Request = {
	read method: string,
	read route:  string,
	read body:   string,
}


--[=[
	What a handler answers with.

	@field status the HTTP status code
	@field body   the text of the reply body
]=]
export type Reply = {
	read status: number,
	read body:   string,
}


--- Answers one request.
export type Handler = (request: Request) -> Reply


--[=[
	A receiver that is listening.

	@field host  the address that it listens on
	@field port  the port that it listens on
	@field close stops it, so that it answers no more requests and the process may end
]=]
export type Receiver = {
	read host:  string,
	read port:  number,
	read close: () -> (),
}


-- Constants ---------------------------------------------------------------------------------------

--- The status that answers a request whose handler threw.
const INTERNAL_ERROR_STATUS = 500


--- The highest port number.
const MAX_PORT = 65_535


-- Private -----------------------------------------------------------------------------------------

local function answer(handler: Handler, received: net.ReceivedRequest): net.ServerResponse
	local request: Request = {
		method = received.method,
		route  = received.path,
		body   = received.body,
	}

	local ok, reply = pcall(handler, request)
	if not ok then
		local cause   = tostring(reply)
		local subject = `{request.method} {request.route}`
		print(`could not answer {subject}; replying {INTERNAL_ERROR_STATUS}: {cause}`)
		return { status = INTERNAL_ERROR_STATUS, body = cause }
	end

	return { status = reply.status, body = reply.body }
end


-- Public ------------------------------------------------------------------------------------------

--- The status that answers a request whose handler threw, which a handler may use for its own.
Receivers.INTERNAL_ERROR_STATUS = INTERNAL_ERROR_STATUS


--[=[
	Starts listening on `host` and `port`, answering each request with `handler`.

	@param  host    the address to listen on, such as "127.0.0.1"
	@param  port    the port to listen on, from 0 to 65535, where 0 asks for any free port
	@param  handler what answers a request
	@return the receiver, or why it could not listen
	@error  when `host` is empty, or `port` is not a whole number from 0 to 65535
]=]
function Receivers.listen(host: string, port: number, handler: Handler): Types.Result<Receiver>
	if host == "" then
		error('host must not be empty, got ""', 2)
	end

	if
		not math.isfinite(port)
		or math.floor(port) ~= port
		or port < 0
		or port > MAX_PORT
	then
		error(`port must be a whole number from 0 to {MAX_PORT}, got {port}`, 2)
	end

	local configuration: net.Configuration = {
		hostname = host,
		port     = port,
		handler  = function(received: net.ReceivedRequest, _: net.Server): net.ServerResponse
			return answer(handler, received)
		end,
	}

	local ok, result = pcall(net.server.serve, configuration)
	if not ok then
		return { ok = false, error = `could not listen on {host}:{port}: {tostring(result)}` }
	end

	local receiver: Receiver = {
		host  = result.hostname,
		port  = result.port,
		close = result.close,
	}

	return { ok = true, value = receiver }
end


return table.freeze(Receivers)
