--!strict
--!optimize 2
-- Gate.validate: invalid inputs across every catalog codec category.

local Env = require(script:FindFirstAncestor("test").Env)

local Codecs = Env.Codecs
local Gate = Env.Internal.Gate
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("adversarial.Schema", function(): ()
    beforeEach(Sandbox.resetAll)

    for _, entry in Codecs.list do
        if not entry.invalid or #entry.invalid == 0 then
            continue
        end
        describe(entry.name, function(): ()
            for i, bad in entry.invalid do
                local label: string
                local t = typeof(bad)
                if t == "number" and bad ~= bad then
                    label = `[{i}] NaN`
                elseif t == "table" then
                    label = `[{i}] table`
                else
                    label = `[{i}] ({t}) {tostring(bad)}`
                end
                it(`rejects {label}`, function(): ()
                    local reason = Gate.validate(bad, entry.codec)
                    expect(reason).never:toBe(nil)
                end)
            end
        end)
    end
end)

return nil
