--!strict
--!native
-- Signed integer writers via writeu* + two's complement (writei* is not FASTCALL).

-- Private ----------------------------------------------------------------

local writeu8 = buffer.writeu8
local writeu16 = buffer.writeu16
local writeu32 = buffer.writeu32

-- Public -----------------------------------------------------------------

local Signed = {}

function Signed.writeI8(b: buffer, off: number, value: number): ()
    writeu8(b, off, if value < 0 then value + 0x100 else value)
end

function Signed.writeI16(b: buffer, off: number, value: number): ()
    writeu16(b, off, if value < 0 then value + 0x10000 else value)
end

function Signed.writeI32(b: buffer, off: number, value: number): ()
    writeu32(b, off, if value < 0 then value + 0x100000000 else value)
end

-- Reads stay on buffer.readi* (already FASTCALL).
Signed.readI8 = buffer.readi8
Signed.readI16 = buffer.readi16
Signed.readI32 = buffer.readi32

return table.freeze(Signed)
