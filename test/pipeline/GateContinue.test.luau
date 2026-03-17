--!strict
--!optimize 2

local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local Gate = require (script.Parent.Parent.Parent.transport.Gate)
local Lync = require (script.Parent.Parent.Parent)
local Reader = require (script.Parent.Parent.Parent.transport.Reader)
local Registry = require (script.Parent.Parent.Parent.internal.Registry)
local Runner = require (script.Parent.Parent.Runner)
local Signal = require (script.Parent.Parent.Parent.api.Signal)
local describe, it, expect, fakePlayer =
    Runner.describe, Runner.it, Runner.expect, Runner.fakePlayer

describe ("gate drop continues next packet", function (): ()
    it ("fail A does not block B", function (): ()
        local sigA = Signal.create ()
        local sigB = Signal.create ()
        local regA = Registry.register (
            "__gc_a",
            Lync.f32,
            false,
            sigA,
            nil,
            function (): (boolean, string?)
                return false, "blocked"
            end
        )
        local regB = Registry.register ("__gc_b", Lync.u8, false, sigB, nil, nil)

        local player = fakePlayer ("GC", 3000)
        Gate.onPlayerAdded (player)

        local ch = Channel.create ()
        Channel.writeBatch (ch, regA.id, "__gc_a", Lync.f32, 3.14)
        Channel.writeBatch (ch, regB.id, "__gc_b", Lync.u8, 42)
        local raw, refs = Channel.sealAndDump (ch)

        local gotA: any = "NOT_FIRED"
        local gotB: any = "NOT_FIRED"
        sigA:connect (function (v: any): ()
            gotA = v
        end)
        sigB:connect (function (v: any): ()
            gotB = v
        end)

        Reader.process (raw, refs, player, 0)

        expect (gotA):toBe ("NOT_FIRED")
        expect (gotB):toBe (42)

        Gate.onPlayerRemoved (player)
        sigA:disconnectAll ()
        sigB:disconnectAll ()
    end)
end)

return nil
