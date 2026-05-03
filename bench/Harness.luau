--!strict
--!optimize 2
-- Bench harness: round-trip CPU + network throughput.

local Channel = require(script.Parent.Parent.internal.Channel)

local RT_ITERS = 1000
local LABEL_W = 28

local clock = os.clock
local floor = math.floor
local sort = table.sort
local maxN = math.max
local minN = math.min
local format = string.format
local utf8len = utf8.len

local function pct(sorted: { number }, p: number): number
    local i = floor(#sorted * p / 100 + 0.5)
    return sorted[maxN(1, minN(i, #sorted))]
end

local function round1(n: number): number
    return floor(n * 10 + 0.5) / 10
end

local function fmtNum(n: number): string
    local s = tostring(floor(n))
    if #s <= 3 then
        return s
    end
    local out, rem = {}, #s % 3
    if rem > 0 then
        table.insert(out, s:sub(1, rem))
    end
    for i = rem + 1, #s, 3 do
        table.insert(out, s:sub(i, i + 2))
    end
    return table.concat(out, ",")
end

local function fmtTime(us: number): string
    if us < 1 then
        return `{floor(us * 1000 + 0.5)}ns`
    end
    if us < 1000 then
        return `{round1(us)}us`
    end
    return `{round1(us / 1000)}ms`
end

local Harness = {}

Harness.fmtNum = fmtNum
Harness.fmtTime = fmtTime

function Harness.header(title: string): ()
    local bar = string.rep("=", 64)
    print(bar)
    print(string.rep(" ", maxN(0, (64 - #title) // 2)) .. title)
    print(bar)
end

function Harness.section(title: string): ()
    print(title)
end

--[[
    UTF-8-aware row print. `string.format("%-Ns", ...)` pads to N BYTES,
    so labels with multi-byte characters end up visually short. Pad by
    visible character count via utf8.len.
]]
function Harness.row(label: string, value: string): ()
    local visible = utf8len(label) or #label
    local pad = string.rep(" ", maxN(0, LABEL_W - visible))
    print("  " .. label .. pad .. " " .. value)
end

function Harness.wireSize(label: string, codec: any, value: any): ()
    local ch = Channel.create()
    codec.write(ch, value)
    Harness.row(label, format("%dB", ch.cursor))
end

-- Per-field delta size: prime cache with SEED, then encode VALUE.
function Harness.deltaSize(label: string, codec: any, seed: any, value: any): ()
    local ch = Channel.create()
    codec.write(ch, seed)
    ch.cursor = 0
    codec.write(ch, value)
    Harness.row(label, format("%dB", ch.cursor))
end

-- Codec round-trip: reused channel, ITERS encodes + ITERS decodes.
function Harness.roundTrip(label: string, codec: any, value: any): ()
    local ch = Channel.create()
    codec.write(ch, value)
    local n = ch.cursor
    local buf = buffer.create(n)
    buffer.copy(buf, 0, ch.buff, 0, n)
    local refs = if ch.refCount > 0 then table.clone(ch.refs) else nil

    for _ = 1, RT_ITERS // 10 do
        ch.cursor = 0
        codec.write(ch, value)
        codec.read(buf, 0, refs)
    end

    local t0 = clock()
    for _ = 1, RT_ITERS do
        ch.cursor = 0
        codec.write(ch, value)
    end
    local enc = clock() - t0

    t0 = clock()
    for _ = 1, RT_ITERS do
        codec.read(buf, 0, refs)
    end
    local dec = clock() - t0

    local encUs = enc / RT_ITERS * 1e6
    local decUs = dec / RT_ITERS * 1e6
    Harness.row(
        format("%s (%dB)", label, n),
        format(
            "enc=%-9s dec=%-9s rt/s=%s",
            fmtTime(encUs),
            fmtTime(decUs),
            fmtNum(RT_ITERS / (enc + dec))
        )
    )
end

--[[
    Blink-style throughput: fire `firesPerFrame` per Heartbeat for `seconds`,
    report median FPS and median Kbps. Identical methodology to the Blink
    benchmark suite so cross-library numbers are apples-to-apples.

    Stats.DataSendKbps is what Blink samples too; the unit label matches
    Blink's published table verbatim regardless of what Roblox documents.
]]
function Harness.throughput(
    label: string,
    firesPerFrame: number,
    seconds: number,
    pool: { any },
    send: (any) -> ()
): ()
    local RunService = game:GetService("RunService")
    local Stats = game:GetService("Stats")

    local fps, kbps = {}, {}
    local frames, elapsed = 0, 0
    local n = #pool

    local conn = RunService.Heartbeat:Connect(function(dt)
        frames += 1
        elapsed += dt
        for i = 1, firesPerFrame do
            send(pool[((frames * 105 + i) % n) + 1])
        end
        if elapsed >= 1 then
            table.insert(kbps, Stats.DataSendKbps)
            table.insert(fps, frames)
            frames, elapsed = 0, 0
        end
    end)
    task.wait(seconds)
    conn:Disconnect()

    if #fps == 0 then
        Harness.row(label, "no samples")
        return
    end

    sort(fps)
    sort(kbps)
    Harness.row(
        label,
        format(
            "fps=%-3d  Kbps=%-9s  p95=%s",
            floor(pct(fps, 50) + 0.5),
            format("%.2f", pct(kbps, 50)),
            format("%.2f", pct(kbps, 95))
        )
    )
end

return table.freeze(Harness)
