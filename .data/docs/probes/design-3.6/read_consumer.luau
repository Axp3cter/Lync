--!strict
local M = require("./read_module")
local function f(a: M.A): number return a.x end
local y: string = f({ x = 1 })
return f
