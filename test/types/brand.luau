--!strict

--[=[
	brand

	Typing proof (review-m1 m4): a record with a field named `_value` is inferred as a record, not
	taken for a codec, since codecs are branded with `"[Lync] value"`. The reveal fails on purpose;
	the expected output records the inferred type.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Lync = require("../../src")
local Types = require("../../src/types")

-- Main --------------------------------------------------------------------------------------------

local t = Lync.types

local schema = Lync.schema("brand", {
	tagged = Lync.event({ from = "client", data = { _value = t.int(0, 9), name = t.string(8) } }),
})

local client = (nil :: any) :: Types.ClientView<typeof(schema)>
client.tagged:fire({ _value = 1, name = "a" })

local record: Types.Infer<typeof({ _value = t.int(0, 9), name = t.string(8) })> = nil :: any
local _reveal: "REVEAL record" = record
