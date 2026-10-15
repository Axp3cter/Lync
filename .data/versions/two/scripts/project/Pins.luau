--!strict

--[=[
	Pins

	Keeps a downloaded file true to its pin.

	A pin is a JSON object.

	Its `"url"` is the secure address that a file is downloaded from.

	Its `"sha256"` is the digest of the file, as lowercase hexadecimal digits.

	Its `"tag"` names a release, is optional, and is for people: it is not read.

	Every operation here yields.

	A failure outside the scripts, such as a pin that cannot be read or a file that does not match
	its pin, comes back as a Result whose clause names the file.

	A mistake by the caller throws.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Digests = require("../system/Digests")
local Files   = require("../system/Files")
local json    = require("@std/json")
local Types   = require("../Types")
local Urls    = require("../system/Urls")


-- Module ------------------------------------------------------------------------------------------

local Pins = {}


-- Types -------------------------------------------------------------------------------------------

--[=[
	What a pin holds.

	@field url    the secure address that the file is downloaded from
	@field sha256 the digest of the file, as lowercase hexadecimal digits
]=]
type Pin = {
	read url:    string,
	read sha256: string,
}


-- Constants ---------------------------------------------------------------------------------------

--- Captures the cause in the error that `json.deserialize` throws for text that is not JSON.
const JSON_FAILURE_PATTERN = "JSON error %- (.+)$"


-- Private -----------------------------------------------------------------------------------------

--[=[
	Reduces an error thrown by `json.deserialize` to the cause that it gave.

	@param  thrown the value that a failed `pcall` caught
	@return that cause, or the whole text of `thrown` when it is not a JSON error
]=]
local function causeOf(thrown: unknown): string
	local message = tostring(thrown)
	local cause   = string.match(message, JSON_FAILURE_PATTERN)
	if cause == nil then
		return message
	end

	return cause
end


local function toText(value: unknown): string?
	if typeof(value) ~= "string" then
		return nil
	end

	return value
end


--[=[
	Reads and checks the pin file `pinPath`.

	@param  pinPath the pin file to read
	@return the pin, or why the file could not be read or is not a usable pin
]=]
local function readPin(pinPath: string): Types.Result<Pin>
	local read = Files.read(pinPath)
	if not read.ok then
		return read
	end

	local ok, result = pcall(json.deserialize, read.value)
	if not ok then
		return { ok = false, error = `"{pinPath}" is not valid JSON: {causeOf(result)}` }
	end

	local object = json.asObject(result)
	if object == nil then
		return { ok = false, error = `"{pinPath}" must hold a JSON object` }
	end

	local url = toText(object.url)
	if url == nil then
		return { ok = false, error = `"{pinPath}" must hold a string "url"` }
	end

	if not Urls.isHttps(url) then
		return { ok = false, error = `"{pinPath}" url must begin with "https://", got "{url}"` }
	end

	local sha256 = toText(object.sha256)
	if sha256 == nil then
		return { ok = false, error = `"{pinPath}" must hold a string "sha256"` }
	end

	if not Digests.isSha256(sha256) then
		local requirement = `"{pinPath}" sha256 must be a SHA-256 digest in lowercase hexadecimal`
		return { ok = false, error = `{requirement}, got "{sha256}"` }
	end

	local pin = { url = url, sha256 = sha256 }

	return { ok = true, value = pin }
end


--[=[
	Confirms that the digest of `text` is the one that `pin` holds.

	@param  subject what `text` came from, which a failure names
	@param  pinPath the pin file that `pin` was read from, which a failure names
	@param  pin     the pin that `text` must match
	@param  text    the bytes to check
	@return a success, or a failure that gives the digest of `text` and the one in `pin`
]=]
local function confirmDigest(
	subject: string,
	pinPath: string,
	pin:     Pin,
	text:    string
): Types.Result<nil>
	local digest = Digests.sha256Of(text)
	if digest ~= pin.sha256 then
		local cause = `its SHA-256 is {digest}, not {pin.sha256}`
		return { ok = false, error = `"{subject}" does not match "{pinPath}": {cause}` }
	end

	return { ok = true, value = nil }
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Fetches the file that the pin `pinPath` names.

	The download is written to `filePath` only when its digest is the one in the pin, so a download
	that does not match changes nothing on disk.

	@param  pinPath  the pin file that names the address and the digest
	@param  filePath where the verified download is written
	@return a success once the file is written, or why it was not
	@error  when `pinPath` or `filePath` is not relative names joined by "/"
]=]
function Pins.fetch(pinPath: string, filePath: string): Types.Result<nil>
	if not Files.isRelativePath(pinPath) then
		error(`pinPath must be relative names joined by "/", got "{pinPath}"`, 2)
	end

	if not Files.isRelativePath(filePath) then
		error(`filePath must be relative names joined by "/", got "{filePath}"`, 2)
	end

	local pinRead = readPin(pinPath)
	if not pinRead.ok then
		return pinRead
	end

	local pin     = pinRead.value
	local urlRead = Urls.read(pin.url)
	if not urlRead.ok then
		return urlRead
	end

	local body      = urlRead.value
	local confirmed = confirmDigest(pin.url, pinPath, pin, body)
	if not confirmed.ok then
		return confirmed
	end

	return Files.write(filePath, body)
end


--[=[
	Verifies the file `filePath` against the pin `pinPath` by reading it and hashing it.

	A failure names the file and says what is wrong with it.

	@param  pinPath  the pin file that names the digest
	@param  filePath the file that must match
	@return a success when the file is there and matches, or why it is missing or does not match
	@error  when `pinPath` or `filePath` is not relative names joined by "/"
]=]
function Pins.verify(pinPath: string, filePath: string): Types.Result<nil>
	if not Files.isRelativePath(pinPath) then
		error(`pinPath must be relative names joined by "/", got "{pinPath}"`, 2)
	end

	if not Files.isRelativePath(filePath) then
		error(`filePath must be relative names joined by "/", got "{filePath}"`, 2)
	end

	local pinRead = readPin(pinPath)
	if not pinRead.ok then
		return pinRead
	end

	local fileRead = Files.read(filePath)
	if not fileRead.ok then
		return fileRead
	end

	return confirmDigest(filePath, pinPath, pinRead.value, fileRead.value)
end


return table.freeze(Pins)
