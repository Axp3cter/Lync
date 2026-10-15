--!strict

--[=[
	Check

	Assertions for spec files. Each raises a string naming what differed, positioned at the
	calling test line.

	`expectThrow` compares a Lync diagnostic by its code, position, subject and path, never by its
	prose (v5.md §9).
]=]

-- Module ------------------------------------------------------------------------------------------

local Check = {}

-- Types -------------------------------------------------------------------------------------------

type Want = {
	code: string,
	at: string?,
	subject: string?,
	path: string?,
}

-- Constants ---------------------------------------------------------------------------------------

const MESSAGE_PATTERN = "^(.-):(%d+): %[Lync%] (%a+): (.*)$"

-- Private -----------------------------------------------------------------------------------------

local function hexOf(bytes: buffer): string
	local parts = table.create(buffer.len(bytes)) :: { string }
	for i = 0, buffer.len(bytes) - 1 do
		parts[i + 1] = string.format("%02x", buffer.readu8(bytes, i))
	end

	return table.concat(parts, " ")
end

local function show(value: unknown): string
	if typeof(value) == "buffer" then
		return `buffer({hexOf(value)})`
	end

	if typeof(value) == "string" then
		return string.format("%q", value)
	end

	if typeof(value) == "number" then
		return string.format("%.17g", value)
	end

	return tostring(value)
end

local function differenceOf(actual: unknown, expected: unknown, path: string): string?
	if typeof(actual) == "buffer" and typeof(expected) == "buffer" then
		if buffer.tostring(actual) == buffer.tostring(expected) then
			return nil
		end

		return `{path}: got {show(actual)}, expected {show(expected)}`
	end

	if typeof(actual) == "table" and typeof(expected) == "table" then
		for key, expectedValue in expected do
			local difference = differenceOf(actual[key], expectedValue, `{path}.{key}`)
			if difference ~= nil then
				return difference
			end
		end

		for key in actual do
			if expected[key] == nil then
				return `{path}.{key}: got {show(actual[key])}, expected nil`
			end
		end

		return nil
	end

	if actual == expected then
		return nil
	end

	local isBothNan = actual ~= actual and expected ~= expected
	if isBothNan then
		return nil
	end

	return `{path}: got {show(actual)}, expected {show(expected)}`
end

local function hasToken(text: string, token: string): boolean
	local start = 1
	while true do
		local first, last = string.find(text, token, start, true)
		if first == nil or last == nil then
			return false
		end

		local before = string.sub(text, first - 1, first - 1)
		local after = string.sub(text, last + 1, last + 1)
		local isStart = before == "" or string.find(before, "%s") ~= nil
		local isEnd = after == "" or string.find(after, "[%s,;:]") ~= nil
		if isStart and isEnd then
			return true
		end

		start = first + 1
	end
end

local function bytesFromHex(hex: string): buffer
	local digits = string.gsub(hex, "%s", "")
	local bytes = buffer.create(#digits // 2)
	for i = 0, buffer.len(bytes) - 1 do
		local pair = string.sub(digits, 2 * i + 1, 2 * i + 2)
		buffer.writeu8(bytes, i, assert(tonumber(pair, 16), "hex must hold only hex digit pairs"))
	end

	return bytes
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Fails unless `condition` holds.

	@param condition what the test requires
	@param message   what failed, reported as is
	@error when `condition` is false
]=]
function Check.expect(condition: boolean, message: string)
	if not condition then
		error(message, 2)
	end
end

--[=[
	Fails unless two values are equal: tables deeply, buffers by content, NaN equal to NaN.

	@param actual   the value the code produced
	@param expected the value the test requires
	@param message  what is compared, prefixed to the report
	@error when the values differ, naming the first differing path
]=]
function Check.expectEqual(actual: any, expected: any, message: string?)
	local difference = differenceOf(actual, expected, "value")
	if difference == nil then
		return
	end

	local prefix = if message == nil then "" else `{message}: `
	error(`{prefix}{difference}`, 2)
end

--[=[
	Fails unless `actual` holds exactly the bytes `expectedHex` names.

	@param actual      the bytes the code produced
	@param expectedHex the bytes required, as hex digit pairs; whitespace is ignored
	@error when the lengths or any byte differ, naming the first differing byte
]=]
function Check.expectBytes(actual: buffer | string, expectedHex: string)
	local actualBytes = if typeof(actual) == "string" then buffer.fromstring(actual) else actual
	local expectedBytes = bytesFromHex(expectedHex)
	local actualLength = buffer.len(actualBytes)
	local expectedLength = buffer.len(expectedBytes)
	for i = 0, math.min(actualLength, expectedLength) - 1 do
		local actualByte = buffer.readu8(actualBytes, i)
		local expectedByte = buffer.readu8(expectedBytes, i)
		if actualByte ~= expectedByte then
			local got = string.format("%02x", actualByte)
			local wanted = string.format("%02x", expectedByte)
			error(`byte {i}: got {got}, expected {wanted} (got {hexOf(actualBytes)})`, 2)
		end
	end

	if actualLength ~= expectedLength then
		error(`length: got {actualLength}, expected {expectedLength} ({hexOf(actualBytes)})`, 2)
	end
end

--[=[
	Fails unless `fn` raises a Lync diagnostic matching `want`.

	@param fn   the call expected to raise
	@param want the code, and optionally the position (`"file:line"`, matched against the end of
	            the message's position) and the subject and path, each a whole token of the text
	@error when `fn` returns, raises something else, or raises a diagnostic that differs
]=]
function Check.expectThrow(fn: () -> (), want: Want)
	local ok, message = pcall(fn)
	if ok then
		error(`expected {want.code} to be raised, but the call returned`, 2)
	end

	if typeof(message) ~= "string" then
		error(`expected a string diagnostic, got {typeof(message)}`, 2)
	end

	local source, line, code, text = string.match(message, MESSAGE_PATTERN)
	if source == nil or line == nil or code == nil or text == nil then
		error(`expected a Lync diagnostic, got {show(message)}`, 2)
	end

	if code ~= want.code then
		error(`code: got {code}, expected {want.code} in {show(message)}`, 2)
	end

	local at = want.at
	local position = `{source}:{line}`
	if at ~= nil and string.sub(position, -#at) ~= at then
		error(`position: got {position}, expected {at}`, 2)
	end

	local subject = want.subject
	if subject ~= nil and not hasToken(text, subject) then
		error(`subject {show(subject)} is not a token of {show(text)}`, 2)
	end

	local path = want.path
	if path ~= nil and not hasToken(text, path) then
		error(`path {show(path)} is not a token of {show(text)}`, 2)
	end
end

return table.freeze(Check)
