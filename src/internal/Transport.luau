--!strict
--!optimize 2
-- Lazy Server/Client require to break the api -> transport import cycle.

-- State ------------------------------------------------------------------

local _server: any = nil
local _client: any = nil

-- Public -----------------------------------------------------------------

local Transport = {}

function Transport.server(): any
    if not _server then
        _server = require(script.Parent.Parent.transport.Server)
    end
    return _server
end

function Transport.client(): any
    if not _client then
        _client = require(script.Parent.Parent.transport.Client)
    end
    return _client
end

return table.freeze(Transport)
