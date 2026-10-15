--!strict
local L = require("./lib")
local Single = L.enum("a")
local Variadic = L.enum("a", "b", "c")
local List = L.enumList({ "a", "b", "c" })
local Set = L.enumSet({ a = true, b = true, c = true })
local Mixed = L.enum("a", 1) -- mixed: what happens
return {
	Single = Single,
	Variadic = Variadic,
	List = List,
	Set = Set,
	Mixed = Mixed,
	Inline = { mode = L.enum("x", "y") }, -- enum written inline inside a schema table
	InlineList = { mode = L.enumList({ "x", "y" }) },
}
