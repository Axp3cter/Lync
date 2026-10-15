--!strict
-- R6b: the same request definition, top level vs nested in Lync.schema(...) vs in a plain table
local Lync = require("./lync")
local t = Lync.types
local top = Lync.request({ from = "client", data = t.int(), reply = t.int(), timeout = 10 })
local inTable = { buy = Lync.request({ from = "client", data = t.int(), reply = t.int(), timeout = 10 }) }
local inSchema = Lync.schema("arena", { buy = Lync.request({ from = "client", data = t.int(), reply = t.int() }) })
local inSchemaTimeout = Lync.schema("arena", { buy = Lync.request({ from = "client", data = t.int(), reply = t.int(), timeout = 10 }) })
local evInSchema = Lync.schema("arena", { e = Lync.event({ from = "client", data = t.int(), rate = 5 }) })
return { top, inTable, inSchema, inSchemaTimeout, evInSchema }
