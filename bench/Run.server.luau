--!strict
--!optimize 2
-- Server-side benchmark runner.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local LyncFolder = ReplicatedStorage:WaitForChild("Lync")
local Lync = require(LyncFolder)
local Scenarios = require(LyncFolder:WaitForChild("bench"):WaitForChild("Scenarios"))

Lync.setChannelMaxSize(1048576) -- 1 MB, needed for Blink entities bench (100x6B x 1000 fires)
Lync.start()

-- Config --------------------------------------------------------------

local FIRES_PER_FRAME = 1000
local DURATION = 10
local SETTLE = 3
local MAX_FRAMERATE = 60

local floor = math.floor
local sort = table.sort
local max = math.max
local min = math.min

-- Helpers -------------------------------------------------------------

local function getPlayer(): Player
    local players = Players:GetPlayers()
    return if #players > 0 then players[1] else Players.PlayerAdded:Wait()
end

local function percentile(sorted: { number }, p: number): number
    local idx = floor(#sorted * p / 100 + 0.5)
    return sorted[max(1, min(idx, #sorted))]
end

local function fmt(value: number): string
    return `{floor(value * 100 + 0.5) / 100}`
end

-- Lync-style bench -------------------------------------------------------

type TestConfig = {
    name: string,
    player: Player,
    packet: any,
    data: () -> any,
    bytes: number,
}

local function runTest(config: TestConfig): ()
    task.wait(SETTLE)

    local packet = config.packet
    local getData = config.data
    local target = config.player
    local fpsData = {} :: { number }
    local kbpsData = {} :: { number }
    local frames = 0
    local elapsed = 0
    local sampleN = 0

    local conn: RBXScriptConnection
    conn = RunService.Heartbeat:Connect(function(dt: number): ()
        local frameData = getData()

        for _ = 1, FIRES_PER_FRAME do
            packet:send(frameData, target)
        end

        frames += 1
        elapsed += dt

        if elapsed >= 1 then
            sampleN += 1
            fpsData[sampleN] = frames / elapsed
            kbpsData[sampleN] = Stats.DataSendKbps
            frames = 0
            elapsed = 0
        end
    end)

    task.wait(DURATION)
    conn:Disconnect()

    sort(fpsData)
    sort(kbpsData)

    local n = #fpsData
    if n == 0 then
        print(`    {config.name}: no samples`)
        return
    end

    local fMed = fmt(fpsData[floor(n / 2) + 1])
    local kMed = fmt(kbpsData[floor(n / 2) + 1])
    local kP95 = fmt(percentile(kbpsData, 95))
    local raw = fmt(config.bytes * FIRES_PER_FRAME * 60 * 8 / 1000)

    print(`    {config.name}`)
    print(`      FPS med={fMed}  Kbps med={kMed}  p95={kP95}  raw={raw}  ({n} samples)`)
end

-- Blink-style bench ------------------------------------------------------

type BlinkTestConfig = {
    name: string,
    player: Player,
    packet: any,
    data: any,
}

local function runBlinkTest(config: BlinkTestConfig): ()
    task.wait(SETTLE)

    -- Wait for any leftover traffic to drain
    while Stats.DataSendKbps > 0.5 do
        RunService.Heartbeat:Wait()
    end
    task.wait(2)

    local packet = config.packet
    local data = config.data
    local target = config.player

    local fpsData = {} :: { number }
    local kbpsData = {} :: { number }
    local frames = 0
    local elapsed = 0
    local sent = 0

    local conn: RBXScriptConnection
    conn = RunService.Heartbeat:Connect(function(dt: number): ()
        frames += 1
        elapsed += dt

        for _ = 1, FIRES_PER_FRAME do
            packet:send(data, target)
            sent += 1
        end

        if elapsed >= 1 then
            local scale = MAX_FRAMERATE / frames
            table.insert(kbpsData, Stats.DataSendKbps * scale)
            table.insert(fpsData, frames)
            frames = 0
            elapsed -= 1
        end
    end)

    task.wait(DURATION)
    conn:Disconnect()

    sort(kbpsData)
    sort(fpsData, function(a: number, b: number): boolean
        return a > b
    end)

    local n = #fpsData
    if n == 0 then
        print(`    {config.name}: no samples`)
        return
    end

    -- Blink-format output: Median, P0, P80, P90, P95, P100
    local function p(samples: { number }, pct: number): string
        local idx = max(1, min(floor(#samples * pct / 100), #samples))
        return fmt(samples[idx])
    end

    -- FPS is sorted descending so P0 = best, P100 = worst
    print(`    {config.name}`)
    print(
        `      FPS    | Median={p(fpsData, 50)} | P0={p(fpsData, 0)} | P80={p(fpsData, 80)} | P90={p(
            fpsData,
            90
        )} | P95={p(fpsData, 95)} | P100={p(fpsData, 100)}`
    )
    print(
        `      Kbps   | Median={p(kbpsData, 50)} | P0={p(kbpsData, 0)} | P80={p(kbpsData, 80)} | P90={p(
            kbpsData,
            90
        )} | P95={p(kbpsData, 95)} | P100={p(kbpsData, 100)}`
    )
    print(`      Sent={sent}  Samples={n}`)
end

-- Main ----------------------------------------------------------------

local player = getPlayer()
Scenarios.Ready:wait()

-- Section 1: Lync-specific benchmarks
print(`\n  Lync Bench  {FIRES_PER_FRAME}/frame  {DURATION}s per test\n`)

runTest({
    name = "Static booleans",
    player = player,
    packet = Scenarios.Booleans,
    data = function(): any
        return true
    end,
    bytes = 1,
})

print("")

runTest({
    name = "Static entities",
    player = player,
    packet = Scenarios.Entities,
    data = function(): any
        return Scenarios.STATIC_ENTITY
    end,
    bytes = 34,
})

print("")

local moveFrame = 0

runTest({
    name = "Moving entities",
    player = player,
    packet = Scenarios.Entities,
    data = function(): any
        moveFrame += 1
        return {
            position = Vector3.new(100.5 + moveFrame * 0.1, 50.25, -200.75 + moveFrame * 0.05),
            velocity = Vector3.new(10.1, 0, -5.3),
            health = 87.5,
            shield = 42.0,
            alive = true,
            team = 2,
        }
    end,
    bytes = 34,
})

print("")

local random = Random.new(42)

runTest({
    name = "Chaotic entities",
    player = player,
    packet = Scenarios.Entities,
    data = function(): any
        return {
            position = Vector3.new(
                random:NextNumber(-500, 500),
                random:NextNumber(0, 200),
                random:NextNumber(-500, 500)
            ),
            velocity = Vector3.new(
                random:NextNumber(-50, 50),
                random:NextNumber(-10, 10),
                random:NextNumber(-50, 50)
            ),
            health = random:NextNumber(0, 100),
            shield = random:NextNumber(0, 100),
            alive = random:NextNumber(0, 1) > 0.5,
            team = random:NextInteger(1, 4),
        }
    end,
    bytes = 34,
})

-- Section 2: Blink-compatible benchmarks
print(`\n\n  Blink-Compatible Bench  {FIRES_PER_FRAME}/frame  {DURATION}s per test`)
print("  Same data shapes as github.com/1Axen/blink/benchmark\n")

runBlinkTest({
    name = "Entities(100x struct, 6x u8)",
    player = player,
    packet = Scenarios.BlinkEntities,
    data = Scenarios.BLINK_ENTITIES,
})

print("")

runBlinkTest({
    name = "Booleans(1000x bool)",
    player = player,
    packet = Scenarios.BlinkBooleans,
    data = Scenarios.BLINK_BOOLEANS,
})

print("\n  Done\n")
