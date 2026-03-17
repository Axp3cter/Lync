--!strict
--!optimize 2

local Baseline = require (script.Parent.Parent.Parent.internal.Baseline)
local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local Lync = require (script.Parent.Parent.Parent)
local Registry = require (script.Parent.Parent.Parent.internal.Registry)
local Runner = require (script.Parent.Parent.Runner)
local Signal = require (script.Parent.Parent.Parent.api.Signal)
local describe, it, expect, fakePlayer =
    Runner.describe, Runner.it, Runner.expect, Runner.fakePlayer

describe ("u8 batch write-seal-read", function (): ()
    local sig = Signal.create ()
    local reg = Registry.register ("__fid_u8", Lync.u8, false, sig, nil, nil)

    it ("write+seal+read recovers value", function (): ()
        local ch = Channel.create ()
        Channel.writeBatch (ch, reg.id, reg.name, Lync.u8, 42)
        local raw, refs = Channel.sealAndDump (ch)

        local got: any
        sig:connect (function (v: any): ()
            got = v
        end)

        local Reader = require (script.Parent.Parent.Parent.transport.Reader)
        Reader.process (raw, refs, nil, 0)
        expect (got):toBe (42)
        sig:disconnectAll ()
    end)
end)

describe ("struct batch write-seal-read", function (): ()
    local sig = Signal.create ()
    local codec = Lync.struct ({ hp = Lync.u8, name = Lync.string })
    local reg = Registry.register ("__fid_struct", codec, false, sig, nil, nil)

    it ("round-trips struct", function (): ()
        local ch = Channel.create ()
        Channel.writeBatch (ch, reg.id, reg.name, codec, { hp = 100, name = "hero" })
        local raw, refs = Channel.sealAndDump (ch)

        local got: any
        sig:connect (function (v: any): ()
            got = v
        end)

        local Reader = require (script.Parent.Parent.Parent.transport.Reader)
        Reader.process (raw, refs, nil, 0)
        expect (got.hp):toBe (100)
        expect (got.name):toBe ("hero")
        sig:disconnectAll ()
    end)
end)

describe ("multiple packets in one frame", function (): ()
    local sigA = Signal.create ()
    local sigB = Signal.create ()
    local regA = Registry.register ("__fid_multi_a", Lync.u8, false, sigA, nil, nil)
    local regB = Registry.register ("__fid_multi_b", Lync.string, false, sigB, nil, nil)

    it ("both values arrive", function (): ()
        local ch = Channel.create ()
        Channel.writeBatch (ch, regA.id, regA.name, Lync.u8, 255)
        Channel.writeBatch (ch, regB.id, regB.name, Lync.string, "hello")
        local raw, refs = Channel.sealAndDump (ch)

        local gotA, gotB: any
        sigA:connect (function (v: any): ()
            gotA = v
        end)
        sigB:connect (function (v: any): ()
            gotB = v
        end)

        local Reader = require (script.Parent.Parent.Parent.transport.Reader)
        Reader.process (raw, refs, nil, 0)
        expect (gotA):toBe (255)
        expect (gotB):toBe ("hello")
        sigA:disconnectAll ()
        sigB:disconnectAll ()
    end)
end)

describe ("XOR round-trip", function (): ()
    it ("xor then reverse recovers data", function (): ()
        local data = buffer.create (8)
        buffer.writef64 (data, 0, math.pi)
        local prev = buffer.create (8)
        buffer.writef64 (prev, 0, 2.718)
        local xored = Channel.xorApply (data, prev)
        local recovered = Channel.xorApply (xored, prev)
        expect (buffer.readf64 (recovered, 0)):toBe (math.pi)
    end)
end)

return nil
