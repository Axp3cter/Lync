--!strict
--!optimize 2
-- Shared codec, packet, and scenario builders used by integration / pipeline tests.

local Lync = require(script.Parent.Parent.Parent)

-- Constants --------------------------------------------------------------

local _packetSeq = 0

-- Public -----------------------------------------------------------------

local Fixtures = {}

--[[
    Bench-shape entity codec: six u8 fields, fully direct-write. Used by
    integration suites that exercise the multi-fire batch path with a
    known-size struct.
]]
function Fixtures.entityCodec(): any
    return Lync.struct({
        id = Lync.int(0, 255),
        x = Lync.int(0, 255),
        y = Lync.int(0, 255),
        z = Lync.int(0, 255),
        orientation = Lync.int(0, 255),
        animation = Lync.int(0, 255),
    })
end

--[[
    Bench-shape entity sample with sentinel bytes for verification.
]]
function Fixtures.entityValue(): { [string]: number }
    return { id = 7, x = 10, y = 20, z = 30, orientation = 40, animation = 50 }
end

--[[
    1000-element bool array, the bench's "bools per frame" payload.
]]
function Fixtures.boolArray(n: number?): { boolean }
    return table.create(n or 1000, true)
end

--[[
    Allocate a unique packet name so Registry.register cannot collide
    across tests (even when a test forgets to reset). Prefer Sandbox.resetAll
    in beforeEach as the primary defense; this is the secondary one.
]]
function Fixtures.uniqueName(prefix: string?): string
    _packetSeq += 1
    return `{prefix or "pkt"}_{_packetSeq}`
end

--[[
    Build a packet handle plus a list that captures every received value.
    Returns (handle, received). The packet uses a unique name and the
    given codec.
]]
function Fixtures.recordingPacket(codec: any, options: any?): (any, { any })
    local received: { any } = {}
    local name = Fixtures.uniqueName("recpkt")
    local handle = Lync.packet(name, codec, options)
    handle:on(function(value: any, sender: any?, ts: any?): ()
        table.insert(received, { value = value, sender = sender, timestamp = ts })
    end)
    return handle, received
end

return table.freeze(Fixtures)
