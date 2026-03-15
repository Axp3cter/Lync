--!strict
-- Server-side bench runner.

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local Stats             = game:GetService("Stats")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Lync        = ReplicatedStorage:WaitForChild("Lync")
local LyncModule  = require(Lync)
local Definitions = require(Lync:WaitForChild("bench"):WaitForChild("Definitions"))

LyncModule.start()

-- Constants --------------------------------------------------------------

local FIRES_PER_FRAME = 1000
local DURATION        = 10
local SETTLE_TIME     = 3

local floor = math.floor
local sort  = table.sort
local max   = math.max
local min   = math.min

-- Helpers ----------------------------------------------------------------

local function getPlayer(): Player
    local existing = Players:GetPlayers()
    if #existing > 0 then return existing[1] end
    return Players.PlayerAdded:Wait()
end

local function percentile(sorted: { number }, p: number): number
    local idx = floor(#sorted * p / 100 + 0.5)
    return sorted[max(1, min(idx, #sorted))]
end

local function fmt(value: number): string
    return `{floor(value * 100 + 0.5) / 100}`
end

local function runTest(name: string, player: Player, fire: (player: Player) -> ()): ()
    task.wait(SETTLE_TIME)

    local fpsData  = {} :: { number }
    local kbpsData = {} :: { number }
    local frames   = 0
    local elapsed  = 0
    local sampleN  = 0

    local conn: RBXScriptConnection
    conn = RunService.Heartbeat:Connect(function(dt: number): ()
        for _ = 1, FIRES_PER_FRAME do
            fire(player)
        end

        frames  += 1
        elapsed += dt

        if elapsed >= 1 then
            sampleN += 1
            fpsData[sampleN]  = frames / elapsed
            kbpsData[sampleN] = Stats.DataSendKbps
            frames  = 0
            elapsed = 0
        end
    end)

    task.wait(DURATION)
    conn:Disconnect()

    sort(fpsData)
    sort(kbpsData)

    local n = #fpsData
    if n == 0 then print(`  {name}: no samples`); return end

    local fMed = fmt(fpsData[floor(n/2)+1])
    local kMed = fmt(kbpsData[floor(n/2)+1])
    local kP95 = fmt(percentile(kbpsData, 95))

    print(`  {name}  FPS med={fMed}  Kbps med={kMed} p95={kP95}  ({n} samples)`)
end

-- Main -------------------------------------------------------------------

local player = getPlayer()
Definitions.Ready:listen(function(): () end)
Definitions.Ready:wait()

print(`\nLync Bench  {FIRES_PER_FRAME}/frame × {DURATION}s`)

task.wait(1)

runTest("Booleans", player, function(target: Player): ()
    Definitions.Booleans:sendTo(Definitions.BOOL_DATA, target)
end)

runTest("Entities", player, function(target: Player): ()
    Definitions.Entities:sendTo(Definitions.ENTITY_DATA, target)
end)

print("Done\n")
