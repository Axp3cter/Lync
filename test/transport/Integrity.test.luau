--!strict
--!optimize 2
-- Full transport pipeline fidelity.

local Baseline = require (script.Parent.Parent.Parent.core.Baseline)
local Channel = require (script.Parent.Parent.Parent.core.Channel)
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)

local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

-- Helpers ----------------------------------------------------------------

local function buffersEqual (a: buffer, b: buffer): boolean
    local len = buffer.len (a)
    if len ~= buffer.len (b) then
        return false
    end
    for i = 0, len - 1 do
        if buffer.readu8 (a, i) ~= buffer.readu8 (b, i) then
            return false
        end
    end
    return true
end

-- Full pipeline: codec write → channel batch → seal → dump → XOR → unXOR → codec read
local function pipelineRoundTrip (codec: any, data: any, prevDump: buffer?): (any, buffer)
    local ch = Channel.create ()
    Channel.writeBatch (ch, 1, codec, data)

    local raw, refs = Channel.sealAndDump (ch)
    local xored = Channel.xorApply (raw, prevDump)

    -- Reverse
    local restored = Channel.xorApply (xored, prevDump)

    -- Parse batch header: 1 byte id + 2 byte count + payload
    local id = buffer.readu8 (restored, 0)
    local count = buffer.readu16 (restored, 1)
    local value, consumed = codec.read (restored, 3, refs)

    return value, raw
end

-- XOR apply + reverse
local function xorRoundTrip (data: buffer, prev: buffer?): buffer
    local xored = Channel.xorApply (data, prev)
    local restored = Channel.xorApply (xored, prev)
    return restored
end

-- Tests ------------------------------------------------------------------

describe ("Pipeline: primitive fidelity", function (): ()
    it ("u8 max survives full pipeline", function (): ()
        local result = pipelineRoundTrip (Lync.u8, 255, nil)
        expect (result):toBe (255)
    end)
    it ("u32 max survives full pipeline", function (): ()
        local result = pipelineRoundTrip (Lync.u32, 4294967295, nil)
        expect (result):toBe (4294967295)
    end)
    it ("i32 min survives full pipeline", function (): ()
        local result = pipelineRoundTrip (Lync.i32, -2147483648, nil)
        expect (result):toBe (-2147483648)
    end)
    it ("f64 pi survives full pipeline", function (): ()
        local result = pipelineRoundTrip (Lync.f64, math.pi, nil)
        expect (result):toBe (math.pi)
    end)
    it ("f32 preserves precision through pipeline", function (): ()
        local result = pipelineRoundTrip (Lync.f32, 1.5, nil)
        expect (result):toBeCloseTo (1.5)
    end)
    it ("bool true survives full pipeline", function (): ()
        local result = pipelineRoundTrip (Lync.bool, true, nil)
        expect (result):toBe (true)
    end)
    it ("bool false survives full pipeline", function (): ()
        local result = pipelineRoundTrip (Lync.bool, false, nil)
        expect (result):toBe (false)
    end)
end)

describe ("Pipeline: complex types", function (): ()
    it ("string survives full pipeline", function (): ()
        local result = pipelineRoundTrip (Lync.string, "hello world", nil)
        expect (result):toBe ("hello world")
    end)
    it ("empty string survives full pipeline", function (): ()
        local result = pipelineRoundTrip (Lync.string, "", nil)
        expect (result):toBe ("")
    end)
    it ("UTF-8 survives full pipeline", function (): ()
        local result = pipelineRoundTrip (Lync.string, "日本語テスト", nil)
        expect (result):toBe ("日本語テスト")
    end)
    it ("Vector3 survives full pipeline", function (): ()
        local result = pipelineRoundTrip (Lync.vec3, Vector3.new (1.5, -2.5, 3.5), nil)
        expect (result.X):toBeCloseTo (1.5)
        expect (result.Y):toBeCloseTo (-2.5)
        expect (result.Z):toBeCloseTo (3.5)
    end)
    it ("CFrame survives full pipeline", function (): ()
        local orig = CFrame.new (10, 20, 30) * CFrame.Angles (math.pi / 4, 0, 0)
        local result = pipelineRoundTrip (Lync.cframe, orig, nil)
        expect (result.Position.X):toBeCloseTo (10, 0.01)
        expect (result.Position.Y):toBeCloseTo (20, 0.01)
        expect (result.Position.Z):toBeCloseTo (30, 0.01)
    end)
    it ("Color3 survives full pipeline", function (): ()
        local result = pipelineRoundTrip (Lync.color3, Color3.fromRGB (128, 64, 200), nil)
        expect (result.R):toBeCloseTo (128 / 255, 1 / 255)
        expect (result.G):toBeCloseTo (64 / 255, 1 / 255)
        expect (result.B):toBeCloseTo (200 / 255, 1 / 255)
    end)
    it ("buffer survives full pipeline", function (): ()
        local input = buffer.create (8)
        buffer.writef64 (input, 0, math.pi)
        local result = pipelineRoundTrip (Lync.buff, input, nil)
        expect (buffer.len (result)):toBe (8)
        expect (buffer.readf64 (result, 0)):toBe (math.pi)
    end)
end)

describe ("Pipeline: struct fidelity", function (): ()
    local codec = Lync.struct ({
        position = Lync.vec3,
        velocity = Lync.vec3,
        health = Lync.f32,
        shield = Lync.f32,
        alive = Lync.bool,
        team = Lync.u8,
    })

    it ("entity struct survives full pipeline", function (): ()
        local input = {
            position = Vector3.new (100.5, 50.25, -200.75),
            velocity = Vector3.new (10.1, 0, -5.3),
            health = 87.5,
            shield = 42.0,
            alive = true,
            team = 2,
        }
        local result = pipelineRoundTrip (codec, input, nil)
        expect (result.position.X):toBeCloseTo (100.5)
        expect (result.position.Y):toBeCloseTo (50.25)
        expect (result.position.Z):toBeCloseTo (-200.75)
        expect (result.velocity.X):toBeCloseTo (10.1, 0.01)
        expect (result.velocity.Y):toBeCloseTo (0)
        expect (result.velocity.Z):toBeCloseTo (-5.3, 0.01)
        expect (result.health):toBeCloseTo (87.5)
        expect (result.shield):toBeCloseTo (42.0)
        expect (result.alive):toBe (true)
        expect (result.team):toBe (2)
    end)
end)

describe ("Pipeline: XOR frame-to-frame", function (): ()
    local codec = Lync.struct ({ x = Lync.f32, y = Lync.f32 })

    it ("second frame XOR'd against first recovers exact data", function (): ()
        local _, prevDump = pipelineRoundTrip (codec, { x = 1.0, y = 2.0 }, nil)
        local result = pipelineRoundTrip (codec, { x = 3.0, y = 4.0 }, prevDump)
        expect (result.x):toBeCloseTo (3.0)
        expect (result.y):toBeCloseTo (4.0)
    end)
    it ("identical frame XOR produces near-zero bytes", function (): ()
        local ch = Channel.create ()
        Lync.struct ({ v = Lync.u32 }).write (ch, { v = 12345 })
        local raw = buffer.create (ch.cursor)
        buffer.copy (raw, 0, ch.buff, 0, ch.cursor)

        local xored = Channel.xorApply (raw, raw)
        local allZero = true
        for i = 0, buffer.len (xored) - 1 do
            if buffer.readu8 (xored, i) ~= 0 then
                allZero = false
                break
            end
        end
        expect (allZero):toBe (true)
    end)
end)

describe ("Pipeline: XOR bit-exact round-trip", function (): ()
    it ("XOR apply then reverse is bit-exact", function (): ()
        local data = buffer.create (32)
        for i = 0, 31 do
            buffer.writeu8 (data, i, (i * 37 + 13) % 256)
        end

        local prev = buffer.create (32)
        for i = 0, 31 do
            buffer.writeu8 (prev, i, (i * 71 + 5) % 256)
        end

        local restored = xorRoundTrip (data, prev)
        expect (buffersEqual (restored, data)):toBe (true)
    end)
    it ("XOR with nil previous returns original", function (): ()
        local data = buffer.create (16)
        for i = 0, 15 do
            buffer.writeu8 (data, i, i)
        end

        local restored = xorRoundTrip (data, nil)
        expect (buffersEqual (restored, data)):toBe (true)
    end)
    it ("XOR with shorter previous preserves tail", function (): ()
        local data = buffer.create (8)
        local prev = buffer.create (4)
        for i = 0, 7 do
            buffer.writeu8 (data, i, 0xAA)
        end
        for i = 0, 3 do
            buffer.writeu8 (prev, i, 0xAA)
        end

        local restored = xorRoundTrip (data, prev)
        expect (buffersEqual (restored, data)):toBe (true)
    end)
end)

describe ("Pipeline: multi-codec batch ordering", function (): ()
    it ("writes and reads multiple codecs from one channel in order", function (): ()
        local ch = Channel.create ()

        -- Write 3 different messages as separate batches
        Channel.writeBatch (ch, 1, Lync.u32, 12345)
        Channel.sealAndDump (ch)
        Channel.writeBatch (ch, 2, Lync.string, "hello")
        Channel.sealAndDump (ch)
        Channel.writeBatch (ch, 3, Lync.bool, true)
        Channel.sealAndDump (ch)

        local raw = buffer.create (ch.cursor)
        buffer.copy (raw, 0, ch.buff, 0, ch.cursor)

        -- Parse manually: each batch = 1 id + 2 count + payload
        local pos = 0

        -- Batch 1: u32
        local id1 = buffer.readu8 (raw, pos)
        pos += 1
        local count1 = buffer.readu16 (raw, pos)
        pos += 2
        local val1 = buffer.readu32 (raw, pos)
        pos += 4
        expect (id1):toBe (1)
        expect (count1):toBe (1)
        expect (val1):toBe (12345)

        -- Batch 2: string (varint len + bytes)
        local id2 = buffer.readu8 (raw, pos)
        pos += 1
        local count2 = buffer.readu16 (raw, pos)
        pos += 2
        local sLen = buffer.readu8 (raw, pos)
        pos += 1
        local sVal = buffer.readstring (raw, pos, sLen)
        pos += sLen
        expect (id2):toBe (2)
        expect (count2):toBe (1)
        expect (sVal):toBe ("hello")

        -- Batch 3: bool
        local id3 = buffer.readu8 (raw, pos)
        pos += 1
        local count3 = buffer.readu16 (raw, pos)
        pos += 2
        local bVal = buffer.readu8 (raw, pos)
        pos += 1
        expect (id3):toBe (3)
        expect (count3):toBe (1)
        expect (bVal ~= 0):toBe (true)
    end)
end)

describe ("Pipeline: same-id batch coalescing", function (): ()
    it ("multiple writes to same id share one header", function (): ()
        local ch = Channel.create ()
        Channel.writeBatch (ch, 5, Lync.u8, 10)
        Channel.writeBatch (ch, 5, Lync.u8, 20)
        Channel.writeBatch (ch, 5, Lync.u8, 30)
        Channel.sealAndDump (ch)

        local raw = buffer.create (ch.cursor)
        buffer.copy (raw, 0, ch.buff, 0, ch.cursor)

        -- Should be: 1 id + 2 count + 3 × 1 byte = 6 bytes total
        expect (ch.cursor):toBe (6)
        expect (buffer.readu8 (raw, 0)):toBe (5)
        expect (buffer.readu16 (raw, 1)):toBe (3)
        expect (buffer.readu8 (raw, 3)):toBe (10)
        expect (buffer.readu8 (raw, 4)):toBe (20)
        expect (buffer.readu8 (raw, 5)):toBe (30)
    end)
end)

describe ("Pipeline: Instance ref ordering", function (): ()
    it ("preserves ref order through batch", function (): ()
        local partA = Instance.new ("Part")
        local partB = Instance.new ("Part")
        local partC = Instance.new ("Part")

        local ch = Channel.create ()
        Lync.inst.write (ch, partA)
        Lync.inst.write (ch, partB)
        Lync.inst.write (ch, partC)

        local buf = buffer.create (ch.cursor)
        buffer.copy (buf, 0, ch.buff, 0, ch.cursor)

        local r1, n1 = Lync.inst.read (buf, 0, ch.refs)
        local r2, n2 = Lync.inst.read (buf, n1, ch.refs)
        local r3, _ = Lync.inst.read (buf, n1 + n2, ch.refs)
        expect (r1):toBe (partA)
        expect (r2):toBe (partB)
        expect (r3):toBe (partC)

        partA:Destroy ()
        partB:Destroy ()
        partC:Destroy ()
    end)
end)

describe ("Delta struct multi-step fidelity", function (): ()
    local codec = Lync.deltaStruct ({ hp = Lync.u16, mp = Lync.u16, alive = Lync.bool })

    it ("full → unchanged → delta → full cycle preserves data", function (): ()
        Baseline.setReadKey ("__integrity_delta")

        local ch = Channel.create ()

        -- Step 1: first write (full snapshot)
        local dataA = { hp = 100, mp = 50, alive = true }
        codec.write (ch, dataA)
        local buf1 = buffer.create (ch.cursor)
        buffer.copy (buf1, 0, ch.buff, 0, ch.cursor)
        local readA = codec.read (buf1, 0, nil)
        expect (readA.hp):toBe (100)
        expect (readA.mp):toBe (50)
        expect (readA.alive):toBe (true)

        -- Step 2: unchanged write
        local pos2 = ch.cursor
        codec.write (ch, dataA)
        local buf2 = buffer.create (ch.cursor - pos2)
        buffer.copy (buf2, 0, ch.buff, pos2, ch.cursor - pos2)
        local readB = codec.read (buf2, 0, nil)
        expect (readB.hp):toBe (100)
        expect (readB.mp):toBe (50)
        expect (readB.alive):toBe (true)

        -- Step 3: partial change (delta)
        local pos3 = ch.cursor
        local dataC = { hp = 80, mp = 50, alive = true }
        codec.write (ch, dataC)
        local buf3 = buffer.create (ch.cursor - pos3)
        buffer.copy (buf3, 0, ch.buff, pos3, ch.cursor - pos3)
        local readC = codec.read (buf3, 0, nil)
        expect (readC.hp):toBe (80)
        expect (readC.mp):toBe (50)
        expect (readC.alive):toBe (true)

        -- Step 4: change everything
        local pos4 = ch.cursor
        local dataD = { hp = 0, mp = 0, alive = false }
        codec.write (ch, dataD)
        local buf4 = buffer.create (ch.cursor - pos4)
        buffer.copy (buf4, 0, ch.buff, pos4, ch.cursor - pos4)
        local readD = codec.read (buf4, 0, nil)
        expect (readD.hp):toBe (0)
        expect (readD.mp):toBe (0)
        expect (readD.alive):toBe (false)

        Baseline.clearSource ("__integrity_delta")
    end)
end)

describe ("Delta array multi-step fidelity", function (): ()
    local codec = Lync.deltaArray (Lync.u16)

    it ("full → unchanged → element change → length change", function (): ()
        Baseline.setReadKey ("__integrity_darr")

        local ch = Channel.create ()

        -- Step 1: full
        local arrA = { 10, 20, 30 }
        codec.write (ch, arrA)
        local buf1 = buffer.create (ch.cursor)
        buffer.copy (buf1, 0, ch.buff, 0, ch.cursor)
        local readA = codec.read (buf1, 0, nil)
        expect (readA[1]):toBe (10)
        expect (readA[2]):toBe (20)
        expect (readA[3]):toBe (30)

        -- Step 2: unchanged
        local pos2 = ch.cursor
        codec.write (ch, arrA)
        local buf2 = buffer.create (ch.cursor - pos2)
        buffer.copy (buf2, 0, ch.buff, pos2, ch.cursor - pos2)
        local readB = codec.read (buf2, 0, nil)
        expect (readB[1]):toBe (10)
        expect (readB[2]):toBe (20)
        expect (readB[3]):toBe (30)

        -- Step 3: change middle element
        local pos3 = ch.cursor
        codec.write (ch, { 10, 99, 30 })
        local buf3 = buffer.create (ch.cursor - pos3)
        buffer.copy (buf3, 0, ch.buff, pos3, ch.cursor - pos3)
        local readC = codec.read (buf3, 0, nil)
        expect (readC[1]):toBe (10)
        expect (readC[2]):toBe (99)
        expect (readC[3]):toBe (30)

        -- Step 4: change length (triggers full resend)
        local pos4 = ch.cursor
        codec.write (ch, { 1, 2 })
        local buf4 = buffer.create (ch.cursor - pos4)
        buffer.copy (buf4, 0, ch.buff, pos4, ch.cursor - pos4)
        local readD = codec.read (buf4, 0, nil)
        expect (#readD):toBe (2)
        expect (readD[1]):toBe (1)
        expect (readD[2]):toBe (2)

        Baseline.clearSource ("__integrity_darr")
    end)
end)

describe ("Edge value fidelity", function (): ()
    it ("zero-length string through pipeline", function (): ()
        expect (pipelineRoundTrip (Lync.string, "", nil)):toBe ("")
    end)
    it ("1000-char string through pipeline", function (): ()
        local long = string.rep ("x", 1000)
        expect (pipelineRoundTrip (Lync.string, long, nil)):toBe (long)
    end)
    it ("string with null bytes through pipeline", function (): ()
        local s = "a\0b\0c"
        expect (pipelineRoundTrip (Lync.string, s, nil)):toBe (s)
    end)
    it ("f16 precision through pipeline", function (): ()
        local result = pipelineRoundTrip (Lync.f16, 3.14, nil)
        expect (result):toBeCloseTo (3.14, 0.01)
    end)
    it ("empty array through pipeline", function (): ()
        local result = pipelineRoundTrip (Lync.array (Lync.u8), {}, nil)
        expect (#result):toBe (0)
    end)
    it ("100-element array through pipeline", function (): ()
        local input = table.create (100)
        for i = 1, 100 do
            input[i] = i
        end
        local result = pipelineRoundTrip (Lync.array (Lync.u16), input, nil)
        expect (#result):toBe (100)
        expect (result[1]):toBe (1)
        expect (result[50]):toBe (50)
        expect (result[100]):toBe (100)
    end)
    it ("empty map through pipeline", function (): ()
        local result = pipelineRoundTrip (Lync.map (Lync.string, Lync.u8), {}, nil)
        local n = 0
        for _ in result do
            n += 1
        end
        expect (n):toBe (0)
    end)
    it ("optional nil through pipeline", function (): ()
        expect (pipelineRoundTrip (Lync.optional (Lync.u32), nil, nil)):toBeNil ()
    end)
    it ("optional present through pipeline", function (): ()
        expect (pipelineRoundTrip (Lync.optional (Lync.u32), 42, nil)):toBe (42)
    end)
    it ("nested struct through pipeline", function (): ()
        local codec = Lync.struct ({
            inner = Lync.struct ({ a = Lync.u8, b = Lync.u8 }),
            tag = Lync.string,
        })
        local result = pipelineRoundTrip (codec, { inner = { a = 1, b = 2 }, tag = "ok" }, nil)
        expect (result.inner.a):toBe (1)
        expect (result.inner.b):toBe (2)
        expect (result.tag):toBe ("ok")
    end)
end)

describe ("Quantized precision guarantee", function (): ()
    it ("float stays within declared precision after round-trip", function (): ()
        local precision = 0.1
        local codec = Lync.quantizedFloat (0, 100, precision)

        for _, v in { 0, 0.05, 1, 25, 50, 75, 99.9, 100 } do
            local result = roundTrip (codec, v)
            local diff = math.abs (result - math.clamp (v, 0, 100))
            expect (diff <= precision):toBe (true)
        end
    end)
    it ("vec3 stays within declared precision after round-trip", function (): ()
        local precision = 0.5
        local codec = Lync.quantizedVec3 (-100, 100, precision)
        local input = Vector3.new (33.3, -77.7, 0.1)
        local result = roundTrip (codec, input)
        expect (math.abs (result.X - 33.3) <= precision):toBe (true)
        expect (math.abs (result.Y - -77.7) <= precision):toBe (true)
        expect (math.abs (result.Z - 0.1) <= precision):toBe (true)
    end)
end)

describe ("Enum fidelity under pipeline", function (): ()
    local codec = Lync.enum ("idle", "walking", "running", "dead")

    it ("all variants survive pipeline", function (): ()
        for _, v in { "idle", "walking", "running", "dead" } do
            expect (pipelineRoundTrip (codec, v, nil)):toBe (v)
        end
    end)
end)

describe ("Tagged fidelity under pipeline", function (): ()
    local codec = Lync.tagged ("type", {
        move = Lync.struct ({ type = Lync.string, x = Lync.f32, y = Lync.f32 }),
        chat = Lync.struct ({ type = Lync.string, msg = Lync.string }),
    })

    it ("move variant survives pipeline", function (): ()
        local r = pipelineRoundTrip (codec, { type = "move", x = 1.5, y = -2.5 }, nil)
        expect (r.type):toBe ("move")
        expect (r.x):toBeCloseTo (1.5)
        expect (r.y):toBeCloseTo (-2.5)
    end)
    it ("chat variant survives pipeline", function (): ()
        local r = pipelineRoundTrip (codec, { type = "chat", msg = "hello" }, nil)
        expect (r.type):toBe ("chat")
        expect (r.msg):toBe ("hello")
    end)
end)

describe ("Bitfield fidelity under pipeline", function (): ()
    local codec = Lync.bitfield ({
        alive = { type = "bool" },
        visible = { type = "bool" },
        level = { type = "uint", width = 5 },
    })

    it ("survives full pipeline", function (): ()
        local r = pipelineRoundTrip (codec, { alive = true, visible = false, level = 31 }, nil)
        expect (r.alive):toBe (true)
        expect (r.visible):toBe (false)
        expect (r.level):toBe (31)
    end)
end)

describe ("Signed bitfield fidelity under pipeline", function (): ()
    local codec = Lync.bitfield ({
        alive = { type = "bool" },
        delta = { type = "int", width = 5 },
        team = { type = "uint", width = 3 },
    })

    it ("positive signed survives pipeline", function (): ()
        local r = pipelineRoundTrip (codec, { alive = true, delta = 15, team = 7 }, nil)
        expect (r.alive):toBe (true)
        expect (r.delta):toBe (15)
        expect (r.team):toBe (7)
    end)
    it ("negative signed survives pipeline", function (): ()
        local r = pipelineRoundTrip (codec, { alive = false, delta = -16, team = 0 }, nil)
        expect (r.alive):toBe (false)
        expect (r.delta):toBe (-16)
        expect (r.team):toBe (0)
    end)
    it ("zero signed survives pipeline", function (): ()
        local r = pipelineRoundTrip (codec, { alive = true, delta = 0, team = 3 }, nil)
        expect (r.delta):toBe (0)
    end)
end)

describe ("Pipeline: query frame with status byte", function (): ()
    it ("status 0 + payload round-trips through channel", function (): ()
        local ch = Channel.create ()
        Channel.writeQuery (ch, 1, 42, Lync.u32, 12345)

        local raw = buffer.create (ch.cursor)
        buffer.copy (raw, 0, ch.buff, 0, ch.cursor)

        -- Parse: id(1) + correlation(2) + status(1) + u32(4) = 8
        expect (ch.cursor):toBe (8)
        expect (buffer.readu8 (raw, 0)):toBe (1)
        expect (buffer.readu16 (raw, 1)):toBe (42)
        expect (buffer.readu8 (raw, 3)):toBe (0)
        expect (buffer.readu32 (raw, 4)):toBe (12345)
    end)
    it ("status 1 (nil) is exactly 4 bytes", function (): ()
        local ch = Channel.create ()
        Channel.writeQuery (ch, 5, 99, nil, nil)

        expect (ch.cursor):toBe (4)
        expect (buffer.readu8 (ch.buff, 0)):toBe (5)
        expect (buffer.readu16 (ch.buff, 1)):toBe (99)
        expect (buffer.readu8 (ch.buff, 3)):toBe (1)
    end)
    it ("large correlationId round-trips", function (): ()
        local ch = Channel.create ()
        Channel.writeQuery (ch, 1, 60000, nil, nil)

        expect (buffer.readu16 (ch.buff, 1)):toBe (60000)
    end)
    it ("mixed batch + query + nil query in one channel", function (): ()
        local ch = Channel.create ()

        -- Batch
        Channel.writeBatch (ch, 1, Lync.u8, 42)
        Channel.sealAndDump (ch)
        local afterBatch = ch.cursor

        -- Query with payload: id(1) + corr(2) + status(1) + u8(1) = 5
        Channel.writeQuery (ch, 2, 10, Lync.u8, 99)
        local afterQuery = ch.cursor
        expect (afterQuery - afterBatch):toBe (5)

        -- Nil query: id(1) + corr(2) + status(1) = 4
        Channel.writeQuery (ch, 3, 20, nil, nil)
        expect (ch.cursor - afterQuery):toBe (4)
    end)
end)

describe ("Pipeline: XOR with query frames", function (): ()
    it ("query frame XOR'd against nil previous recovers", function (): ()
        local ch = Channel.create ()
        Channel.writeQuery (ch, 1, 0, Lync.f32, 3.14)

        local raw = buffer.create (ch.cursor)
        buffer.copy (raw, 0, ch.buff, 0, ch.cursor)

        local xored = Channel.xorApply (raw, nil)
        expect (buffersEqual (xored, raw)):toBe (true)
    end)
    it ("identical query frames XOR to zero", function (): ()
        local ch1 = Channel.create ()
        local ch2 = Channel.create ()
        Channel.writeQuery (ch1, 1, 5, Lync.u16, 1000)
        Channel.writeQuery (ch2, 1, 5, Lync.u16, 1000)

        local raw1 = buffer.create (ch1.cursor)
        buffer.copy (raw1, 0, ch1.buff, 0, ch1.cursor)
        local raw2 = buffer.create (ch2.cursor)
        buffer.copy (raw2, 0, ch2.buff, 0, ch2.cursor)

        local xored = Channel.xorApply (raw2, raw1)
        local allZero = true
        for i = 0, buffer.len (xored) - 1 do
            if buffer.readu8 (xored, i) ~= 0 then
                allZero = false
                break
            end
        end
        expect (allZero):toBe (true)
    end)
end)

return nil
