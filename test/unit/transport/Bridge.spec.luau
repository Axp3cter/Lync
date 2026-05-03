--!strict
--!optimize 2
-- transport.Bridge: setup, fire variants, error before setup, attach/reset hooks.

local Env = require(script:FindFirstAncestor("test").Env)

local Bridge = Env.Internal.Bridge
local MockBridge = Env.MockBridge
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach
local afterEach = Env.afterEach

describe("transport.Bridge", function(): ()
    local containers: { Instance } = {}

    beforeEach(function(): ()
        Sandbox.resetAll()
        table.clear(containers)
    end)

    afterEach(function(): ()
        for _, inst in containers do
            inst:Destroy()
        end
        table.clear(containers)
    end)

    local function newContainer(): Instance
        local f = Instance.new("Folder")
        table.insert(containers, f)
        return f
    end

    describe("error before setup or attach", function(): ()
        it("reliable() throws", function(): ()
            expect(function(): ()
                Bridge.reliable()
            end):toThrow("not set up")
        end)
        it("unreliable() throws", function(): ()
            expect(function(): ()
                Bridge.unreliable()
            end):toThrow("not set up")
        end)
    end)

    describe("attach + reset hooks", function(): ()
        it("attach installs the supplied transport pair", function(): ()
            local mockReliable = MockBridge.newRemote()
            local mockUnreliable = MockBridge.newRemote()
            Bridge.attach(mockReliable, mockUnreliable)
            expect(Bridge.reliable()):toBe(mockReliable)
            expect(Bridge.unreliable()):toBe(mockUnreliable)
        end)
        it("reset clears the cached pair", function(): ()
            local h = MockBridge.install()
            expect(Bridge.reliable()):toBe(h.reliable)
            Bridge.reset()
            expect(function(): ()
                Bridge.reliable()
            end):toThrow("not set up")
        end)
    end)

    describe("fireServer / fireClient route through attached transport", function(): ()
        it("fireServer captures payload on the mock", function(): ()
            local h = MockBridge.install()
            local data = buffer.create(4)
            buffer.writeu32(data, 0, 0xCAFE)
            Bridge.fireServer(data, {})
            expect(#h.reliable.capturedServer):toBe(1)
            expect(h.reliable.capturedServer[1].data):toBe(data)
        end)
        it("fireClient captures with player + payload", function(): ()
            local h = MockBridge.install()
            local data = buffer.create(2)
            local player = newContainer()
            Bridge.fireClient(player :: any, data, {})
            expect(#h.reliable.capturedClient):toBe(1)
            expect(h.reliable.capturedClient[1].player):toBe(player)
            expect(h.reliable.capturedClient[1].data):toBe(data)
        end)
        it("fireServerUnreliable routes to the unreliable mock", function(): ()
            local h = MockBridge.install()
            local data = buffer.create(2)
            Bridge.fireServerUnreliable(data, {})
            expect(#h.unreliable.capturedServer):toBe(1)
            expect(#h.reliable.capturedServer):toBe(0)
        end)
        it("fireClientUnreliable routes to the unreliable mock", function(): ()
            local h = MockBridge.install()
            local data = buffer.create(2)
            local player = newContainer()
            Bridge.fireClientUnreliable(player :: any, data, {})
            expect(#h.unreliable.capturedClient):toBe(1)
            expect(#h.reliable.capturedClient):toBe(0)
        end)
        it("payload omits refs argument when refs is empty", function(): ()
            --[[
                Bridge picks the no-refs branch when #refs == 0; verify the
                fired payload signature reflects this. Mocks capture data
                regardless, so we test by reading captured.refs.
            ]]
            local h = MockBridge.install()
            local data = buffer.create(2)
            Bridge.fireServer(data, {})
            -- Mock signature: { data, refs? }; refs nil when not passed.
            expect(h.reliable.capturedServer[1].refs):toBeNil()
        end)
        it("payload includes refs argument when refs is non-empty", function(): ()
            local h = MockBridge.install()
            local data = buffer.create(2)
            local part = newContainer()
            Bridge.fireServer(data, { part })
            expect(h.reliable.capturedServer[1].refs):toBeType("table")
        end)
    end)

    describe("attach can be called repeatedly (re-attach)", function(): ()
        it("second attach replaces the first", function(): ()
            local r1 = MockBridge.newRemote()
            local u1 = MockBridge.newRemote()
            Bridge.attach(r1, u1)
            local r2 = MockBridge.newRemote()
            local u2 = MockBridge.newRemote()
            Bridge.attach(r2, u2)
            expect(Bridge.reliable()):toBe(r2)
            expect(Bridge.unreliable()):toBe(u2)
        end)
    end)

    describe("reset is idempotent", function(): ()
        it("reset twice does not throw", function(): ()
            MockBridge.install()
            Bridge.reset()
            expect(function(): ()
                Bridge.reset()
            end).never:toThrow()
        end)
        it("reset before any attach does not throw", function(): ()
            expect(function(): ()
                Bridge.reset()
            end).never:toThrow()
        end)
    end)

    describe("captured frames preserve order", function(): ()
        it("three sequential fireServer calls land in order", function(): ()
            local h = MockBridge.install()
            for i = 1, 3 do
                local b = buffer.create(1)
                buffer.writeu8(b, 0, i)
                Bridge.fireServer(b, {})
            end
            expect(#h.reliable.capturedServer):toBe(3)
            expect(buffer.readu8(h.reliable.capturedServer[1].data, 0)):toBe(1)
            expect(buffer.readu8(h.reliable.capturedServer[3].data, 0)):toBe(3)
        end)
    end)

    describe("reliable vs unreliable buckets isolated", function(): ()
        it("reliable fires don't appear in unreliable bucket", function(): ()
            local h = MockBridge.install()
            local b = buffer.create(1)
            Bridge.fireServer(b, {})
            expect(#h.unreliable.capturedServer):toBe(0)
        end)
        it("unreliable fires don't appear in reliable bucket", function(): ()
            local h = MockBridge.install()
            local b = buffer.create(1)
            Bridge.fireServerUnreliable(b, {})
            expect(#h.reliable.capturedServer):toBe(0)
        end)
    end)
end)

return nil
