--!strict
--!optimize 2
-- One value through a built codec and back, which is what every suite about bytes opens with.

local Shape = require ("@src/shape")
local Types = require ("@src/Types")

local Expect = require ("@self/Expect")

local Turns = {}

-- Constants -----------------------------------------------------------

-- The path a codec is built under, which is what a refusal out of one names.
const AT = "at"

-- Public --------------------------------------------------------------

-- The context every read is handed, and the one nothing that turns a value reads.
Turns.CTX = table.freeze ({ player = nil, now = 0, last = nil }) :: Types.ValidateContext

-- A codec compiled, under a path a refusal can name.
function Turns.built (codec: any): any return Shape.build (codec, AT) end

--[[
    One value written into a buffer of exactly the width the codec promises.

    The buffer is the bound rather than something larger, so an encode that ran past it raises out
    of `buffer` rather than quietly filling slack a real frame would not have had.
]]
function Turns.wrote (of: any, value: any): (buffer, number)
    local out = buffer.create (of.maxBytes)
    return out, of.write (out, 0, value)
end

-- The same bytes as text, which is what a check that damages one of them works on.
function Turns.text (of: any, value: any): string
    local out, size = Turns.wrote (of, value)
    return buffer.readstring (out, 0, size)
end

-- Text as the buffer a read takes, which is that way round.
function Turns.held (text: string): buffer
    local out = buffer.create (#text)
    buffer.writestring (out, 0, text)
    return out
end

--[[
    What a codec reads back out of its own bytes, with the cursor held to the write.

    A read ending anywhere else read something the write did not put there, which is why no caller
    has to say it and every one of them stays a claim about the value.
]]
function Turns.read (of: any, bytes: buffer, size: number): any
    local at, value = of.read (bytes, 0, Turns.CTX)
    if at == size then return value end

    Expect.holds (false, `a read of {at} bytes against a write of {size}`)
    return value
end

return table.freeze (Turns)
