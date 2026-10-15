--!strict

--[=[
	fail.spec

	Message positions and grammar (v5.md §7.1), the caller walk, and value rendering
	(diagnostics §3.2).
]=]

-- Imports -----------------------------------------------------------------------------------------

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local Check = require("../support/check")
local Codes = require("../../src/diag/codes")
local Fail = require("../../src/diag/fail")

-- Constants ---------------------------------------------------------------------------------------

const SOURCE = debug.info(1, "s")

const MESSAGE_PATTERN = "^(.-):(%d+): (%[Lync%] .*)$"

-- Lync loaded as a Roblox package, beside sibling packages whose names start with its own.
const ROBLOX_FAIL = "ReplicatedStorage.Packages.Lync.diag.fail"
const ROBLOX_ROWS = "ReplicatedStorage.Packages.Lync.codec.rows"
const ROBLOX_SIBLING = "ReplicatedStorage.Packages.LyncNet.client"

-- Private -----------------------------------------------------------------------------------------

local function at(line: number): string
	return `{SOURCE}:{line}`
end

local function messageOf(fn: () -> ()): string
	local ok, message = pcall(fn)
	Check.expect(not ok, "the call must raise")
	Check.expect(typeof(message) == "string", "the raised value must be a string")

	return message
end

-- Loads `fail.luau` as the module `ROBLOX_FAIL`, so its Lync prefix is a Roblox one.
local function robloxFail(): typeof(Fail)
	local environment = {
		require = function(_path: string): any
			return Codes
		end,
		assert = assert,
		buffer = buffer,
		debug = debug,
		error = error,
		math = math,
		next = next,
		string = string,
		table = table,
		tostring = tostring,
		typeof = typeof,
		utf8 = utf8,
	}
	local source = fs.readFile("src/diag/fail.luau")
	local chunk = luau.load(source, { debugName = `={ROBLOX_FAIL}`, environment = environment })

	return chunk()
end

-- Loads `text` as the module `name` and returns what it returns.
local function moduleAs(name: string, text: string, environment: { [string]: any }): any
	return luau.load(text, { debugName = `={name}`, environment = environment })()
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["valueRefused: a caller error is positioned at the caller's line"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Fail.caller("valueRefused", "arena.buy:invoke", 'be one of "sword", "shield"', "axe")
		end, { code = "valueRefused", at = at(line + 2), subject = "arena.buy:invoke" })
	end,

	["the caller walk skips C frames"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			local ok, message = pcall(Fail.caller, "valueRefused", "a.chat:fire data", "be text")
			Check.expect(not ok, "pcall must fail")
			error(message, 0)
		end, { code = "valueRefused", at = at(line + 2), subject = "a.chat:fire", path = "data" })
	end,

	["internal: an invariant broken inside Lync, positioned at the caller"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Fail.caller("internal", "t.rotation encode", "reach a fixed point", nil, "report a bug")
		end, { code = "internal", at = at(line + 2), subject = "t.rotation" })
	end,

	["the caller walk skips Lync's modules but not a sibling package named like it"] = function()
		local fail = robloxFail()
		local rows = moduleAs(
			ROBLOX_ROWS,
			[[
			return function()
				return Fail.caller("valueRefused", "arena.chat:fire data", "be a string", 5)
			end
		]],
			{ Fail = fail }
		)
		local client = moduleAs(
			ROBLOX_SIBLING,
			[[
			return function()
				encode()
			end
		]],
			{ encode = rows }
		)

		Check.expectThrow(client, {
			code = "valueRefused",
			at = `{ROBLOX_SIBLING}:2`,
			subject = "arena.chat:fire",
			path = "data",
		})
	end,

	["a declaration error is positioned where it was recorded"] = function()
		Check.expectThrow(function()
			Fail.declaration(
				"intBounds",
				{ line = 7, source = "Net.schema" },
				"t.int max",
				"be above min"
			)
		end, { code = "intBounds", at = "Net.schema:7", subject = "t.int" })
	end,

	["messages follow the grammar, got and fix included only when given"] = function()
		local bare = messageOf(function()
			Fail.declaration(
				"missingOption",
				{ line = 3, source = "S" },
				"arena.chat",
				"have from",
				Fail.NONE
			)
		end)
		local missing = messageOf(function()
			Fail.caller("valueRefused", "arena.x:fire data.v.x", "be a boolean", nil)
		end)
		local full = messageOf(function()
			Fail.declaration(
				"numberStepIsInt",
				{ line = 3, source = "S" },
				"t.number step",
				"not be 1",
				1,
				"use t.int"
			)
		end)

		Check.expectEqual(bare, "S:3: [Lync] missingOption: arena.chat must have from")
		Check.expectEqual(
			string.match(missing, ": %[Lync%] .*$"),
			": [Lync] valueRefused: arena.x:fire data.v.x must be a boolean, got nil"
		)
		Check.expectEqual(
			full,
			"S:3: [Lync] numberStepIsInt: t.number step must not be 1, got 1; use t.int"
		)
	end,

	["messages are one line of at most 200 bytes after the position"] = function()
		local subject = `arena.{string.rep("x", 300)}`
		local message = messageOf(function()
			Fail.declaration("paramRange", { line = 1, source = "S" }, subject, "be short", "a\nb")
		end)
		local source, line, body = string.match(message, MESSAGE_PATTERN)

		Check.expectEqual(source, "S")
		Check.expectEqual(line, "1")
		Check.expect(body ~= nil and #body <= 200, "the body must be at most 200 bytes")
		Check.expect(string.find(message, "\n", 1, true) == nil, "the message must be one line")
	end,

	["show: strings are quoted, escaped and cut at 40 bytes"] = function()
		Check.expectEqual(Fail.show("gg"), '"gg"')
		Check.expectEqual(Fail.show('a"b\\c\n\t\r'), '"a\\"b\\\\c\\n\\t\\r"')
		Check.expectEqual(Fail.show("\0\127"), '"\\x00\\x7F"')
		Check.expectEqual(Fail.show("é"), '"é"')
		Check.expectEqual(Fail.show("\xff"), '"\\xFF"')
		Check.expectEqual(Fail.show(string.rep("a", 45)), `"{string.rep("a", 40)}"…(+5 bytes)`)
	end,

	["show: a cut never splits a UTF-8 sequence"] = function()
		local text = `{string.rep("a", 39)}é`

		Check.expectEqual(Fail.show(`{text}z`), `"{string.rep("a", 39)}"…(+3 bytes)`)
	end,

	["show: numbers"] = function()
		Check.expectEqual(Fail.show(42), "42")
		Check.expectEqual(Fail.show(-2 ^ 52), "-4503599627370496")
		Check.expectEqual(Fail.show(0.1), "0.1")
		Check.expectEqual(Fail.show(0.35), "0.35")
		Check.expectEqual(Fail.show(0 / 0), "nan")
		Check.expectEqual(Fail.show(math.huge), "inf")
		Check.expectEqual(Fail.show(-math.huge), "-inf")
		Check.expectEqual(Fail.show(-0), "-0")
		Check.expectEqual(Fail.show(2 ^ 70), "1.1805916207174113e+21")
	end,

	["show: booleans, nil, buffers and tables"] = function()
		Check.expectEqual(Fail.show(true), "true")
		Check.expectEqual(Fail.show(nil), "nil")
		Check.expectEqual(Fail.show(buffer.create(12)), "buffer(12 bytes)")
		Check.expectEqual(Fail.show({ 1, 2, x = 3 }), "table (3 keys)")
	end,

	["show: Roblox values, never an instance's name"] = function()
		local part = Instance.new("Part")
		part.Name = "PlayerChosenName"

		Check.expectEqual(Fail.show(Vector3.new(1, 2.5, -3)), "Vector3(1, 2.5, -3)")
		Check.expectEqual(Fail.show(CFrame.new(1, 2, 3)), "CFrame(1, 2, 3)")
		Check.expectEqual(Fail.show(Color3.new(1, 0, 0)), "Color3(1, 0, 0)")
		Check.expectEqual(Fail.show(part), "Instance(Part)")
		Check.expectEqual(Fail.show(print), "function")
	end,
}
