--!strict
--!native
-- User-defined fixed-size codec factory. Public API wrapper over Base.define.

local Base = require (script.Parent.Parent.Base)

local floor = math.floor

local Custom = {}

function Custom.define (
    size: number,
    writeFn: (b: buffer, offset: number, value: any) -> (),
    readFn: (b: buffer, offset: number) -> any
): any
    if size < 0 or size ~= floor (size) then
        error (`[Lync] Custom codec size must be a non-negative integer, got {size}`)
    end

    if size == 0 then
        return Base.zero ()
    end

    return Base.define (size, writeFn, readFn)
end

return table.freeze (Custom)
