--!strict
--!optimize 2
-- Player-shaped key helpers. Roblox does not let user code instantiate
-- a real Player Instance, so tests use either:
--   * unique tables (Lua table identity) for tests that only need a key,
--   * Folder Instances for tests that require typeof(x) == "Instance",
--   * direct calls into Util.isPlayer for boundary tests.

-- State ------------------------------------------------------------------

local _seq = 0

-- Public -----------------------------------------------------------------

local Players = {}

--[[
    Returns a unique table to use as a map key. typeof() is "table", so
    Util.isPlayer returns false. Use this when the code under test only
    keys a map by player and never inspects the typeof.
]]
function Players.newTableKey(): { name: string, userId: number }
    _seq += 1
    return { name = `TableKey{_seq}`, userId = _seq }
end

--[[
    Returns a Folder Instance to use as a key. typeof() is "Instance",
    but folder:IsA("Player") is false. Use when code paths check typeof
    but not IsA.
]]
function Players.newInstanceKey(): Instance
    _seq += 1
    local folder = Instance.new("Folder")
    folder.Name = `InstanceKey{_seq}`
    return folder
end

--[[
    Cleans up a key. Safe for both table and Instance forms.
]]
function Players.destroy(key: any): ()
    if typeof(key) == "Instance" then
        (key :: Instance):Destroy()
    end
end

--[[
    Returns N unique Instance keys for tests that need multiple players.
]]
function Players.newInstanceKeys(n: number): { Instance }
    local out = table.create(n)
    for i = 1, n do
        out[i] = Players.newInstanceKey()
    end
    return out
end

--[[
    Cleanup a list returned by newInstanceKeys.
]]
function Players.destroyAll(keys: { any }): ()
    for _, k in keys do
        Players.destroy(k)
    end
end

return table.freeze(Players)
