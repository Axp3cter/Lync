--!strict
--!optimize 2
-- Zero-byte codec. Reads nil. For fire-and-forget signals.

local Base = require(script.Parent.Parent.Base)

-- Public --------------------------------------------------------------

local Nothing = {}

Nothing.nothing = Base.zero()

return table.freeze(Nothing)
