--!strict
--!optimize 2
local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe ("boundedString overflow", function (): ()
    local bounded = Lync.boundedString (10)

    local function encode (str: string): buffer
        local ch = Channel.create ()
        Lync.string.write (ch, str)
        local buf = buffer.create (ch.cursor)
        buffer.copy (buf, 0, ch.buff, 0, ch.cursor)
        return buf
    end

    it ("within limit", function (): ()
        expect (bounded.read (encode ("short"), 0, nil)):toBe ("short")
    end)
    it ("exact limit", function (): ()
        expect (bounded.read (encode ("0123456789"), 0, nil)):toBe ("0123456789")
    end)
    it ("rejects over limit", function (): ()
        expect (function (): ()
            bounded.read (encode ("01234567890"), 0, nil)
        end):toThrow ("exceeds max")
    end)
    it ("rejects way over limit", function (): ()
        expect (function (): ()
            bounded.read (encode (string.rep ("x", 100)), 0, nil)
        end):toThrow ("exceeds max")
    end)
    it ("accepts empty", function (): ()
        expect (bounded.read (encode (""), 0, nil)):toBe ("")
    end)
end)

return nil
