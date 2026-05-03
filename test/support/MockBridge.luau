--!strict
--!optimize 2
-- In-memory replacement for Roblox RemoteEvents. Captures FireServer /
-- FireClient calls and lets tests replay them as incoming events.

local Lync = script.Parent.Parent.Parent

local Bridge = require(Lync.transport.Bridge)

-- Public types -----------------------------------------------------------

export type CapturedServerFrame = {
    data: any,
    refs: { Instance }?,
}

export type CapturedClientFrame = {
    player: any,
    data: any,
    refs: { Instance }?,
}

export type MockSignal = {
    _listeners: { (...any) -> () },
    Connect: (self: MockSignal, fn: (...any) -> ()) -> { Disconnect: () -> () },
    _fire: (self: MockSignal, ...any) -> (),
}

export type MockRemote = {
    OnServerEvent: MockSignal,
    OnClientEvent: MockSignal,
    capturedServer: { CapturedServerFrame },
    capturedClient: { CapturedClientFrame },
    FireServer: (self: MockRemote, data: any, refs: { Instance }?) -> (),
    FireClient: (
        self: MockRemote,
        player: any,
        data: any,
        refs: { Instance }?
    ) -> (),
    FireAllClients: (self: MockRemote, data: any, refs: { Instance }?) -> (),
    replayServer: (self: MockRemote, player: any, data: any, refs: { Instance }?) -> (),
    replayClient: (self: MockRemote, data: any, refs: { Instance }?) -> (),
    drainServer: (self: MockRemote) -> { CapturedServerFrame },
    drainClient: (self: MockRemote) -> { CapturedClientFrame },
}

export type Harness = {
    reliable: MockRemote,
    unreliable: MockRemote,
}

-- Private ----------------------------------------------------------------

local function newSignal(): MockSignal
    local self: any = { _listeners = {} }

    function self:Connect(fn: (...any) -> ()): { Disconnect: () -> () }
        table.insert(self._listeners, fn)
        local conn = {}
        function conn.Disconnect(): ()
            local listeners = self._listeners
            for i, listener in listeners do
                if listener == fn then
                    local last = #listeners
                    if i ~= last then
                        listeners[i] = listeners[last]
                    end
                    listeners[last] = nil
                    break
                end
            end
        end
        return conn
    end

    function self:_fire(...: any): ()
        local snapshot = table.clone(self._listeners)
        for _, fn in snapshot do
            fn(...)
        end
    end

    return self :: MockSignal
end

local function newRemote(): MockRemote
    local self: any = {
        OnServerEvent = newSignal(),
        OnClientEvent = newSignal(),
        capturedServer = {},
        capturedClient = {},
    }

    function self:FireServer(data: any, refs: { Instance }?): ()
        table.insert(self.capturedServer, { data = data, refs = refs })
    end

    function self:FireClient(player: any, data: any, refs: { Instance }?): ()
        table.insert(self.capturedClient, { player = player, data = data, refs = refs })
    end

    function self:FireAllClients(data: any, refs: { Instance }?): ()
        table.insert(self.capturedClient, { player = "*", data = data, refs = refs })
    end

    function self:replayServer(player: any, data: any, refs: { Instance }?): ()
        self.OnServerEvent:_fire(player, data, refs)
    end

    function self:replayClient(data: any, refs: { Instance }?): ()
        self.OnClientEvent:_fire(data, refs)
    end

    function self:drainServer(): { CapturedServerFrame }
        local out = self.capturedServer
        self.capturedServer = {}
        return out
    end

    function self:drainClient(): { CapturedClientFrame }
        local out = self.capturedClient
        self.capturedClient = {}
        return out
    end

    return self :: MockRemote
end

-- Public -----------------------------------------------------------------

local MockBridge = {}

MockBridge.newSignal = newSignal
MockBridge.newRemote = newRemote

--[[
    Build a paired mock and attach it to Bridge so subsequent calls into
    Server.start, Client.start, Bridge.fireServer, Bridge.fireClient route
    through these in-memory remotes instead of real Roblox networking.
]]
function MockBridge.install(): Harness
    local reliable = newRemote()
    local unreliable = newRemote()
    Bridge.attach(reliable, unreliable)
    return {
        reliable = reliable,
        unreliable = unreliable,
    }
end

return table.freeze(MockBridge)
