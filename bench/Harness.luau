--!strict
--!optimize 2
-- Benchmark harness: isolated timing, percentiles, formatted output.

-- Private -------------------------------------------------------------

local clock = os.clock
local floor = math.floor
local sort  = table.sort
local max   = math.max
local min   = math.min

local function percentile(sorted: { number }, p: number): number
    local idx = floor(#sorted * p / 100 + 0.5)
    return sorted[max(1, min(idx, #sorted))]
end

local function fmtNum(n: number): string
    local s = tostring(floor(n))
    local len = #s
    if len <= 3 then return s end
    local parts = {}
    local rem = len % 3
    if rem > 0 then table.insert(parts, s:sub(1, rem)) end
    for i = rem + 1, len, 3 do
        table.insert(parts, s:sub(i, i + 2))
    end
    return table.concat(parts, ",")
end

local function fmtBytes(n: number): string
    if n < 1024 then return `{n}B` end
    if n < 1048576 then return `{floor(n / 1024 * 10 + 0.5) / 10}KB` end
    return `{floor(n / 1048576 * 100 + 0.5) / 100}MB`
end

local function fmtTime(us: number): string
    if us < 1 then return `{floor(us * 1000 + 0.5)}ns` end
    if us < 1000 then return `{floor(us * 10 + 0.5) / 10}µs` end
    return `{floor(us / 1000 * 10 + 0.5) / 10}ms`
end

-- Public --------------------------------------------------------------

local Harness = {}

function Harness.header(title: string): ()
    print("╔══════════════════════════════════════════════════════════════╗")
    print(`║  {title}{string.rep(" ", 60 - #title - 2)}║`)
    print("╚══════════════════════════════════════════════════════════════╝")
end

function Harness.section(title: string): ()
    print(`  ┌ {title}`)
end

function Harness.sectionEnd(): ()
    print("  └")
end

--[[
    Measures isolated encode throughput.
    Runs the function for warmup, then times N iterations.
    Returns ops/sec and mean time in microseconds.
]]
function Harness.benchEncode(
    label: string,
    iterations: number,
    fn: () -> ()
): ()
    -- Warmup
    for _ = 1, min(1000, iterations // 10) do
        fn()
    end

    -- Timed run
    local t0 = clock()
    for _ = 1, iterations do
        fn()
    end
    local elapsed = clock() - t0

    local opsPerSec = iterations / elapsed
    local meanUs = elapsed / iterations * 1e6

    print(`  │  {label}`)
    print(`  │    {fmtNum(floor(opsPerSec))} ops/sec   {fmtTime(meanUs)}/op   ({fmtNum(iterations)} iterations)`)
end

--[[
    Measures wire size for a codec + value pair.
    Writes once and reports exact byte count.
]]
function Harness.benchWireSize(
    label: string,
    codec: any,
    value: any
): number
    local Channel = require(script.Parent.Parent.internal.Channel)
    local ch = Channel.create()
    codec.write(ch, value)
    local bytes = ch.cursor

    print(`  │  {label}: {bytes}B`)
    return bytes
end

--[[
    Measures delta savings: first write vs unchanged second write.
]]
function Harness.benchDelta(
    label: string,
    codec: any,
    value: any
): ()
    local Channel = require(script.Parent.Parent.internal.Channel)
    local ch = Channel.create()

    -- First write (full)
    codec.write(ch, value)
    local fullBytes = ch.cursor

    -- Second write (unchanged)
    ch.cursor = 0
    codec.write(ch, value)
    local unchangedBytes = ch.cursor

    -- Third write (changed — mutate one field if table)
    ch.cursor = 0
    local changed = value
    if typeof(value) == "table" then
        changed = table.clone(value)
        local firstKey = next(changed)
        if firstKey and typeof(changed[firstKey]) == "number" then
            changed[firstKey] += 1
        end
    end
    codec.write(ch, changed)
    local changedBytes = ch.cursor

    local savings = floor((1 - unchangedBytes / fullBytes) * 100 + 0.5)

    print(`  │  {label}`)
    print(`  │    full={fullBytes}B  unchanged={unchangedBytes}B  changed={changedBytes}B  savings={savings}%`)
end

--[[
    Measures full round-trip: encode + decode for a codec.
    Reports encode time, decode time, and total.
]]
function Harness.benchRoundTrip(
    label: string,
    iterations: number,
    codec: any,
    value: any
): ()
    local Channel = require(script.Parent.Parent.internal.Channel)
    local ch = Channel.create()

    -- Pre-encode once to get buffer
    codec.write(ch, value)
    local written = ch.cursor
    local buf = buffer.create(written)
    buffer.copy(buf, 0, ch.buff, 0, written)
    local refs = if ch.refCount > 0 then table.clone(ch.refs) else nil

    -- Warmup
    local warmup = min(1000, iterations // 10)
    for _ = 1, warmup do
        ch.cursor = 0
        codec.write(ch, value)
        codec.read(buf, 0, refs)
    end

    -- Encode timing
    local t0 = clock()
    for _ = 1, iterations do
        ch.cursor = 0
        codec.write(ch, value)
    end
    local encodeTime = clock() - t0

    -- Decode timing
    local t1 = clock()
    for _ = 1, iterations do
        codec.read(buf, 0, refs)
    end
    local decodeTime = clock() - t1

    local encUs = encodeTime / iterations * 1e6
    local decUs = decodeTime / iterations * 1e6
    local totalUs = encUs + decUs

    print(`  │  {label} ({written}B)`)
    print(`  │    encode={fmtTime(encUs)}  decode={fmtTime(decUs)}  total={fmtTime(totalUs)}  {fmtNum(floor(iterations / (encodeTime + decodeTime)))} round-trips/sec`)
end

--[[
    Network throughput bench: fires N packets per frame for duration seconds.
    Reports FPS, Kbps (median/p95), and effective compression ratio.
]]
function Harness.benchNetwork(
    label: string,
    firesPerFrame: number,
    durationSeconds: number,
    packet: any,
    data: any,
    target: Player
): ()
    local RunService = game:GetService("RunService")
    local Stats = game:GetService("Stats")

    -- Settle
    task.wait(2)

    local fpsData: { number } = {}
    local kbpsData: { number } = {}
    local frames = 0
    local elapsed = 0

    local conn = RunService.Heartbeat:Connect(function(dt: number): ()
        for _ = 1, firesPerFrame do
            packet:send(data, target)
        end
        frames += 1
        elapsed += dt
        if elapsed >= 1 then
            table.insert(fpsData, frames / elapsed)
            table.insert(kbpsData, Stats.DataSendKbps)
            frames = 0
            elapsed = 0
        end
    end)

    task.wait(durationSeconds)
    conn:Disconnect()

    sort(fpsData)
    sort(kbpsData)

    local n = #fpsData
    if n == 0 then
        print(`  │  {label}: no samples`)
        return
    end

    local fpsMed = floor(percentile(fpsData, 50) * 10 + 0.5) / 10
    local fpsP1  = floor(percentile(fpsData, 1) * 10 + 0.5) / 10
    local kMed   = floor(percentile(kbpsData, 50) * 10 + 0.5) / 10
    local kP95   = floor(percentile(kbpsData, 95) * 10 + 0.5) / 10
    local kP99   = floor(percentile(kbpsData, 99) * 10 + 0.5) / 10

    print(`  │  {label}`)
    print(`  │    FPS: median={fpsMed}  p1={fpsP1}`)
    print(`  │    Kbps: median={kMed}  p95={kP95}  p99={kP99}`)
    print(`  │    ({n} samples, {firesPerFrame}/frame, {durationSeconds}s)`)
end

--[[
    Outputs FPS and Kbps at the exact percentiles used in the README
    cross-library comparison tables (P0/P80/P90/P95/P100) so results
    can be pasted directly into the Lync rows.
]]
function Harness.benchComparison(
    label: string,
    firesPerFrame: number,
    durationSeconds: number,
    targetFPS: number,
    packet: any,
    data: any,
    target: Player
): ()
    local RunService = game:GetService("RunService")
    local Stats = game:GetService("Stats")

    -- Drain residual traffic before starting
    task.wait(2)
    while Stats.DataSendKbps > 0.5 do
        RunService.Heartbeat:Wait()
    end
    task.wait(2)

    local fpsData: { number }  = {}
    local kbpsData: { number } = {}
    local frames  = 0
    local elapsed = 0
    local sent    = 0

    local conn = RunService.Heartbeat:Connect(function(dt: number): ()
        frames += 1
        elapsed += dt

        for _ = 1, firesPerFrame do
            packet:send(data, target)
            sent += 1
        end

        if elapsed >= 1 then
            -- Scale to target FPS so results are comparable across hardware
            local scale = targetFPS / frames
            table.insert(kbpsData, Stats.DataSendKbps * scale)
            table.insert(fpsData, frames)
            frames = 0
            elapsed -= 1
        end
    end)

    task.wait(durationSeconds)
    conn:Disconnect()

    sort(kbpsData)
    -- FPS sorted descending: P0 = best, P100 = worst
    sort(fpsData, function(a: number, b: number): boolean return a > b end)

    local n = #fpsData
    if n == 0 then
        print(`  │  {label}: no samples`)
        return
    end

    local function p(samples: { number }, pct: number): string
        local idx = max(1, min(floor(#samples * pct / 100), #samples))
        return tostring(floor(samples[idx] * 100 + 0.5) / 100)
    end

    print(`  │  {label}`)
    print(`  │    FPS    │ Median={p(fpsData, 50)} │ P0={p(fpsData, 0)} │ P80={p(fpsData, 80)} │ P90={p(fpsData, 90)} │ P95={p(fpsData, 95)} │ P100={p(fpsData, 100)}`)
    print(`  │    Kbps   │ Median={p(kbpsData, 50)} │ P0={p(kbpsData, 0)} │ P80={p(kbpsData, 80)} │ P90={p(kbpsData, 90)} │ P95={p(kbpsData, 95)} │ P100={p(kbpsData, 100)}`)
    print(`  │    Sent={sent}  Samples={n}`)
end

return table.freeze(Harness)
