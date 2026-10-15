--!strict

--[=[
	enums

	Typing proof (v5.md §3.2, §10 item 1): a list enum widens to `string`, and a Roblox enum is
	`Codec<unknown>`. The reveals below fail on purpose; the expected output records the types.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Lync = require("../../src")

-- Main --------------------------------------------------------------------------------------------

local t = Lync.types

local _list: "REVEAL list enum" = t.enum({ "red", "blue" })
local _roblox: "REVEAL Roblox enum" = t.enum(Enum.Material)
