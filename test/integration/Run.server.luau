--!strict
--!optimize 2
local Players = game:GetService ("Players")
local ReplicatedStorage = game:GetService ("ReplicatedStorage")

local LyncFolder = ReplicatedStorage:WaitForChild ("Lync")
local Lync = require (LyncFolder)
local Scenarios = require (
    LyncFolder:WaitForChild ("test"):WaitForChild ("integration"):WaitForChild ("Scenarios")
)

-- Wait for unit tests to finish defining packets, then start transport.
task.wait (3)
Lync.start ()

-- Helpers ----------------------------------------------------------------

local passed = 0
local failed = 0
local errors = {} :: { string }

local function pass (name: string): ()
    passed += 1
    print (`    ✓ {name}`)
end

local function fail (name: string, reason: string): ()
    failed += 1
    local msg = `    ✗ {name} — {reason}`
    print (msg)
    table.insert (errors, msg)
end

local function test (name: string, fn: () -> ()): ()
    local ok, err = pcall (fn)
    if ok then
        pass (name)
    else
        fail (name, tostring (err))
    end
end

local function getPlayer (): Player
    local players = Players:GetPlayers ()
    return if #players > 0 then players[1] else Players.PlayerAdded:Wait ()
end

-- Main -------------------------------------------------------------------

local player = getPlayer ()
Scenarios.Ready:wait ()

print (
    "\n══════════════════════════════════════════════════════════════"
)
print ("  Lync Integration Tests")
print (
    "══════════════════════════════════════════════════════════════\n"
)

print ("  Server → Client")
test ("sendTo u8", function (): ()
    Scenarios.SimpleU8:sendTo (255, player)
end)

test ("sendTo struct", function (): ()
    Scenarios.Struct:sendTo ({ hp = 100, name = "hero", alive = true }, player)
end)

test ("sendTo big array", function (): ()
    local data = table.create (500)
    for i = 1, 500 do
        data[i] = i
    end
    Scenarios.BigArray:sendTo (data, player)
end)

test ("sendTo unreliable vec3", function (): ()
    Scenarios.Unreliable:sendTo (Vector3.new (1, 2, 3), player)
end)

test ("sendToAll", function (): ()
    Scenarios.SimpleU8:sendToAll (42)
end)

test ("sendToList", function (): ()
    Scenarios.SimpleU8:sendToList (42, { player })
end)

test ("sendToAllExcept", function (): ()
    Scenarios.SimpleU8:sendToAllExcept (42, player)
end)

print ("\n  Query round-trip")
test ("echo query", function (): ()
    local result = Scenarios.Echo:invoke ("hello", player)
    assert (result == "echo:hello", `Expected "echo:hello", got "{result}"`)
end)

test ("math query", function (): ()
    local result = Scenarios.MathQuery:invoke ({ a = 10, b = 20 }, player)
    assert (math.abs (result - 30) < 0.01, `Expected 30, got {result}`)
end)

print ("\n  Client → Server")
test ("client send u8", function (): ()
    local value = Scenarios.ClientToServer:wait ()
    assert (value == 42, `Expected 42, got {value}`)
end)

print ("\n  Groups")
test ("sendToGroup", function (): ()
    Lync.createGroup ("__intGroup")
    Lync.addToGroup ("__intGroup", player)
    Scenarios.SimpleU8:sendToGroup (99, "__intGroup")
    Lync.destroyGroup ("__intGroup")
end)

-- Results ----------------------------------------------------------------

task.wait (1)
print (
    "\n──────────────────────────────────────────────────────────────"
)
print (`  {passed} passed, {failed} failed, {passed + failed} total`)
if failed > 0 then
    print ("\n  Failures:")
    for _, msg in errors do
        print (msg)
    end
end
print (
    "══════════════════════════════════════════════════════════════\n"
)
