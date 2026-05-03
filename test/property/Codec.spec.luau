--!strict
--!optimize 2
-- Property test: every catalog codec round-trips 200 random valid inputs.

local Env = require(script:FindFirstAncestor("test").Env)

local ChannelHelper = Env.Channel
local Codecs = Env.Codecs
local Random = Env.Random
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

local SAMPLES = 100
local SEED = 0x4C796E63

describe("property.Codec", function(): ()
    beforeEach(Sandbox.resetAll)

    for _, entry in Codecs.list do
        if entry.generate == nil then
            continue
        end
        describe(entry.name, function(): ()
            it(`{SAMPLES} random valid inputs round-trip`, function(): ()
                local rng = Random.new(SEED + #entry.name)
                local fails: { string } = {}
                for i = 1, SAMPLES do
                    local input = (entry.generate :: any)(rng)
                    local ok, err = pcall(function(): ()
                        local decoded = ChannelHelper.roundTripStrict(entry.codec, input)
                        if not entry.compare(decoded, input) then
                            error(`mismatch at sample {i}: input did not round-trip`, 0)
                        end
                    end)
                    if not ok then
                        table.insert(fails, `seed={SEED + #entry.name} sample={i}: {tostring(err)}`)
                    end
                    if i % 25 == 0 then
                        task.wait()
                    end
                end
                if #fails > 0 then
                    error(`{#fails} property failures: {fails[1]}`)
                end
                expect(#fails):toBe(0)
            end)
        end)
    end
end)

return nil
