--!strict
--!optimize 2
-- Wire-format pinning: canonical inputs produce exact byte sequences.
-- This file is the single source of truth for wire-format invariants.
-- A failure here indicates an unintended format change.

local Env = require(script:FindFirstAncestor("test").Env)

local Channel = Env.Channel
local Codecs = Env.Codecs
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("property.Wire (canonical pinning)", function(): ()
    beforeEach(Sandbox.resetAll)

    for _, entry in Codecs.list do
        if entry.canonical == nil or entry.bytes == nil then
            continue
        end
        it(`{entry.name} canonical encode matches reference bytes`, function(): ()
            local r = Channel.encode(entry.codec, entry.canonical)
            expect(r.buffer):toMatchBuffer(entry.bytes :: { number })
        end)
    end
end)

return nil
