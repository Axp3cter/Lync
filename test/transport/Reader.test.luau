--!strict
--!optimize 2
local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local Lync = require (script.Parent.Parent.Parent)
local Reader = require (script.Parent.Parent.Parent.transport.Reader)
local Registry = require (script.Parent.Parent.Parent.internal.Registry)
local Runner = require (script.Parent.Parent.Runner)
local Signal = require (script.Parent.Parent.Parent.api.Signal)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe ("Reader.decodeIncoming", function (): ()
    it ("accepts buffer", function (): ()
        expect (Reader.decodeIncoming (buffer.create (4))):toBeTruthy ()
    end)
    it ("rejects string", function (): ()
        expect (Reader.decodeIncoming ("not a buffer")):toBeNil ()
    end)
    it ("rejects number", function (): ()
        expect (Reader.decodeIncoming (42)):toBeNil ()
    end)
    it ("rejects nil", function (): ()
        expect (Reader.decodeIncoming (nil)):toBeNil ()
    end)
    it ("rejects table", function (): ()
        expect (Reader.decodeIncoming ({})):toBeNil ()
    end)
    it ("accepts empty buffer", function (): ()
        expect (Reader.decodeIncoming (buffer.create (0))):toBeTruthy ()
    end)
end)

describe ("Reader.process empty frame", function (): ()
    it ("no-op on zero-length buffer", function (): ()
        Reader.process (buffer.create (0), nil, nil, 0)
    end)
end)

describe ("Reader.process single packet", function (): ()
    local sig = Signal.create ()
    local reg = Registry.register ("__reader_u8", Lync.u8, false, sig, nil, nil)

    it ("fires signal with decoded value", function (): ()
        local ch = Channel.create ()
        Channel.writeBatch (ch, reg.id, reg.name, Lync.u8, 99)
        local raw, refs = Channel.sealAndDump (ch)

        local got: any
        local conn = sig:connect (function (v: any): ()
            got = v
        end)
        Reader.process (raw, refs, nil, 0)
        expect (got):toBe (99)
        conn:disconnect ()
    end)
end)

describe ("Reader.process multiple same-id values", function (): ()
    local sig = Signal.create ()
    local reg = Registry.register ("__reader_batch", Lync.u8, false, sig, nil, nil)

    it ("fires once per value", function (): ()
        local ch = Channel.create ()
        Channel.writeBatch (ch, reg.id, reg.name, Lync.u8, 10)
        Channel.writeBatch (ch, reg.id, reg.name, Lync.u8, 20)
        Channel.writeBatch (ch, reg.id, reg.name, Lync.u8, 30)
        local raw, refs = Channel.sealAndDump (ch)

        local values = {} :: { number }
        local conn = sig:connect (function (v: any): ()
            table.insert (values, v)
        end)
        Reader.process (raw, refs, nil, 0)
        expect (#values):toBe (3)
        expect (values[1]):toBe (10)
        expect (values[2]):toBe (20)
        expect (values[3]):toBe (30)
        conn:disconnect ()
    end)
end)

describe ("Reader.process struct", function (): ()
    local codec = Lync.struct ({ hp = Lync.u8, name = Lync.string })
    local sig = Signal.create ()
    local reg = Registry.register ("__reader_struct", codec, false, sig, nil, nil)

    it ("decodes struct fields", function (): ()
        local ch = Channel.create ()
        Channel.writeBatch (ch, reg.id, reg.name, codec, { hp = 100, name = "hero" })
        local raw, refs = Channel.sealAndDump (ch)

        local got: any
        local conn = sig:connect (function (v: any): ()
            got = v
        end)
        Reader.process (raw, refs, nil, 0)
        expect (got.hp):toBe (100)
        expect (got.name):toBe ("hero")
        conn:disconnect ()
    end)
end)

return nil
