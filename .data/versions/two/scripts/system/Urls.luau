--!strict

--[=[
	Urls

	Reads what a URL serves, for the repository scripts.

	The scripts reach the network only through this module.

	Every operation here yields, except isHttps.

	A failure outside the scripts, such as a server that cannot be reached or one that refuses the
	request, comes back as a Result.

	A mistake by the caller throws.

	Lute follows redirects by itself, up to 20 of them, wherever they lead.

	Lute gives up on a request after five minutes.
]=]


-- Imports -----------------------------------------------------------------------------------------

local net   = require("@std/net")
local Types = require("../Types")


-- Module ------------------------------------------------------------------------------------------

local Urls = {}


-- Constants ---------------------------------------------------------------------------------------

--- Matches an address that begins with "https://" and holds something after it.
const HTTPS_PATTERN = "^https://."


--[=[
	Captures the cause in the error that `net.request` throws when no response arrives.

	The message begins "network request failed: ", and the cause is the rest of it.
]=]
const NETWORK_FAILURE_PATTERN = "^network request failed: (.+)$"


-- Private -----------------------------------------------------------------------------------------

--[=[
	Reduces an error thrown by `net.request` to the cause that Lute gave.

	@param  thrown the value that a failed `pcall` caught
	@return that cause, or the whole text of `thrown` when `net.request` did not throw it
]=]
local function causeOf(thrown: unknown): string
	local message = tostring(thrown)
	local cause   = string.match(message, NETWORK_FAILURE_PATTERN)
	if cause == nil then
		return message
	end

	return cause
end


local function isHttps(url: string): boolean
	return string.find(url, HTTPS_PATTERN) ~= nil
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Tells whether `url` is an address that `read` accepts.

	A request starts on a secure address, which begins with "https://".

	@param  url the text to test
	@return true when `url` begins with "https://" and holds something after it
]=]
function Urls.isHttps(url: string): boolean
	return isHttps(url)
end


--[=[
	Reads the body that `url` serves.

	@param  url the secure address to read
	@return the body, byte for byte, or why it could not be read
	@error  when `url` is not an address that begins with "https://"
]=]
function Urls.read(url: string): Types.Result<string>
	if not isHttps(url) then
		error(`url must begin with "https://", got "{url}"`, 2)
	end

	local clause = `"{url}" could not be read`
	-- The checker makes pcall require the optional parameter of net.request, so nil is passed.
	local ok, result = pcall(net.request, url, nil)
	if not ok then
		return { ok = false, error = `{clause}: {causeOf(result)}` }
	end

	local response = result
	if not response.ok then
		return { ok = false, error = `{clause}: the server answered {response.status}` }
	end

	return { ok = true, value = response.body }
end


return table.freeze(Urls)
