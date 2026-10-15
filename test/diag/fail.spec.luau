--!strict

--[=[
	fail.spec

	Message positions and grammar (v5.md §7.1), the caller walk, and value rendering
	(diagnostics §3.2).
]=]

-- Imports -----------------------------------------------------------------------------------------

local Check = require("../support/check")
local Fail = require("../../src/diag/fail")

-- Constants ---------------------------------------------------------------------------------------

const SOURCE = debug.info(1, "s")

const MESSAGE_PATTERN = "^(.-):(%d+): (%[Lync%] .*)$"

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
		Check.expectThrow(
			function()
				local ok, message =
					pcall(Fail.caller, "valueRefused", "arena.chat:fire data", "be a string")
				Check.expect(not ok, "pcall must fail")
				error(message, 0)
			end,
			{ code = "valueRefused", at = at(line + 2), subject = "arena.chat:fire", path = "data" }
		)
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
			Fail.declaration("missingOption", { line = 3, source = "S" }, "arena.chat", "have from")
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
		Check.expectEqual(Fail.show(0.1), "0.10000000000000001")
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
