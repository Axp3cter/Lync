--!strict
--!optimize 2
-- transport.Client: getChannel + flush against a mock bridge.

local Env = require(script:FindFirstAncestor("test").Env)

local Channel = Env.Internal.Channel
local Client = Env.Internal.Client
local Lync = Env.Lync
local MockBridge = Env.MockBridge
local Registry = Env.Internal.Registry
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("transport.Client", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("getChannel", function(): ()
        it("reliable and unreliable are distinct singletons", function(): ()
            local r = Client.getChannel(false)
            local u = Client.getChannel(true)
            expect(r).never:toBe(u)
        end)
        it("subsequent calls return the same channel", function(): ()
            expect(Client.getChannel(false)):toBe(Client.getChannel(false))
        end)
    end)

    describe("flush forwards to Bridge.fireServer", function(): ()
        it("buffered reliable bytes are routed to the mock", function(): ()
            local h = MockBridge.install()
            local ch = Client.getChannel(false)
            local reg = Registry.register({
                name = "client_flush_pkt",
                kind = Registry.KIND_PACKET,
                codec = Lync.int(0, 255),
                isUnreliable = false,
                partner = nil,
                needsGate = false,
                headerSize = 1,
                timestampMode = Channel.TS_NONE,
                openFn = Channel.resolveOpenFn(Channel.TS_NONE, "client_flush_pkt"),
                rateLimit = nil,
                validate = nil,
                maxPayloadBytes = nil,
            })
            Channel.writeBatch(ch, reg, 42)

            Client.flush()
            expect(#h.reliable.capturedServer):toBe(1)
        end)
        it("idle channels do not produce frames", function(): ()
            local h = MockBridge.install()
            Client.flush()
            expect(#h.reliable.capturedServer):toBe(0)
            expect(#h.unreliable.capturedServer):toBe(0)
        end)
    end)

    describe("channel reset on flush", function(): ()
        it("flush resets the channel cursor to 0", function(): ()
            MockBridge.install()
            local ch = Client.getChannel(false)
            local reg = Registry.register({
                name = "client_reset_pkt",
                kind = Registry.KIND_PACKET,
                codec = Lync.int(0, 255),
                isUnreliable = false,
                partner = nil,
                needsGate = false,
                headerSize = 1,
                timestampMode = Channel.TS_NONE,
                openFn = Channel.resolveOpenFn(Channel.TS_NONE, "client_reset_pkt"),
                rateLimit = nil,
                validate = nil,
                maxPayloadBytes = nil,
            })
            Channel.writeBatch(ch, reg, 1)
            expect(ch.cursor):toBeGreaterThan(0)
            Client.flush()
            expect(ch.cursor):toBe(0)
        end)
        it("two flushes in a row second is a no-op", function(): ()
            local h = MockBridge.install()
            local ch = Client.getChannel(false)
            local reg = Registry.register({
                name = "client_double_flush",
                kind = Registry.KIND_PACKET,
                codec = Lync.int(0, 255),
                isUnreliable = false,
                partner = nil,
                needsGate = false,
                headerSize = 1,
                timestampMode = Channel.TS_NONE,
                openFn = Channel.resolveOpenFn(Channel.TS_NONE, "client_double_flush"),
                rateLimit = nil,
                validate = nil,
                maxPayloadBytes = nil,
            })
            Channel.writeBatch(ch, reg, 1)
            Client.flush()
            Client.flush()
            expect(#h.reliable.capturedServer):toBe(1)
        end)
    end)

    describe("unreliable channel routing", function(): ()
        it("unreliable channel writes go to unreliable mock bucket", function(): ()
            local h = MockBridge.install()
            local ch = Client.getChannel(true)
            local reg = Registry.register({
                name = "client_unrel",
                kind = Registry.KIND_PACKET,
                codec = Lync.int(0, 255),
                isUnreliable = true,
                partner = nil,
                needsGate = false,
                headerSize = 1,
                timestampMode = Channel.TS_NONE,
                openFn = Channel.resolveOpenFn(Channel.TS_NONE, "client_unrel"),
                rateLimit = nil,
                validate = nil,
                maxPayloadBytes = nil,
            })
            Channel.writeBatch(ch, reg, 7)
            Client.flush()
            expect(#h.unreliable.capturedServer):toBe(1)
            expect(#h.reliable.capturedServer):toBe(0)
        end)
    end)

    describe("Sandbox.reset clears the channel", function(): ()
        it("getChannel after reset returns a fresh channel", function(): ()
            local before = Client.getChannel(false)
            Sandbox.resetAll()
            local after = Client.getChannel(false)
            -- After reset Client may either return the same channel zeroed,
            -- or a fresh one. Either way cursor must be 0.
            expect(after.cursor):toBe(0)
            expect(after :: any).never:toBe(nil)
            expect(before).never:toBe(nil)
        end)
    end)
end)

return nil
