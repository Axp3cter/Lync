--!strict
--!optimize 2
-- Packet.luau — Packet definition and send/listen API via metatabled class.

local RunService = game:GetService("RunService")

local Registry = require(script.Parent.Parent.core.Registry)
local Signal   = require(script.Parent.Parent.event.Signal)
local Server   = require(script.Parent.Parent.transport.Server)
local Client   = require(script.Parent.Parent.transport.Client)
local Group    = require(script.Parent.Group)
local Types    = require(script.Parent.Parent.Types)

type Connection      = Types.Connection
type PacketConfig<T> = Types.PacketConfig<T>

-- Constants --------------------------------------------------------------

local IS_SERVER = RunService:IsServer()

-- Private ----------------------------------------------------------------

local PacketImpl = {}
PacketImpl.__index = PacketImpl

function PacketImpl.sendTo(self: any, data: any, player: Player): ()
    if not IS_SERVER then error("[Lync] sendTo is server-only") end

    Server.writeTo(player, self._id, self._name, self._codec, data, self._rel)
end

function PacketImpl.sendToAll(self: any, data: any): ()
    if not IS_SERVER then error("[Lync] sendToAll is server-only") end

    Server.writeToAll(self._id, self._name, self._codec, data, self._rel)
end

function PacketImpl.sendToList(self: any, data: any, players: { Player }): ()
    if not IS_SERVER then error("[Lync] sendToList is server-only") end

    Server.writeToList(players, self._id, self._name, self._codec, data, self._rel)
end

function PacketImpl.sendToAllExcept(self: any, data: any, except: Player): ()
    if not IS_SERVER then error("[Lync] sendToAllExcept is server-only") end

    Server.writeToAllExcept(except, self._id, self._name, self._codec, data, self._rel)
end

function PacketImpl.sendToGroup(self: any, data: any, groupName: string): ()
    if not IS_SERVER then error("[Lync] sendToGroup is server-only") end

    Server.writeToList(Group.players(groupName), self._id, self._name, self._codec, data, self._rel)
end

function PacketImpl.send(self: any, data: any): ()
    if IS_SERVER then error("[Lync] send is client-only") end

    Client.write(self._id, self._name, self._codec, data, self._rel)
end

function PacketImpl.listen(self: any, callback: (...any) -> ()): Connection
    return self._signal:connect(callback)
end

function PacketImpl.once(self: any, callback: (...any) -> ()): Connection
    return self._signal:once(callback)
end

function PacketImpl.wait(self: any): ...any
    return self._signal:wait()
end

function PacketImpl.disconnectAll(self: any): ()
    self._signal:disconnectAll()
end

-- Public -----------------------------------------------------------------

local Packet = {}

function Packet.define(name: string, config: PacketConfig<any>): any
    if not config.value then error(`[Lync] Packet "{name}" requires a value codec`) end

    local reliability = config.reliability or "reliable"
    local signal      = Signal.create()

    local reg = Registry.register(
        name, config.value, reliability, signal, config.rateLimit, config.validate
    )

    return setmetatable({
        _id     = reg.id,
        _name   = reg.name,
        _codec  = reg.codec,
        _rel    = reg.reliability,
        _signal = reg.signal,
    }, PacketImpl)
end

return table.freeze(Packet)
