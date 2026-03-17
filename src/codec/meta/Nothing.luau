--!strict
--!native
-- Zero-byte codec. Reads nil. Good for fire-and-forget signals.

local Base = require (script.Parent.Parent.Base)

return table.freeze ({
    nothing = Base.zero (),
})
