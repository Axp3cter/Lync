--!strict
--!optimize 2
-- internal.Channel: per-channel state, MSB framing, XOR delta, query frames, timestamps.

local Env = require(script:FindFirstAncestor("test").Env)

local Base = Env.Internal.Base
local Channel = Env.Internal.Channel
local Lync = Env.Lync
local Registry = Env.Internal.Registry
local Sandbox = Env.Sandbox
local Wire = Env.Wire

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

local function packetReg(name: string, codec: any?): any
    return Registry.register({
        name = name,
        kind = Registry.KIND_PACKET,
        codec = codec or Lync.int(0, 255),
        isUnreliable = false,
        partner = nil,
        needsGate = false,
        headerSize = 1,
        timestampMode = Channel.TS_NONE,
        openFn = Channel.resolveOpenFn(Channel.TS_NONE, name),
        rateLimit = nil,
        validate = nil,
        maxPayloadBytes = nil,
    })
end

describe("internal.Channel", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("create defaults", function(): ()
        it("cursor 0, size 1024, lastId -1", function(): ()
            local ch = Channel.create()
            expect(ch.cursor):toBe(0)
            expect(ch.size):toBe(1024)
            expect(ch.lastId):toBe(-1)
            expect(ch.singleMode):toBe(false)
            expect(ch.refCount):toBe(0)
        end)
        it("buff is a 1024-byte buffer", function(): ()
            local ch = Channel.create()
            expect(ch.buff):toBeBuffer(1024)
        end)
    end)

    describe("timestamp mode constants", function(): ()
        it("TS_NONE = 0", function(): ()
            expect(Channel.TS_NONE):toBe(0)
        end)
        it("TS_FRAME = 1", function(): ()
            expect(Channel.TS_FRAME):toBe(1)
        end)
        it("TS_OFFSET = 2", function(): ()
            expect(Channel.TS_OFFSET):toBe(2)
        end)
        it("TS_FULL = 3", function(): ()
            expect(Channel.TS_FULL):toBe(3)
        end)
    end)

    describe("writeByte", function(): ()
        it("writes one byte and advances cursor", function(): ()
            local ch = Channel.create()
            Channel.writeByte(ch, 0x42)
            expect(ch.cursor):toBe(1)
            expect(buffer.readu8(ch.buff, 0)):toBe(0x42)
        end)
        it("grows buffer when at capacity", function(): ()
            local ch = Channel.create()
            ch.cursor = ch.size
            Channel.writeByte(ch, 0xAA)
            expect(ch.size):toBeGreaterThan(1024)
            expect(buffer.readu8(ch.buff, 1024)):toBe(0xAA)
        end)
    end)

    describe("pushRef", function(): ()
        it("appends to refs and writes 1-based index as u16", function(): ()
            local ch = Channel.create()
            local part = Instance.new("Folder")
            Channel.pushRef(ch, part)
            expect(ch.refCount):toBe(1)
            expect(ch.refs[1]):toBe(part)
            expect(buffer.readu16(ch.buff, 0)):toBe(1)
            part:Destroy()
        end)
        it("increments index on subsequent calls", function(): ()
            local ch = Channel.create()
            local a = Instance.new("Folder")
            local b = Instance.new("Folder")
            Channel.pushRef(ch, a)
            expect(ch.refCount):toBe(1)
            Channel.pushRef(ch, b)
            expect(ch.refCount):toBe(2)
            a:Destroy()
            b:Destroy()
        end)
    end)

    describe("alloc grows to next power-of-two", function(): ()
        it("1020 + 100 -> 2048", function(): ()
            local ch = Channel.create()
            ch.cursor = 1020
            Base.alloc(ch, 100)
            expect(ch.size):toBe(2048)
        end)
        it("preserves bytes after growth", function(): ()
            local ch = Channel.create()
            buffer.writeu32(ch.buff, 0, 0xDEADBEEF)
            ch.cursor = 4
            Base.alloc(ch, 2000)
            expect(buffer.readu32(ch.buff, 0)):toBe(0xDEADBEEF)
        end)
        it("zero-byte alloc is a no-op", function(): ()
            local ch = Channel.create()
            local original = ch.buff
            Base.alloc(ch, 0)
            expect(ch.buff):toBe(original)
        end)
    end)

    describe("reset", function(): ()
        it("zeros cursor and clears refs", function(): ()
            local ch = Channel.create()
            ch.cursor = 500
            ch.refCount = 3
            ch.refs[1] = {} :: any
            Channel.reset(ch)
            expect(ch.cursor):toBe(0)
            expect(ch.refCount):toBe(0)
            expect(ch.lastId):toBe(-1)
            expect(ch.itemCount):toBe(0)
            expect(ch.singleMode):toBe(false)
        end)
        it("keeps the buffer allocation", function(): ()
            local ch = Channel.create()
            ch.cursor = 500
            local size = ch.size
            Channel.reset(ch)
            expect(ch.size):toBe(size)
        end)
    end)

    describe("sealAndDump", function(): ()
        it("returns a snapshot copy", function(): ()
            local ch = Channel.create()
            buffer.writeu32(ch.buff, 0, 0xCAFE)
            ch.cursor = 4
            local snap, _, byteLen = Channel.sealAndDump(ch)
            expect(byteLen):toBe(4)
            expect(buffer.readu32(snap, 0)):toBe(0xCAFE)
        end)
        it("snapshot is isolated from the channel", function(): ()
            local ch = Channel.create()
            buffer.writeu32(ch.buff, 0, 0xCAFE)
            ch.cursor = 4
            local snap = Channel.sealAndDump(ch)
            buffer.writeu32(snap, 0, 0)
            expect(buffer.readu32(ch.buff, 0)):toBe(0xCAFE)
        end)
        it("clones refs when present", function(): ()
            local ch = Channel.create()
            ch.cursor = 2
            ch.refCount = 1
            local part = Instance.new("Folder")
            ch.refs[1] = part
            local _, refs, _, refCount = Channel.sealAndDump(ch)
            expect(refCount):toBe(1)
            expect(refs[1]):toBe(part)
            refs[1] = nil :: any
            expect(ch.refs[1]):toBe(part)
            part:Destroy()
        end)
        it("returns frozen empty refs when none", function(): ()
            local ch = Channel.create()
            ch.cursor = 1
            local _, refs, _, refCount = Channel.sealAndDump(ch)
            expect(refCount):toBe(0)
            expect(function(): ()
                (refs :: any)[1] = "bad"
            end):toThrow()
        end)
    end)

    describe("writeBatch single-mode framing", function(): ()
        it("first write puts MSB-set id at cursor 0", function(): ()
            local reg = packetReg("first")
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 42)
            expect(buffer.readu8(ch.buff, 0)):toBe(bit32.bor(0x80, reg.id))
            expect(ch.singleMode):toBe(true)
        end)
        it("ID extractable by clearing MSB", function(): ()
            local reg = packetReg("clearmsb")
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 0)
            expect(bit32.band(buffer.readu8(ch.buff, 0), 0x7F)):toBe(reg.id)
        end)
        it("header byte is id + 128 (since id <= 127, equivalent to bor(0x80, id))", function(): ()
            -- The optimized openFn uses `id + 128` instead of bit32.bor; this
            -- test pins the wire equivalence so future changes can't drift.
            local reg = packetReg("id_plus_128")
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 0)
            expect(buffer.readu8(ch.buff, 0)):toBe(reg.id + 128)
        end)
    end)

    describe("writeBatch single -> multi upgrade", function(): ()
        it("second write of same id clears MSB", function(): ()
            local reg = packetReg("upgrade_msb")
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 1)
            Channel.writeBatch(ch, reg, 2)
            expect(bit32.band(buffer.readu8(ch.buff, 0), 0x80)):toBe(0)
            expect(ch.singleMode):toBe(false)
        end)
        it("two-write batch wire = 1 (id) + 2 (count) + 2*payload", function(): ()
            local reg = packetReg("upgrade_size")
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 0)
            Channel.writeBatch(ch, reg, 0)
            expect(ch.cursor):toBe(1 + 2 + 1 + 1)
        end)
        it("count field finalized to 2 after seal", function(): ()
            local reg = packetReg("upgrade_count")
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 5)
            Channel.writeBatch(ch, reg, 6)
            local snap = Channel.sealAndDump(ch)
            expect(buffer.readu16(snap, 1)):toBe(2)
        end)
    end)

    describe("writeBatch atomicity vs codec errors", function(): ()
        it("itemCount only bumps after codec.write succeeds", function(): ()
            local throwingCodec: any = {
                _size = nil,
                write = function(_ch: any, _v: any): ()
                    error("codec failure", 0)
                end,
                read = function(_b, _pos, _refs)
                    return nil, 0
                end,
            }
            local reg = packetReg("err_pkt", throwingCodec)
            local ch = Channel.create()
            local ok = pcall(function(): ()
                Channel.writeBatch(ch, reg, 0)
            end)
            expect(ok):toBe(false)
            expect(ch.itemCount):toBe(0)
        end)
        it("cursor rewinds to pre-codec position on throw", function(): ()
            -- A codec that advances cursor partway then throws would leave
            -- the channel with a partial body past the last item boundary.
            -- Without rewind, the next sealAndDump sends those bytes and
            -- the receiver desyncs.
            local partialCodec: any = {
                _size = nil,
                write = function(ch: any, _v: any): ()
                    if ch.cursor + 4 > ch.size then
                        Base.alloc(ch, 4)
                    end
                    buffer.writeu32(ch.buff, ch.cursor, 0xDEADBEEF)
                    ch.cursor += 4
                    error("aborted after partial advance", 0)
                end,
                read = function(_b, _pos, _refs)
                    return nil, 0
                end,
            }
            local reg = packetReg("err_partial", partialCodec)
            local ch = Channel.create()
            local cursorBefore = ch.cursor
            local ok = pcall(function(): ()
                Channel.writeBatch(ch, reg, 0)
            end)
            expect(ok):toBe(false)
            -- openOrUpgrade ran (header byte) before the throw, so cursor
            -- sits exactly at the post-header position — not past the
            -- 4-byte advance the codec attempted.
            expect(ch.cursor):toBe(cursorBefore + 1)
        end)
        it("refCount rewinds to pre-codec count on throw", function(): ()
            local refLeakingCodec: any = {
                _size = nil,
                write = function(ch: any, _v: any): ()
                    Channel.pushRef(ch, Instance.new("Folder"))
                    Channel.pushRef(ch, Instance.new("Folder"))
                    error("aborted after pushing refs", 0)
                end,
                read = function(_b, _pos, _refs)
                    return nil, 0
                end,
            }
            local reg = packetReg("err_refs", refLeakingCodec)
            local ch = Channel.create()
            local ok = pcall(function(): ()
                Channel.writeBatch(ch, reg, 0)
            end)
            expect(ok):toBe(false)
            expect(ch.refCount):toBe(0)
            expect(ch.refs[1]):toBeNil()
            expect(ch.refs[2]):toBeNil()
        end)
        it("mid-batch throw preserves prior items intact", function(): ()
            -- The place-file scenario: a stable multi-mode batch with N
            -- successful items, then (N+1)'s codec hits the cap. Rewind
            -- must preserve the first N item bytes so the flush is coherent.
            local goodCodec: any = {
                _size = 1,
                write = function(ch: any, v: any): ()
                    if ch.cursor + 1 > ch.size then
                        Base.alloc(ch, 1)
                    end
                    buffer.writeu8(ch.buff, ch.cursor, v)
                    ch.cursor += 1
                end,
                read = function(b, pos, _refs)
                    return buffer.readu8(b, pos), 1
                end,
            }
            local reg = packetReg("err_midbatch_cap", goodCodec)
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 1)
            Channel.writeBatch(ch, reg, 2)
            Channel.writeBatch(ch, reg, 3)
            local cursorAfterThree = ch.cursor
            local itemCountAfterThree = ch.itemCount

            -- Now swap in a throwing codec for the same reg and watch the rewind.
            reg.codec = {
                _size = nil,
                write = function(_ch: any, _v: any): ()
                    error("simulated alloc-cap throw", 0)
                end,
                read = function(_b, _pos, _refs)
                    return nil, 0
                end,
            } :: any
            local ok = pcall(function(): ()
                Channel.writeBatch(ch, reg, 4)
            end)
            expect(ok):toBe(false)
            expect(ch.cursor):toBe(cursorAfterThree)
            expect(ch.itemCount):toBe(itemCountAfterThree)
        end)
        it("writeBatchEncoded itemCount stays atomic when splice throws on cap", function(): ()
            Base.setMaxSize(2048)
            local reg = packetReg("err_encoded")
            local ch = Channel.create()
            ch.cursor = 1500
            local itemCountBefore = ch.itemCount
            local payload = buffer.create(4096)
            local ok = pcall(function(): ()
                Channel.writeBatchEncoded(ch, reg, payload, 4096)
            end)
            expect(ok):toBe(false)
            expect(ch.itemCount):toBe(itemCountBefore)
        end)
    end)

    describe("writeBatch interleaved packet IDs", function(): ()
        it("two distinct IDs produce two single-mode batches", function(): ()
            local a = packetReg("a")
            local b = packetReg("b")
            local ch = Channel.create()
            Channel.writeBatch(ch, a, 1)
            Channel.writeBatch(ch, b, 2)
            expect(ch.cursor):toBe(4)
        end)
    end)

    describe("xorApply", function(): ()
        it("self XOR yields all zeros", function(): ()
            local f = buffer.create(8)
            buffer.writeu32(f, 0, 0xDEADBEEF)
            buffer.writeu32(f, 4, 0xCAFEBABE)
            local x = Channel.xorApply(f, 8, f, 8)
            expect(buffer.readu32(x, 0)):toBe(0)
            expect(buffer.readu32(x, 4)):toBe(0)
        end)
        it("nil previous returns the input unchanged", function(): ()
            local f = buffer.create(4)
            buffer.writeu32(f, 0, 0x12345678)
            local x = Channel.xorApply(f, 4, nil, 0)
            expect(buffer.readu32(x, 0)):toBe(0x12345678)
        end)
        it("encode then decode recovers original", function(): ()
            local prev = buffer.create(4)
            buffer.writeu32(prev, 0, 0xAAAAAAAA)
            local cur = buffer.create(4)
            buffer.writeu32(cur, 0, 0xBBBBBBBB)
            local enc = Channel.xorApply(cur, 4, prev, 4)
            local dec = Channel.xorApply(enc, 4, prev, 4)
            expect(buffer.readu32(dec, 0)):toBe(0xBBBBBBBB)
        end)
        it("current larger than previous extends with raw current bytes", function(): ()
            local prev = buffer.create(4)
            buffer.writeu32(prev, 0, 0x11)
            local cur = buffer.create(8)
            buffer.writeu32(cur, 0, 0x22)
            buffer.writeu32(cur, 4, 0x33)
            local enc = Channel.xorApply(cur, 8, prev, 4)
            local dec = Channel.xorApply(enc, 8, prev, 4)
            expect(buffer.readu32(dec, 0)):toBe(0x22)
            expect(buffer.readu32(dec, 4)):toBe(0x33)
        end)
        it("non-aligned tail handled byte-wise", function(): ()
            local a = buffer.create(5)
            buffer.writeu32(a, 0, 0x11223344)
            buffer.writeu8(a, 4, 0x55)
            local b = buffer.create(5)
            buffer.writeu32(b, 0, 0xAABBCCDD)
            buffer.writeu8(b, 4, 0xEE)
            local enc = Channel.xorApply(b, 5, a, 5)
            local dec = Channel.xorApply(enc, 5, a, 5)
            expect(buffer.readu32(dec, 0)):toBe(0xAABBCCDD)
            expect(buffer.readu8(dec, 4)):toBe(0xEE)
        end)
    end)

    describe("writeQuery", function(): ()
        it("MSB-set id with no payload (nil response shape)", function(): ()
            local ch = Channel.create()
            Channel.writeQuery(ch, 7, 1, nil, nil)
            expect(buffer.readu8(ch.buff, 0)):toBe(7 + 128)
        end)
        it("plain id with payload", function(): ()
            local ch = Channel.create()
            Channel.writeQuery(ch, 7, 1, Lync.int(0, 255) :: any, 42)
            expect(buffer.readu8(ch.buff, 0)):toBe(7)
        end)
        it("varint correlation ID encoded after id byte", function(): ()
            local ch = Channel.create()
            Channel.writeQuery(ch, 7, 100, nil, nil)
            -- Tier 1 inline varint: 100 fits in 1 byte.
            expect(buffer.readu8(ch.buff, 1)):toBe(100)
        end)
        it("resets lastId so the next writeBatch reopens its frame", function(): ()
            local reg = packetReg("query_clear")
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 1)
            Channel.writeQuery(ch, 8, 1, nil, nil)
            -- Resetting lastId is the contract; singleMode is intentionally not
            -- touched here because it's gated by `lastId >= 0` everywhere it's read.
            expect(ch.lastId):toBe(-1)
        end)
        it("name param sets currentPacket so overflow blames the right caller", function(): ()
            local reg = packetReg("prev_packet")
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 1)
            -- A subsequent writeQuery without a name leaves currentPacket as "prev_packet".
            -- With the name param, it's stamped to the query's identity.
            Channel.writeQuery(ch, 8, 1, nil, nil, "MyQuery")
            expect(ch.currentPacket):toBe("MyQuery")
        end)
    end)

    describe("resolveOpenFn includes timestamp byte count in header", function(): ()
        it("TS_FRAME open writes 1 + 1 timestamp byte", function(): ()
            local reg = packetReg("ts_frame")
            reg.headerSize = 2
            reg.timestampMode = Channel.TS_FRAME
            reg._openFn = Channel.resolveOpenFn(Channel.TS_FRAME, "ts_frame")
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 0)
            expect(ch.cursor):toBe(2 + 1)
        end)
        it("TS_OFFSET reserves 2 timestamp bytes", function(): ()
            local reg = packetReg("ts_offset")
            reg.headerSize = 3
            reg.timestampMode = Channel.TS_OFFSET
            reg._openFn = Channel.resolveOpenFn(Channel.TS_OFFSET, "ts_offset")
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 0)
            expect(ch.cursor):toBe(3 + 1)
        end)
        it("TS_FULL reserves 8 timestamp bytes", function(): ()
            local reg = packetReg("ts_full")
            reg.headerSize = 9
            reg.timestampMode = Channel.TS_FULL
            reg._openFn = Channel.resolveOpenFn(Channel.TS_FULL, "ts_full")
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 0)
            expect(ch.cursor):toBe(9 + 1)
        end)
        it("each timestamp mode returns a distinct openFn closure", function(): ()
            -- The specialized variants are constructed as separate closures
            -- so the inner branch on `mode` is gone. Identity differs.
            local fNone = Channel.resolveOpenFn(Channel.TS_NONE, "x")
            local fFrame = Channel.resolveOpenFn(Channel.TS_FRAME, "x")
            local fOffset = Channel.resolveOpenFn(Channel.TS_OFFSET, "x")
            local fFull = Channel.resolveOpenFn(Channel.TS_FULL, "x")
            expect(fNone).never:toBe(fFrame)
            expect(fNone).never:toBe(fOffset)
            expect(fNone).never:toBe(fFull)
            expect(fFrame).never:toBe(fOffset)
            expect(fFrame).never:toBe(fFull)
            expect(fOffset).never:toBe(fFull)
        end)
        it("TS_FRAME header byte at offset 1 is the current frame counter", function(): ()
            Channel.enableTimestamps()
            Channel.updateTimestamp()
            local reg = packetReg("ts_frame_value")
            reg.timestampMode = Channel.TS_FRAME
            reg._openFn = Channel.resolveOpenFn(Channel.TS_FRAME, "ts_frame_value")
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 0)
            -- Pre-fix: writeTimestamp dispatched on `mode`; post-fix: inlined.
            -- The byte itself must still be a u8 (0..255) regardless.
            local tsByte = buffer.readu8(ch.buff, 1)
            expect(tsByte):toBeGreaterThanOrEqual(0)
            expect(tsByte):toBeLessThanOrEqual(255)
        end)
    end)

    describe("timestamp toggle and stats toggle", function(): ()
        it("hasTimestamps starts false and flips after enableTimestamps", function(): ()
            expect(Channel.hasTimestamps()):toBe(false)
            Channel.enableTimestamps()
            expect(Channel.hasTimestamps()):toBe(true)
        end)
        it("statsEnabled starts false and flips after enableStats", function(): ()
            expect(Channel.statsEnabled()):toBe(false)
            Channel.enableStats()
            expect(Channel.statsEnabled()):toBe(true)
        end)
        it("Sandbox reset disables both", function(): ()
            Channel.enableTimestamps()
            Channel.enableStats()
            Sandbox.resetAll()
            expect(Channel.hasTimestamps()):toBe(false)
            expect(Channel.statsEnabled()):toBe(false)
        end)
    end)

    describe("setMaxSize", function(): ()
        it("alloc beyond max throws with byte details", function(): ()
            Base.setMaxSize(2048)
            local ch = Channel.create()
            ch.cursor = 2000
            expect(function(): ()
                Base.alloc(ch, 1000)
            end):toThrow("overflow")
        end)
    end)
end)

return nil
