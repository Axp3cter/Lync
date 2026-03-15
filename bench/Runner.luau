--!strict
--!optimize 2
-- Benchmark harness.

local Channel = require(script.Parent.Parent.core.Channel)
local Types   = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T>     = Types.Codec<T>

-- Constants --------------------------------------------------------------

local DEFAULT_SAMPLES = 2000
local DEFAULT_WARMUP  = 500
local DEFAULT_BATCH   = 200

local clock = os.clock
local sort  = table.sort
local floor = math.floor
local max   = math.max
local min   = math.min

-- State ------------------------------------------------------------------

type BenchEntry = {
    name:    string,
    fn:      () -> (),
    samples: number,
    warmup:  number,
    batch:   number,
}

type BenchGroup = {
    name:    string,
    entries: { BenchEntry },
}

local _groups  = {} :: { BenchGroup }
local _current = nil :: BenchGroup?

-- Private ----------------------------------------------------------------

local function median(sorted: { number }): number
    local n   = #sorted
    local mid = floor(n / 2)
    if n % 2 == 0 then
        return (sorted[mid] + sorted[mid + 1]) / 2
    end
    return sorted[mid + 1]
end

local function percentile(sorted: { number }, p: number): number
    local idx = floor(#sorted * p / 100 + 0.5)
    return sorted[max(1, min(idx, #sorted))]
end

local function formatNanos(ns: number): string
    if ns < 1000 then
        return `{floor(ns * 10 + 0.5) / 10} ns`
    elseif ns < 1000000 then
        return `{floor(ns / 100 + 0.5) / 10} µs`
    else
        return `{floor(ns / 100000 + 0.5) / 10} ms`
    end
end

local function runEntry(entry: BenchEntry): ()
    local fn      = entry.fn
    local warmup  = entry.warmup
    local nSample = entry.samples
    local batch   = entry.batch
    local invB    = 1 / batch

    for _ = 1, warmup * batch do
        fn()
    end

    local data = table.create(nSample)
    for i = 1, nSample do
        local t0 = clock()
        for _ = 1, batch do
            fn()
        end
        data[i] = (clock() - t0) * 1e9 * invB
    end

    sort(data)

    local total = 0
    for _, s in data do
        total += s
    end

    local avg = total / nSample
    local med = median(data)
    local lo  = data[1]
    local hi  = data[nSample]
    local p99 = percentile(data, 99)
    local ops = nSample * batch

    print(`      {entry.name}`)
    print(`        avg={formatNanos(avg)}  med={formatNanos(med)}  min={formatNanos(lo)}  max={formatNanos(hi)}  p99={formatNanos(p99)}  ops={ops}`)
end

-- Public -----------------------------------------------------------------

local Runner = {}

function Runner.group(name: string, fn: () -> ()): ()
    local group: BenchGroup = { name = name, entries = {} }
    local previous = _current
    _current = group
    table.insert(_groups, group)
    fn()
    _current = previous
end

--[[
    Registers a benchmark. Each sample times `batch` calls of fn(),
    then divides to get per-op time. High batch = accurate for fast ops.
    Low batch (1) = accurate for slow ops that already exceed clock tick.
]]
function Runner.measure(
    name: string,
    fn: () -> (),
    config: { samples: number?, warmup: number?, batch: number? }?
): ()
    if not _current then error("[Bench] measure() must be called inside group()") end

    local cfg = config or {}
    table.insert(_current.entries, {
        name    = name,
        fn      = fn,
        samples = cfg.samples or DEFAULT_SAMPLES,
        warmup  = cfg.warmup or DEFAULT_WARMUP,
        batch   = cfg.batch or DEFAULT_BATCH,
    })
end

function Runner.run(): ()
    print("\n══════════════════════════════════════════════════════════════")
    print("  Lync Benchmark Suite")
    print("══════════════════════════════════════════════════════════════\n")

    for _, group in _groups do
        print(`    {group.name}`)
        for _, entry in group.entries do
            runEntry(entry)
        end
        print("")
    end

    print("══════════════════════════════════════════════════════════════\n")
    table.clear(_groups)
end

--[[
    Encodes a value through a codec into a fresh channel.
    Returns (channel, bytesWritten) for read benchmarks.
]]
function Runner.encode(codec: Codec<any>, value: any): (ChannelState, number)
    local ch = Channel.create()
    codec.write(ch, value)
    return ch, ch.cursor
end

return table.freeze(Runner)
