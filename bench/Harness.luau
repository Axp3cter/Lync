--!strict
--!optimize 2
-- Benchmark harness with fixed-column output.

local Channel = require(script.Parent.Parent.internal.Channel)

-- Constants --------------------------------------------------------------

local LABEL_WIDTH = 32
local INDENT = "  "

local WARMUP_FRACTION = 10
local WARMUP_CAP = 1000
local SETTLE_SECONDS = 2
local SAMPLE_INTERVAL = 1

--[[
    Iter count for CPU benches is auto-tuned: probe the operation's
    per-call cost, then pick a count that runs for ~MEASURE_BUDGET
    seconds. This makes timings comparable across tests of wildly
    different cost (a 50ns bool encode vs a 50us 100x-entity encode)
    without hand-tuned divisors at every call site.
]]
local PROBE_ITERS = 256
local MEASURE_BUDGET = 0.05 -- seconds
local MIN_ITERS = 1000
local MAX_ITERS = 1000000

-- Column-aligned output formats so every row lines up regardless of
-- label or value content.
local FMT_HEADER = "================================================================"
local HEADER_WIDTH = #FMT_HEADER
local FMT_LABEL_VALUE = "%s%-" .. LABEL_WIDTH .. "s %s"
local FMT_ROW_RT = "%s%-" .. LABEL_WIDTH .. "s enc=%-9s dec=%-9s tot=%-9s rt/s=%s"
local FMT_ROW_ENC = "%s%-" .. LABEL_WIDTH .. "s ops/s=%-12s us/op=%-9s iters=%s"
local FMT_ROW_NET = "%s%-"
    .. LABEL_WIDTH
    .. "s fps_med=%-7s fps_p1=%-7s kbps_med=%-7s kbps_p95=%-7s kbps_p99=%s"
local FMT_ROW_DELTA = "%s%-" .. LABEL_WIDTH .. "s full=%-7s unchanged=%-7s changed=%-7s saved=%s"
local FMT_ROW_COMP = "%s%-"
    .. LABEL_WIDTH
    .. "s %-6s med=%-9s P0=%-9s P80=%-9s P90=%-9s P95=%-9s P100=%s"

-- Private ----------------------------------------------------------------

local clock = os.clock
local floor = math.floor
local sort = table.sort
local maxN = math.max
local minN = math.min
local format = string.format

local function warmupFor(iterations: number): number
    return minN(WARMUP_CAP, iterations // WARMUP_FRACTION)
end

--[[
    Run `fn` PROBE_ITERS times, measure how long it took, and return the
    iter count that fits MEASURE_BUDGET seconds (clamped to a sane range).
    Avoids the random `// 2`, `// 10`, `// 50` divisors at call sites:
    every test gets a similarly-sized budget so timings are comparable.
]]
local function pickIterCount(fn: () -> ()): number
    local t0 = clock()
    for _ = 1, PROBE_ITERS do
        fn()
    end
    local elapsed = clock() - t0
    if elapsed <= 0 then
        return MAX_ITERS
    end
    local target = floor(PROBE_ITERS * MEASURE_BUDGET / elapsed)
    if target < MIN_ITERS then
        return MIN_ITERS
    end
    if target > MAX_ITERS then
        return MAX_ITERS
    end
    return target
end

local function percentile(sorted: { number }, p: number): number
    local idx = floor(#sorted * p / 100 + 0.5)
    return sorted[maxN(1, minN(idx, #sorted))]
end

local function roundTo(value: number, digits: number): number
    local mul = 10 ^ digits
    return floor(value * mul + 0.5) / mul
end

local function fmtNum(n: number): string
    local s = tostring(floor(n))
    if #s <= 3 then
        return s
    end
    local parts = {}
    local rem = #s % 3
    if rem > 0 then
        table.insert(parts, s:sub(1, rem))
    end
    for i = rem + 1, #s, 3 do
        table.insert(parts, s:sub(i, i + 2))
    end
    return table.concat(parts, ",")
end

local function fmtBytes(n: number): string
    if n < 1024 then
        return `{n}B`
    end
    if n < 1048576 then
        return `{roundTo(n / 1024, 1)}KB`
    end
    return `{roundTo(n / 1048576, 2)}MB`
end

local function fmtTime(us: number): string
    if us < 1 then
        return `{floor(us * 1000 + 0.5)}ns`
    end
    if us < 1000 then
        return `{roundTo(us, 1)}us`
    end
    return `{roundTo(us / 1000, 1)}ms`
end

-- Public -----------------------------------------------------------------

local Harness = {}

Harness.fmtBytes = fmtBytes
Harness.fmtTime = fmtTime
Harness.fmtNum = fmtNum

function Harness.header(title: string): ()
    local pad = HEADER_WIDTH - #title
    local left = if pad > 0 then pad // 2 else 0
    print(FMT_HEADER)
    print(string.rep(" ", left) .. title)
    print(FMT_HEADER)
end

function Harness.section(title: string): ()
    print(title)
end

function Harness.sectionEnd(): ()
    print("")
end

function Harness.note(text: string): ()
    print(format("%s%s", INDENT, text))
end

--[[
    Encode-only throughput. Iter count is auto-picked from a probe so
    every test runs for roughly MEASURE_BUDGET seconds.
]]
function Harness.benchEncode(label: string, fn: () -> ()): ()
    local iterations = pickIterCount(fn)
    for _ = 1, warmupFor(iterations) do
        fn()
    end

    local t0 = clock()
    for _ = 1, iterations do
        fn()
    end
    local elapsed = clock() - t0

    print(
        format(
            FMT_ROW_ENC,
            INDENT,
            label,
            fmtNum(iterations / elapsed),
            fmtTime(elapsed / iterations * 1e6),
            fmtNum(iterations)
        )
    )
end

--[[
    Wire size for a codec + value pair. Output:
      <label>            <bytes>
    Returns the byte count for callers that compare against external refs.
]]
function Harness.benchWireSize(label: string, codec: any, value: any): number
    local ch = Channel.create()
    codec.write(ch, value)
    local bytes = ch.cursor

    print(format(FMT_LABEL_VALUE, INDENT, label, fmtBytes(bytes)))
    return bytes
end

--[[
    Delta savings. `mutate(value)` returns a changed copy; if omitted,
    falls back to bumping the first numeric field at the alphabetically
    first sorted key.
]]
function Harness.benchDelta(
    label: string,
    codec: any,
    value: any,
    mutate: ((value: any) -> any)?
): ()
    local ch = Channel.create()

    codec.write(ch, value)
    local fullBytes = ch.cursor

    ch.cursor = 0
    codec.write(ch, value)
    local unchangedBytes = ch.cursor

    local changed = value
    if mutate then
        changed = mutate(value)
    elseif typeof(value) == "table" then
        changed = table.clone(value)
        local keys = {}
        for k in changed do
            table.insert(keys, k)
        end
        sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)
        for _, k in keys do
            if typeof(changed[k]) == "number" then
                changed[k] += 1
                break
            end
        end
    end

    ch.cursor = 0
    codec.write(ch, changed)
    local changedBytes = ch.cursor

    local savings = floor((1 - unchangedBytes / fullBytes) * 100 + 0.5)
    print(
        format(
            FMT_ROW_DELTA,
            INDENT,
            label,
            fmtBytes(fullBytes),
            fmtBytes(unchangedBytes),
            fmtBytes(changedBytes),
            `{savings}%`
        )
    )
end

--[[
    Full encode + decode round-trip. Iter count is auto-picked from a
    probe of the combined enc+dec cycle so every test runs for roughly
    MEASURE_BUDGET seconds.
]]
function Harness.benchRoundTrip(label: string, codec: any, value: any): ()
    local ch = Channel.create()
    codec.write(ch, value)
    local written = ch.cursor

    local buf = buffer.create(written)
    buffer.copy(buf, 0, ch.buff, 0, written)
    local refs = if ch.refCount > 0 then table.clone(ch.refs) else nil

    local function cycle(): ()
        ch.cursor = 0
        codec.write(ch, value)
        codec.read(buf, 0, refs)
    end

    local iterations = pickIterCount(cycle)
    for _ = 1, warmupFor(iterations) do
        cycle()
    end

    local t0 = clock()
    for _ = 1, iterations do
        ch.cursor = 0
        codec.write(ch, value)
    end
    local encodeTime = clock() - t0

    local t1 = clock()
    for _ = 1, iterations do
        codec.read(buf, 0, refs)
    end
    local decodeTime = clock() - t1

    local encUs = encodeTime / iterations * 1e6
    local decUs = decodeTime / iterations * 1e6

    print(
        format(
            FMT_ROW_RT,
            INDENT,
            format("%s (%dB)", label, written),
            fmtTime(encUs),
            fmtTime(decUs),
            fmtTime(encUs + decUs),
            fmtNum(iterations / (encodeTime + decodeTime))
        )
    )
end

--[[
    Network throughput sampler. Caller supplies a `send` callback fired
    `firesPerFrame` times per Heartbeat; harness samples FPS and the
    measured DataSendKbps once per second for `durationSeconds`.

    Direction-agnostic: works for both client->server and server->client
    benches as long as the caller measures local DataSendKbps (which
    Roblox reports on whichever side is sending).
]]
function Harness.benchNetwork(
    label: string,
    firesPerFrame: number,
    durationSeconds: number,
    send: () -> ()
): ()
    local RunService = game:GetService("RunService")
    local Stats = game:GetService("Stats")

    task.wait(SETTLE_SECONDS)

    local fpsData: { number } = {}
    local kbpsData: { number } = {}
    local frames = 0
    local elapsed = 0

    local conn = RunService.Heartbeat:Connect(function(dt: number)
        for _ = 1, firesPerFrame do
            send()
        end
        frames += 1
        elapsed += dt
        if elapsed >= SAMPLE_INTERVAL then
            table.insert(fpsData, frames / elapsed)
            table.insert(kbpsData, Stats.DataSendKbps)
            frames, elapsed = 0, 0
        end
    end)

    task.wait(durationSeconds)
    conn:Disconnect()

    if #fpsData == 0 then
        print(format(FMT_LABEL_VALUE, INDENT, label, "no samples"))
        return
    end

    sort(fpsData)
    sort(kbpsData)

    print(
        format(
            FMT_ROW_NET,
            INDENT,
            label,
            tostring(roundTo(percentile(fpsData, 50), 1)),
            tostring(roundTo(percentile(fpsData, 1), 1)),
            tostring(roundTo(percentile(kbpsData, 50), 1)),
            tostring(roundTo(percentile(kbpsData, 95), 1)),
            tostring(roundTo(percentile(kbpsData, 99), 1))
        )
    )
end

--[[
    Cross-library comparison. Reports FPS and Kbps at percentiles used
    by github.com/1Axen/blink/benchmark. Kbps scaled to `targetFPS` so
    samples compare across hardware.
]]
function Harness.benchComparison(
    label: string,
    firesPerFrame: number,
    durationSeconds: number,
    targetFPS: number,
    send: () -> ()
): ()
    local RunService = game:GetService("RunService")
    local Stats = game:GetService("Stats")

    --[[
        Fixed settle. We previously also spun on `Stats.DataSendKbps` to
        wait for prior traffic to fully dissipate, but that hangs forever
        on the client in Studio where the moving average never crosses
        the floor. The Kbps value is scaled per-sample by targetFPS /
        frames anyway, so a few residual frames don't skew percentiles.
    ]]
    task.wait(SETTLE_SECONDS)

    local fpsData: { number } = {}
    local kbpsData: { number } = {}
    local frames = 0
    local elapsed = 0
    local sent = 0

    local conn = RunService.Heartbeat:Connect(function(dt: number)
        frames += 1
        elapsed += dt
        for _ = 1, firesPerFrame do
            send()
            sent += 1
        end
        if elapsed >= SAMPLE_INTERVAL then
            table.insert(kbpsData, Stats.DataSendKbps * (targetFPS / frames))
            table.insert(fpsData, frames)
            frames = 0
            elapsed -= SAMPLE_INTERVAL
        end
    end)

    task.wait(durationSeconds)
    conn:Disconnect()

    if #fpsData == 0 then
        print(format(FMT_LABEL_VALUE, INDENT, label, "no samples"))
        return
    end

    sort(kbpsData)
    -- FPS sorted descending: P0 = best frame, P100 = worst.
    sort(fpsData, function(a, b)
        return a > b
    end)

    local function p(samples: { number }, pct: number): string
        local idx = maxN(1, minN(floor(#samples * pct / 100), #samples))
        return tostring(roundTo(samples[idx], 2))
    end

    print(
        format(
            FMT_ROW_COMP,
            INDENT,
            label,
            "FPS",
            p(fpsData, 50),
            p(fpsData, 0),
            p(fpsData, 80),
            p(fpsData, 90),
            p(fpsData, 95),
            p(fpsData, 100)
        )
    )
    print(
        format(
            FMT_ROW_COMP,
            INDENT,
            "",
            "Kbps",
            p(kbpsData, 50),
            p(kbpsData, 0),
            p(kbpsData, 80),
            p(kbpsData, 90),
            p(kbpsData, 95),
            p(kbpsData, 100)
        )
    )
    print(
        format(
            "%s%-" .. LABEL_WIDTH .. "s sent=%s samples=%s",
            INDENT,
            "",
            fmtNum(sent),
            tostring(#fpsData)
        )
    )
end

return table.freeze(Harness)
