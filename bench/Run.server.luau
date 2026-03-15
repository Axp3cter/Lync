--!strict
-- Server-side bench runner.

local Players = game:GetService ("Players")
local ReplicatedStorage = game:GetService ("ReplicatedStorage")
local RunService = game:GetService ("RunService")
local Stats = game:GetService ("Stats")

local Lync = ReplicatedStorage:WaitForChild ("Lync")
local Definitions = require (Lync:WaitForChild ("bench"):WaitForChild ("Definitions"))
local LyncModule = require (Lync)

LyncModule.start ()

-- Config -----------------------------------------------------------------

local FIRES_PER_FRAME = 1000
local DURATION = 10
local SETTLE = 3

local floor = math.floor
local sort = table.sort
local max = math.max
local min = math.min

-- Helpers ----------------------------------------------------------------

local function getPlayer (): Player
    local existing = Players:GetPlayers ()
    if #existing > 0 then
        return existing[1]
    end
    return Players.PlayerAdded:Wait ()
end

local function percentile (sorted: { number }, p: number): number
    local idx = floor (#sorted * p / 100 + 0.5)
    return sorted[max (1, min (idx, #sorted))]
end

local function fmt (value: number): string
    return `{floor (value * 100 + 0.5) / 100}`
end

type TestConfig = {
    name: string,
    player: Player,
    packet: any,
    data: () -> any,
    bytes: number,
}

local function runTest (config: TestConfig): ()
    task.wait (SETTLE)

    local packet = config.packet
    local getData = config.data
    local target = config.player
    local fpsData = {} :: { number }
    local kbpsData = {} :: { number }
    local frames = 0
    local elapsed = 0
    local sampleN = 0

    local conn: RBXScriptConnection
    conn = RunService.Heartbeat:Connect (function (dt: number): ()
        local frameData = getData ()

        for _ = 1, FIRES_PER_FRAME do
            packet:sendTo (frameData, target)
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

    task.wait (DURATION)
    conn:Disconnect ()

    sort (fpsData)
    sort (kbpsData)

    local n = #fpsData
    if n == 0 then
        print (`    {config.name}: no samples`)
        return
    end

    local fMed = fmt (fpsData[floor (n / 2) + 1])
    local kMed = fmt (kbpsData[floor (n / 2) + 1])
    local kP95 = fmt (percentile (kbpsData, 95))
    local raw = fmt (config.bytes * FIRES_PER_FRAME * 60 * 8 / 1000)

    print (`    {config.name}`)
    print (`      FPS med={fMed}  Kbps med={kMed}  p95={kP95}  raw={raw}  ({n} samples)`)
end

-- Main -------------------------------------------------------------------

local player = getPlayer ()
Definitions.Ready:listen (function (): () end)
Definitions.Ready:wait ()

print (`\n  Lync Bench  {FIRES_PER_FRAME}/frame  {DURATION}s per test\n`)

-- Static booleans: same value every frame.
-- XOR zeros everything. Baseline batching overhead.
runTest ({
    name = "Static booleans",
    player = player,
    packet = Definitions.Booleans,
    data = function (): any
        return true
    end,
    bytes = 1,
})

print ("")

-- Static entities: 34 bytes, same data every frame.
-- XOR produces all zeros, LZSS compresses to near nothing.
local staticEntity = Definitions.STATIC_ENTITY

runTest ({
    name = "Static entities",
    player = player,
    packet = Definitions.Entities,
    data = function (): any
        return staticEntity
    end,
    bytes = 34,
})

print ("")

-- Moving entities: only position changes each frame.
-- XOR produces 12 non-zero bytes (vec3) + 22 zero bytes.
-- Typical gameplay pattern.
local moveFrame = 0

runTest ({
    name = "Moving entities",
    player = player,
    packet = Definitions.Entities,
    data = function (): any
        moveFrame += 1
        return {
            position = Vector3.new (100.5 + moveFrame * 0.1, 50.25, -200.75 + moveFrame * 0.05),
            velocity = Vector3.new (10.1, 0, -5.3),
            health = 87.5,
            shield = 42.0,
            alive = true,
            team = 2,
        }
    end,
    bytes = 34,
})

print ("")

-- Chaotic entities: every field random every frame.
-- XOR produces entirely non-zero bytes. LZSS finds no matches.
-- Worst case.
local random = Random.new (42)

runTest ({
    name = "Chaotic entities",
    player = player,
    packet = Definitions.Entities,
    data = function (): any
        return {
            position = Vector3.new (
                random:NextNumber (-500, 500),
                random:NextNumber (0, 200),
                random:NextNumber (-500, 500)
            ),
            velocity = Vector3.new (
                random:NextNumber (-50, 50),
                random:NextNumber (-10, 10),
                random:NextNumber (-50, 50)
            ),
            health = random:NextNumber (0, 100),
            shield = random:NextNumber (0, 100),
            alive = random:NextNumber (0, 1) > 0.5,
            team = random:NextInteger (1, 4),
        }
    end,
    bytes = 34,
})

print ("\n  Done\n")
