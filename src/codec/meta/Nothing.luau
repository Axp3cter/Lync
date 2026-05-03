--!strict
--!optimize 2
-- Zero-byte codec. Reads nil. For fire-and-forget signals.

local Base = require(script.Parent.Parent.Base)

-- Public -----------------------------------------------------------------

local Nothing = {}

local base = Base.constant(nil :: nil)
Nothing.nothing = table.freeze({
    _isNothing = true,
    _size = base._size,
    _directWrite = base._directWrite,
    _directRead = base._directRead,
    write = base.write,
    read = base.read,
})

return table.freeze(Nothing)
