--!strict

--[=[
	Digests

	Computes the digests of text for the repository scripts, and knows what a digest looks like.

	A digest is a fixed-size fingerprint of text, so two texts with the same digest are the same
	text for the scripts' purposes.

	Nothing here yields, because the computation reaches nothing outside the process.
]=]


-- Imports -----------------------------------------------------------------------------------------

local crypto = require("@lute/crypto")


-- Module ------------------------------------------------------------------------------------------

local Digests = {}


-- Constants ---------------------------------------------------------------------------------------

--- Matches text made only of digits and the letters "a" to "f" in lowercase.
const LOWERCASE_HEX_PATTERN = "^[0-9a-f]+$"


--- The number of hexadecimal digits in a SHA-256 digest.
const SHA256_LENGTH = 64


-- Private -----------------------------------------------------------------------------------------

local function hexOf(digest: buffer): string
	local byteCount = buffer.len(digest)
	local digits    = table.create(byteCount) :: { string }
	for i = 1, byteCount do
		local byte = buffer.readu8(digest, i - 1)
		digits[i]  = string.format("%02x", byte)
	end

	return table.concat(digits)
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Tells whether `text` is written as `sha256Of` writes a digest.

	@param  text the text to test, such as a digest read from a file
	@return true when `text` is 64 lowercase hexadecimal digits
]=]
function Digests.isSha256(text: string): boolean
	if #text ~= SHA256_LENGTH then
		return false
	end

	return string.find(text, LOWERCASE_HEX_PATTERN) ~= nil
end


--[=[
	Returns the SHA-256 digest of `text`.

	@param  text the bytes to fingerprint
	@return the digest as 64 lowercase hexadecimal digits
]=]
function Digests.sha256Of(text: string): string
	local digest = crypto.digest(crypto.hash.sha256, text)
	return hexOf(digest)
end


return table.freeze(Digests)
