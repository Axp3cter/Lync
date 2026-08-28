--!strict
--!optimize 2
-- Strings and bytes: the two counted kinds, and the five symbol sets the library names.

local Base = require ("@src/codec/Base")
local Legality = require ("@src/codec/Legality")
local Log = require ("@src/kernel/Log")
local Types = require ("@src/Types")

local Text = {}

-- Constants -----------------------------------------------------------

--[[
    The five sets a caller never has to write. A set is a layout, since a symbol's place in it is
    the index it encodes as, so the order inside each is arbitrary and pinned: a preset a caller
    could spell differently would be two layouts under one name.
]]
const ALPHANUM = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
const BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
const BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
const DIGITS = "0123456789"
const HEX = "0123456789abcdef"

-- Private -------------------------------------------------------------

--[[
    A symbol set indexes its own characters, so a character appearing twice is two indices decoding
    to one value and an encode with no answer to give. Walked a byte at a time because the set is
    bytes: a character past the ASCII range is several of them, and each is a symbol.
]]
local function symbolic (symbols: string)
    if type (symbols) ~= "string" then
        Log.refuse (`an alphabet takes a symbol set, not a {typeof (symbols)}`)
    end
    if symbols == "" then Log.refuse ("an alphabet takes at least one symbol") end

    local seen = {}
    for at = 1, #symbols do
        local byte = string.byte (symbols, at)
        if seen[byte] ~= nil then
            Log.refuse (`an alphabet takes each symbol once, and {string.char (byte)} is twice`)
        end
        seen[byte] = true
    end
end

local function alphabet (symbols: string, min: number, max: number): Types.Codec<string>
    symbolic (symbols)
    Legality.counts ("str", min, max)

    return Base.make ("str", { symbols = symbols, min = min, max = max })
end

-- A preset is one of the sets above with the general form behind it, so every set is one path.
local function preset (symbols: string): (number, number) -> Types.Codec<string>
    return function (min: number, max: number): Types.Codec<string>
        return alphabet (symbols, min, max)
    end
end

-- The bare name, reached through the metamethod. That hands the table over ahead of the bounds.
local function called (_: any, min: number, max: number): Types.Codec<string>
    Legality.counts ("str", min, max)
    return Base.make ("str", { min = min, max = max })
end

-- Public --------------------------------------------------------------

--[[
    One name carrying seven forms: the bare one, the general alphabet, and the five presets. What
    tells a plain string from an alphabet downstream is whether a symbol set was recorded.
]]
Text.str = table.freeze (setmetatable ({
    alphabet = alphabet,
    alphanum = preset (ALPHANUM),
    base32 = preset (BASE32),
    base64 = preset (BASE64),
    digits = preset (DIGITS),
    hex = preset (HEX),
}, { __call = called }))

-- Bytes nobody opens, counted the same way and carrying no set to be outside of.
function Text.buffer (min: number, max: number): Types.Codec<buffer>
    Legality.counts ("buffer", min, max)
    return Base.make ("buffer", { min = min, max = max })
end

return table.freeze (Text)
