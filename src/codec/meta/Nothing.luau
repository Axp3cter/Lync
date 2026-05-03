--!strict
--!optimize 2
-- 0-byte codec. Reads nil. For fire-and-forget signals.

local Base = require(script.Parent.Parent.Base)

-- Public -----------------------------------------------------------------

local Nothing = {}

Nothing.nothing = Base.constant(nil :: nil)

return table.freeze(Nothing)
