--!strict
--!optimize 2
-- User-defined fixed-size codec.

local Base = require(script.Parent.Parent.Base)

-- Private -------------------------------------------------------------

local floor = math.floor

-- Public --------------------------------------------------------------

local Custom = {}

function Custom.define(
    size: number,
    writeFn: (b: buffer, offset: number, value: any) -> (),
    readFn: (b: buffer, offset: number) -> any
): any
    if type(size) ~= "number" or size < 0 or floor(size) ~= size then
        error("[Lync] Lync.custom: size must be a non-negative integer")
    end

    if size == 0 then
        return Base.zero()
    end

    return Base.define(size, writeFn, readFn)
end

return table.freeze(Custom)
