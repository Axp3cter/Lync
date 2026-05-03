--!strict
--!optimize 2
-- Targeted exploit attempts: ID forgery, table-as-Instance, ref overflow,
-- variant injection through tagged.

local Env = require(script:FindFirstAncestor("test").Env)

local Channel = Env.Internal.Channel
local Gate = Env.Internal.Gate
local Lync = Env.Lync
local Reader = Env.Internal.Reader
local Registry = Env.Internal.Registry
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("adversarial.ExploitVectors", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("ID forgery: id 0 is never assigned", function(): ()
        it("Reader.process aborts on id 0 byte", function(): ()
            Reader.setSilent(true)
            local received = 0
            local handle = Lync.packet("forge_pkt", Lync.int(0, 255))
            handle:on(function(): ()
                received += 1
            end)
            local reg = Registry.getByName("forge_pkt") :: any

            local raw = buffer.create(3)
            buffer.writeu8(raw, 0, 0x80) -- id 0, MSB set
            buffer.writeu8(raw, 1, bit32.bor(0x80, reg.id))
            buffer.writeu8(raw, 2, 7)
            Reader.process(raw, 3, nil, nil, false)
            expect(received):toBe(0)
        end)
    end)

    describe("table-as-Instance attempt: Gate.scan rejects fake instance shapes", function(): ()
        it("table with Class-like fields is still just a table to scan", function(): ()
            local fake = { ClassName = "Folder", Name = "Faked" }
            -- scan walks tables and checks NaN/inf only; doesn't validate type.
            -- Codec-side typeCheck is what catches this. Verify the codec path:
            local codec = Lync.struct({ inst = Lync.inst })
            expect(Gate.validate({ inst = fake }, codec)).never:toBe(nil)
        end)
    end)

    describe("pushRef overflow guard", function(): ()
        it("> 65535 refs throws on the next push", function(): ()
            local ch = Channel.create()
            ch.refCount = 0xFFFF
            ch.refs[0xFFFF] = {} :: any
            expect(function(): ()
                Channel.pushRef(ch, {})
            end):toThrow("ref overflow")
        end)
    end)

    describe("tagged variant injection", function(): ()
        it("Gate.validate rejects unknown variant", function(): ()
            local c = Lync.tagged("type", {
                ok = Lync.struct({ x = Lync.int(0, 255) }),
            })
            expect(Gate.validate({ type = "evil", x = 1 }, c)).never:toBe(nil)
        end)
        it("Gate.validate rejects payload that violates inner codec", function(): ()
            local c = Lync.tagged("type", {
                ok = Lync.struct({ x = Lync.int(0, 100) }),
            })
            expect(Gate.validate({ type = "ok", x = 999 }, c)).never:toBe(nil)
        end)
    end)

    describe("enum index out of range", function(): ()
        it("crafted buffer with index >= variant count fails on read", function(): ()
            local c = Lync.enum("a", "b")
            local b = buffer.create(1)
            buffer.writeu8(b, 0, 5)
            expect(function(): ()
                c.read(b, 0, nil)
            end):toThrow("invalid index")
        end)
    end)

    describe("rate-limit cannot be bypassed by varying packet ID", function(): ()
        it("per-packet rate limit isolates by packet+player, not by call site", function(): ()
            local p = Instance.new("Folder")
            local reg1 = { id = 100, rateLimit = { maxPerSecond = 1, burst = 1 } } :: any
            local reg2 = { id = 200, rateLimit = { maxPerSecond = 1, burst = 1 } } :: any
            -- Different reg.id buckets are independent.
            expect(Gate.checkRateLimit(reg1, p)):toBe(true)
            expect(Gate.checkRateLimit(reg1, p)):toBe(false)
            expect(Gate.checkRateLimit(reg2, p)):toBe(true)
            p:Destroy()
        end)
        it("global rate limit applies across packets", function(): ()
            Gate.configureGlobalRateLimit(2)
            local p = Instance.new("Folder")
            expect(Gate.checkGlobalRateLimit(p)):toBe(true)
            expect(Gate.checkGlobalRateLimit(p)):toBe(true)
            expect(Gate.checkGlobalRateLimit(p)):toBe(false)
            p:Destroy()
        end)
    end)

    describe("schema-aware validation rejects deeply nested malicious payloads", function(): ()
        it("nested struct with NaN inside f32 field rejects", function(): ()
            local c = Lync.struct({
                inner = Lync.struct({ value = Lync.f32 }),
            })
            local bad = { inner = { value = 0 / 0 } }
            expect(Gate.validate(bad, c)).never:toBe(nil)
        end)
        it("array of struct with one bad element rejects entire array", function(): ()
            local elem = Lync.struct({ x = Lync.int(0, 100) })
            local c = Lync.array(elem)
            expect(Gate.validate({ { x = 1 }, { x = 999 } }, c)).never:toBe(nil)
        end)
    end)
end)

return nil
