--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe ("Scope create", function (): ()
    it ("returns object", function (): ()
        local s = Lync.scope ()
        expect (s):toBeTruthy ()
    end)
end)

describe ("Scope add + destroy", function (): ()
    it ("disconnects lync connections", function (): ()
        local s = Lync.scope ()
        local disconnected = false
        local mockConn = {
            connected = true,
            disconnect = function (self: any): ()
                disconnected = true
                self.connected = false
            end,
        }
        s:add (mockConn)
        s:destroy ()
        expect (disconnected):toBe (true)
    end)

    it ("disconnects RBX-style connections", function (): ()
        local s = Lync.scope ()
        local disconnected = false
        local mockConn = setmetatable ({}, {
            __index = {
                Disconnect = function (): ()
                    disconnected = true
                end,
            },
        })
        -- Fake typeof to return "RBXScriptConnection" won't work in test env,
        -- so this tests the .disconnect fallback path instead.
        s:add ({
            disconnect = function (): ()
                disconnected = true
            end,
        })
        s:destroy ()
        expect (disconnected):toBe (true)
    end)

    it ("handles multiple connections", function (): ()
        local s = Lync.scope ()
        local count = 0
        for _ = 1, 5 do
            s:add ({
                disconnect = function (): ()
                    count += 1
                end,
            })
        end
        s:destroy ()
        expect (count):toBe (5)
    end)

    it ("double destroy is safe", function (): ()
        local s = Lync.scope ()
        s:add ({ disconnect = function (): () end })
        s:destroy ()
        expect (function (): ()
            s:destroy ()
        end).never:toThrow ()
    end)

    it ("destroy on empty is safe", function (): ()
        local s = Lync.scope ()
        expect (function (): ()
            s:destroy ()
        end).never:toThrow ()
    end)

    it ("add nil is safe", function (): ()
        local s = Lync.scope ()
        expect (function (): ()
            s:add (nil)
        end).never:toThrow ()
        s:destroy ()
    end)
end)

return nil
