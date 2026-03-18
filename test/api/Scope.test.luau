--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("Scope create", function(): ()
    it("returns object", function(): ()
        local s = Lync.scope()
        expect(s):toBeTruthy()
    end)
end)

describe("Scope add + destroy", function(): ()
    it("disconnects lync connections", function(): ()
        local s = Lync.scope()
        local disconnected = false
        s:add({
            disconnect = function(): ()
                disconnected = true
            end,
        })
        s:destroy()
        expect(disconnected):toBe(true)
    end)

    it("handles multiple connections", function(): ()
        local s = Lync.scope()
        local count = 0
        for _ = 1, 5 do
            s:add({
                disconnect = function(): ()
                    count += 1
                end,
            })
        end
        s:destroy()
        expect(count):toBe(5)
    end)

    it("double destroy is safe", function(): ()
        local s = Lync.scope()
        s:add({ disconnect = function(): () end })
        s:destroy()
        expect(function(): ()
            s:destroy()
        end).never:toThrow()
    end)

    it("destroy on empty is safe", function(): ()
        local s = Lync.scope()
        expect(function(): ()
            s:destroy()
        end).never:toThrow()
    end)

    it("add nil is safe", function(): ()
        local s = Lync.scope()
        expect(function(): ()
            s:add(nil)
        end).never:toThrow()
        s:destroy()
    end)
end)

describe("Scope listen shortcut", function(): ()
    it("calls listen on source and tracks", function(): ()
        local s = Lync.scope()
        local disconnected = false
        local received = false

        local mockPacket = {
            listen = function(_self: any, fn: any): any
                fn("test")
                return {
                    disconnect = function(): ()
                        disconnected = true
                    end,
                }
            end,
        }

        s:listen(mockPacket, function(data: any): ()
            received = true
        end)

        expect(received):toBe(true)
        s:destroy()
        expect(disconnected):toBe(true)
    end)
end)

describe("Scope once shortcut", function(): ()
    it("calls once on source and tracks", function(): ()
        local s = Lync.scope()
        local disconnected = false

        local mockPacket = {
            once = function(_self: any, fn: any): any
                return {
                    disconnect = function(): ()
                        disconnected = true
                    end,
                }
            end,
        }

        s:once(mockPacket, function(): () end)
        s:destroy()
        expect(disconnected):toBe(true)
    end)
end)

describe("Scope listenAll shortcut", function(): ()
    it("calls listenAll on namespace and tracks", function(): ()
        local s = Lync.scope()
        local disconnected = false

        local mockNs = {
            listenAll = function(_self: any, fn: any): any
                return {
                    disconnect = function(): ()
                        disconnected = true
                    end,
                }
            end,
        }

        s:listenAll(mockNs, function(): () end)
        s:destroy()
        expect(disconnected):toBe(true)
    end)
end)

return nil
