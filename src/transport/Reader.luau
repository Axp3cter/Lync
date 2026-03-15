--!strict
--!optimize 2
-- Reader.luau — Deserializes incoming buffers and routes by registration kind.

local Registry   = require(script.Parent.Parent.core.Registry)
local Varint     = require(script.Parent.Parent.core.Varint)
local Middleware = require(script.Parent.Parent.core.Middleware)
local Gate       = require(script.Parent.Gate)

-- Public -----------------------------------------------------------------

local Reader = {}

function Reader.process(incoming: buffer, refs: { Instance }?, player: Player?, startOffset: number): ()
    local length = buffer.len(incoming)
    local pos    = startOffset

    while pos < length do
        local id, idBytes = Varint.read(incoming, pos)
        pos += idBytes

        local reg = Registry.get(id)
        if not reg then
            warn("[Lync] Unknown ID", id)
            break
        end

        local kind          = reg.kind
        local correlationId = nil :: number?

        if kind ~= "packet" then
            if pos >= length then break end
            correlationId = buffer.readu8(incoming, pos)
            pos += 1
        end

        local ok, value, consumed = pcall(reg.codec.read, incoming, pos, refs)
        if not ok then
            warn(`[Lync] Read error ({reg.name}): {value}`)
            break
        end
        pos += consumed :: number

        -- Gate failure breaks: corrupted data makes the cursor unreliable
        if player and not Gate.check(value, reg, player) then
            break
        end

        -- Middleware nil continues: the read succeeded and pos is valid
        local final = Middleware.runReceive(value, reg.baseName, player)
        if final == nil then continue end

        if kind == "packet" then
            reg.signal:fire(final, player)
        elseif kind == "request" then
            reg.signal:fire(final, player, correlationId)
        else
            reg.signal:fire(final, correlationId)
        end
    end
end

return table.freeze(Reader)
