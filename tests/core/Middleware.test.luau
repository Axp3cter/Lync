--!strict
--!optimize 2
-- Middleware.test.luau — Send/receive chain ordering, nil short-circuit, removal.

local Middleware = require (script.Parent.Parent.Parent.core.Middleware)
local Runner = require (script.Parent.Parent.Runner)

local describe = Runner.describe
local it = Runner.it
local expect = Runner.expect

-- Tests ------------------------------------------------------------------

describe ("Middleware.runSend with no handlers", function (): ()
    it ("returns data unchanged", function (): ()
        expect (Middleware.runSend (42, "test", nil)):toBe (42)
    end)
    it ("passes through tables", function (): ()
        local data = { hp = 100 }
        local result = Middleware.runSend (data, "test", nil)
        expect (result):toBe (data)
    end)
end)

describe ("Middleware.addSend chain", function (): ()
    it ("transforms data through handlers in order", function (): ()
        local removeFnA = Middleware.addSend (
            function (data: any, _name: string, _player: Player?): any?
                return (data :: number) + 1
            end
        )
        local removeFnB = Middleware.addSend (
            function (data: any, _name: string, _player: Player?): any?
                return (data :: number) * 10
            end
        )

        local result = Middleware.runSend (5, "test", nil)
        expect (result):toBe (60)

        removeFnA ()
        removeFnB ()
    end)
    it ("short-circuits on nil return", function (): ()
        local removeFn = Middleware.addSend (
            function (_data: any, _name: string, _player: Player?): any?
                return nil
            end
        )

        expect (Middleware.runSend (42, "test", nil)):toBeNil ()
        removeFn ()
    end)
end)

describe ("Middleware.addReceive", function (): ()
    it ("transforms received data", function (): ()
        local removeFn = Middleware.addReceive (
            function (data: any, _name: string, _player: Player?): any?
                return (data :: number) + 100
            end
        )

        expect (Middleware.runReceive (5, "test", nil)):toBe (105)
        removeFn ()
    end)
end)

describe ("Middleware removal", function (): ()
    it ("remove function disconnects the handler", function (): ()
        local callCount = 0
        local removeFn = Middleware.addSend (
            function (data: any, _name: string, _player: Player?): any?
                callCount += 1
                return data
            end
        )

        Middleware.runSend (1, "test", nil)
        expect (callCount):toBe (1)

        removeFn ()
        Middleware.runSend (1, "test", nil)
        expect (callCount):toBe (1)
    end)
    it ("double removal is safe", function (): ()
        local removeFn = Middleware.addSend (
            function (data: any, _name: string, _player: Player?): any?
                return data
            end
        )

        removeFn ()
        expect (function (): ()
            removeFn ()
        end).never:toThrow ()
    end)
end)

describe ("Middleware error handling", function (): ()
    it ("returns nil and warns on handler error", function (): ()
        local removeFn = Middleware.addSend (
            function (_data: any, _name: string, _player: Player?): any?
                error ("intentional test error")
            end
        )

        local result = Middleware.runSend (42, "test", nil)
        expect (result):toBeNil ()
        removeFn ()
    end)
end)

return nil
