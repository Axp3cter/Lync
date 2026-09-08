--!strict
--!optimize 2
-- The handshake: a hello answered with a verdict, and what each end makes of the other's bytes.

local Catalog = require("@src/kernel/Catalog")
local Handshake = require("@src/runtime/Handshake")
local Log = require("@src/kernel/Log")
local Protocol = require("@src/wire/Protocol")
local Wide = require("@src/kernel/Wide")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local OURS = Wide.fromHex("0123456789ABCDEF")
local THEIRS = Wide.fromHex("FEDCBA9876543210")
local EPOCH = 1234.5

-- The warnings a call raised, by their code, with the call's own answers.
local function warned(call: () -> ...any): ({ string }, ...any)
    local codes: { string } = {}
    local link = Log.onLog(function(kind, _message, data)
        if kind == "warn" then table.insert(codes, tostring(data.code)) end
    end)
    local results = { call() }
    link:disconnect()
    return codes, table.unpack(results)
end

return {
    -- A hello carrying our hash earns an accepting verdict carrying the epoch, which the client
    -- reads back as that epoch.
    Harness.case("handshake.accepts", function()
        local hello = Handshake.hello(OURS)
        Expect.equal(buffer.len(hello), Protocol.HELLO_BYTES)
        local codes, verdict, spoken = warned(function()
            return Handshake.verdict(OURS, EPOCH, hello)
        end)
        Expect.equal(codes, {})
        Expect.equal(spoken, true)
        Expect.equal(buffer.len(verdict), Protocol.VERDICT_BYTES)
        Expect.equal(buffer.readu8(verdict, 0), Protocol.VERDICT_ACCEPT)
        Expect.equal(Handshake.judged(OURS, verdict), EPOCH)
    end),

    -- A hello from another build earns a rejecting verdict carrying our hash, warned at the
    -- server and raised at the client, both naming the two hashes.
    Harness.case("handshake.rejects", function()
        local codes, verdict, spoken = warned(function()
            return Handshake.verdict(OURS, EPOCH, Handshake.hello(THEIRS))
        end)
        Expect.equal(codes, { Catalog.MISMATCH })
        Expect.equal(spoken, false)
        Expect.equal(buffer.readu8(verdict, 0), Protocol.VERDICT_REJECT)
        Expect.holds(
            Wide.eq(Wide.read(verdict, Protocol.VERDICT_FIELD), OURS),
            "the verdict lost our hash"
        )
        local said = Expect.throws(function()
            Handshake.judged(THEIRS, verdict)
        end)
        Expect.holds(string.find(said, Wide.toHex(OURS), 1, true) ~= nil, `it said {said}`)
        Expect.holds(string.find(said, Wide.toHex(THEIRS), 1, true) ~= nil, `it said {said}`)
    end),

    -- Bytes neither message could be are warned under one code and answered with nothing.
    Harness.case("handshake.unspoken", function()
        local codes, verdict, spoken = warned(function()
            return Handshake.verdict(OURS, EPOCH, buffer.create(3))
        end)
        Expect.equal(codes, { Catalog.HELLO })
        Expect.equal({ verdict, spoken }, { nil, false })

        local short = warned(function()
            return Handshake.judged(OURS, buffer.create(2))
        end)
        Expect.equal(short, { Catalog.HELLO })
        local odd = buffer.create(Protocol.VERDICT_BYTES)
        buffer.writeu8(odd, 0, 7)
        local unknown, epoch = warned(function()
            return Handshake.judged(OURS, odd)
        end)
        Expect.equal(unknown, { Catalog.HELLO })
        Expect.equal(epoch, nil)
    end),
}
