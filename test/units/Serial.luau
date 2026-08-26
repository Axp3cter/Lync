--!strict
--!optimize 2
--[[
    The descriptor hash alone: the fold from a schema text to the number a handshake carries.
]]

local Serial = require ("@src/shape/Serial")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Limbs = require ("@test/harness/Limbs")
local Rng = require ("@test/harness/Rng")
local Wide = require ("@src/kernel/Wide")

-- Constants -----------------------------------------------------------

--[[
    FNV-1a's two constants, in the hex the standard writes them in. They are the algorithm's, not
    the library's, so a suite states them rather than reading them from the module under test. The
    prime is padded to the width a wide value is written in.
]]
const BASIS = "CBF29CE484222325"
const PRIME = "00000100000001B3"

-- Bytes a fold is likeliest to mishandle, drawn as often as anywhere else.
const NOTABLE = table.freeze ({ 0, 1, 0x7F, 0x80, 0xFE, 0xFF })

-- The longest run a drawn case folds.
const MOST = 48

-- Private -------------------------------------------------------------

const BASIS_LIMBS = table.freeze (Limbs.of (BASIS))
const PRIME_LIMBS = table.freeze (Limbs.of (PRIME))

--[[
    The same fold, in the only arithmetic on this platform that carries sixty-four bits without the
    integer library: sixteen-bit pieces in doubles, and `bit32` for the byte that goes into the low
    one. It shares no instruction with the thing it checks, which is what makes agreeing with it
    evidence rather than a second reading of the same answer.
]]
local function folded (text: string): Limbs.Limbs
    local h = table.clone (BASIS_LIMBS)

    for index = 1, #text do
        h[1] = bit32.bxor (h[1], string.byte (text, index))
        h = Limbs.times (h, PRIME_LIMBS)
    end
    return h
end

local function drawn (rng: Rng.Rng): string
    local count = Rng.int (rng, 0, MOST)
    local out = table.create (count) :: { string }

    for _ = 1, count do
        if Rng.bool (rng) then
            table.insert (out, string.char (Rng.pick (rng, NOTABLE)))
        else
            table.insert (out, string.char (Rng.int (rng, 0, 255)))
        end
    end
    return table.concat (out)
end

-- Every octet, four times over, which is the one long input written down here.
local function every (): string
    local out = table.create (256 * 4) :: { string }
    for _ = 1, 4 do
        for byte = 0, 255 do
            table.insert (out, string.char (byte))
        end
    end
    return table.concat (out)
end

-- Public --------------------------------------------------------------

return {
    --[[
        A descriptor of nothing hashes to the offset basis, because a fold over no bytes is where it
        started. That is the one vector needing no multiply at all, so it pins the constant the fold
        opens with and nothing else, and a hash opening anywhere else fails every vector below for a
        reason this line names first.
    ]]
    Harness.case (
        "serial.basis",
        function () Expect.equal (Wide.text (Serial.hash ("")), BASIS) end
    ),

    --[[
        The standard's own vectors, published with the algorithm rather than written down twice
        here, so agreeing with them says the fold is FNV-1a and not merely self-consistent. They
        prove the wrap too: the first multiply of a one-byte input already runs past what
        sixty-four bits hold.
    ]]
    Harness.case ("serial.vectors", function ()
        local vectors = {
            { text = "a", hash = "AF63DC4C8601EC8C" },
            { text = "b", hash = "AF63DF4C8601F1A5" },
            { text = "c", hash = "AF63DE4C8601EFF2" },
            { text = "d", hash = "AF63D94C8601E773" },
            { text = "e", hash = "AF63D84C8601E5C0" },
            { text = "f", hash = "AF63DB4C8601EAD9" },
            { text = "fo", hash = "08985907B541D342" },
            { text = "foo", hash = "DCB27518FED9D577" },
            { text = "foob", hash = "DD120E790C2512AF" },
            { text = "fooba", hash = "CAC165AFA2FEF40A" },
            { text = "foobar", hash = "85944171F73967E8" },
        }
        for _, vector in vectors do
            local got = Wide.text (Serial.hash (vector.text))
            if got == vector.hash then continue end
            Expect.holds (false, `"{vector.text}" hashed {got} and not {vector.hash}`)
        end
    end),

    --[[
        Every octet is a byte the fold counts. Two hundred and fifty six inputs of one byte answer
        two hundred and fifty six different hashes, a byte of none is a byte rather than the end of
        anything, and a byte past 0x7F is a magnitude rather than a negative.
    ]]
    Harness.case ("serial.bytes", function ()
        Expect.equal (Wide.text (Serial.hash ("\0")), "AF63BD4C8601B7DF")
        Expect.equal (Wide.text (Serial.hash ("\255")), "AF64724C8602EB6E")
        Expect.equal (Wide.text (Serial.hash ("\0\0")), "08328807B4EB6FED")

        local seen = {}
        for byte = 0, 255 do
            local answer = Wide.text (Serial.hash (string.char (byte)))
            if seen[answer] ~= nil then
                Expect.holds (false, `byte {byte} hashed as byte {seen[answer]} did`)
            end
            seen[answer] = byte
        end
    end),

    --[[
        One long input, written down. A thousand bytes carrying every octet four times is longer
        than any drawn case and wider than any published vector, and its answer is committed the
        way a golden frame is: computed once by three arithmetics that agreed, and held.
    ]]
    Harness.case (
        "serial.long",
        function () Expect.equal (Wide.text (Serial.hash (every ())), "1E5698F9D66E6F25") end
    ),

    --[[
        Every run of bytes, against the same fold carried in limbs. The vectors above say the
        algorithm is the standard's for eleven inputs, and this says it stays the standard's for
        every input, without asking the wire format or the integer library to vouch for themselves.
    ]]
    Harness.property ("serial.folds", "leaves", function (rng: Rng.Rng)
        local text = drawn (rng)
        Expect.equal (Wide.text (Serial.hash (text)), Limbs.hex (folded (text)))
    end),
}
