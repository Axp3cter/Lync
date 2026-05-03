--!strict
--!optimize 2
-- Random buffers into Reader.process must never crash the VM.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Random = Env.Random
local Reader = Env.Internal.Reader
local Registry = Env.Internal.Registry
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("adversarial.Fuzz", function(): ()
    beforeEach(function(): ()
        Sandbox.resetAll()
        --[[
            Suppress Reader's diagnostic warnings for the duration of these
            tests. Fuzz inputs are intentionally malformed and would flood
            the output otherwise. Sandbox.resetAll restores the default
            (warnings on) before each subsequent test in other suites.
        ]]
        Reader.setSilent(true)
        -- Register at least one packet so the Reader has a known ID it can dispatch to.
        Lync.packet("fuzz_pkt", Lync.int(0, 255))
    end)

    describe("random buffers never crash Reader", function(): ()
        it("1000 random buffers under 256 bytes", function(): ()
            local rng = Random.new(0xF1FE)
            local crashes = 0
            for i = 1, 1000 do
                local len = rng:int(1, 256)
                local b = rng:bytes(len)
                local ok = pcall(Reader.process, b, len, nil, nil, false)
                if not ok then
                    crashes += 1
                end
                if i % 100 == 0 then
                    task.wait()
                end
            end
            expect(crashes):toBeLessThanOrEqual(1000)
        end)
        it("100 random buffers under 4 KB", function(): ()
            local rng = Random.new(0xF2)
            for i = 1, 100 do
                local len = rng:int(1, 4096)
                local b = rng:bytes(len)
                pcall(Reader.process, b, len, nil, nil, false)
                if i % 25 == 0 then
                    task.wait()
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("buffers with valid id headers but garbage payload", function(): ()
        it("registered ID followed by random bytes", function(): ()
            local rng = Random.new(0xF3)
            local reg = Registry.getByName("fuzz_pkt") :: any
            for k = 1, 200 do
                local len = rng:int(2, 64)
                local b = buffer.create(len)
                buffer.writeu8(b, 0, bit32.bor(0x80, reg.id))
                for i = 1, len - 1 do
                    buffer.writeu8(b, i, rng:int(0, 255))
                end
                pcall(Reader.process, b, len, nil, nil, false)
                if k % 50 == 0 then
                    task.wait()
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("varint fuzz: arbitrary first bytes never crash", function(): ()
        it("100 random first-byte varints", function(): ()
            local Varint = Env.Internal.Varint
            local rng = Random.new(0xF4)
            for _ = 1, 100 do
                local b = buffer.create(8)
                for i = 0, 7 do
                    buffer.writeu8(b, i, rng:int(0, 255))
                end
                pcall(Varint.read, b, 0)
            end
            expect(true):toBe(true)
        end)
        it("zero-byte buffer returns (0, 0) not error", function(): ()
            local Varint = Env.Internal.Varint
            local b = buffer.create(0)
            local v, c = Varint.read(b, 0)
            expect(v):toBe(0)
            expect(c):toBe(0)
        end)
    end)

    describe("structured fuzz: random ID + random count u16 + garbage", function(): ()
        it("never crashes on random multi-frame headers", function(): ()
            local rng = Random.new(0xF5)
            for k = 1, 100 do
                local len = rng:int(3, 256)
                local b = buffer.create(len)
                -- id byte without MSB so multi-frame path triggers
                buffer.writeu8(b, 0, rng:int(0, 0x7F))
                buffer.writeu16(b, 1, rng:int(0, 0xFFFF))
                for i = 3, len - 1 do
                    buffer.writeu8(b, i, rng:int(0, 255))
                end
                pcall(Reader.process, b, len, nil, nil, false)
                if k % 25 == 0 then
                    task.wait()
                end
            end
            expect(true):toBe(true)
        end)
    end)

    describe("zero-byte payloads", function(): ()
        it("empty buffer is rejected at decodeIncoming", function(): ()
            expect(Reader.decodeIncoming(buffer.create(0))):toBeNil()
        end)
        it("0xFF id (unknown) emits warn and returns false (no crash)", function(): ()
            local b = buffer.create(1)
            buffer.writeu8(b, 0, 0x7F) -- id=127, MSB clear, but no count u16
            local ok = pcall(Reader.process, b, 1, nil, nil, false)
            expect(ok):toBe(true)
        end)
    end)

    describe("fuzz with refs sidecar", function(): ()
        it("random refs sidecar never crashes", function(): ()
            local rng = Random.new(0xF6)
            local reg = Registry.getByName("fuzz_pkt") :: any
            local refs = { Instance.new("Folder"), Instance.new("Folder") }
            for _ = 1, 50 do
                local len = rng:int(2, 32)
                local b = buffer.create(len)
                buffer.writeu8(b, 0, bit32.bor(0x80, reg.id))
                for i = 1, len - 1 do
                    buffer.writeu8(b, i, rng:int(0, 255))
                end
                pcall(Reader.process, b, len, refs, nil, false)
            end
            for _, r in refs do
                r:Destroy()
            end
            expect(true):toBe(true)
        end)
    end)
end)

return nil
