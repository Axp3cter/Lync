--!strict
--!optimize 2
-- Centralized warn/error/assert. Project name + caller source come from here.

-- State ------------------------------------------------------------------

-- Module-level so tests mute the whole library without threading a flag.
local _silent = false

-- Constants --------------------------------------------------------------

local PREFIX = "[Lync]"

-- Private ----------------------------------------------------------------

--[[
    Stack levels: 1=this fn, 2=Log.warn/error/assert, 3=user. We want #3 so
    the source/line/name point at the actual caller, not at Log.

    Source comes back as a dotted Roblox path (e.g. "ServerScriptService.
    MainModule.Lync.codec.primitive.Int" or "...test.unit.api.Packet.spec").
    `.spec` is a literal dot in test ModuleScript names, so split-on-dot
    would yield the meaningless tail "spec"; check the .spec suffix first
    and recover the meaningful segment, then fall back to the last segment.
]]
local function format(message: string): string
    local source, line, name = debug.info(3, "sln")
    local file = source:match("([^.]+)%.spec$") or source:match("[^./\\]+$") or source
    if name and name ~= "" then
        return `{PREFIX} {file}:{line} ({name}) {message}`
    end
    return `{PREFIX} {file}:{line} {message}`
end

-- Public -----------------------------------------------------------------

local Log = {}

function Log.warn(message: string): ()
    if not _silent then
        warn(format(message))
    end
end

-- level 2 so the runtime traceback points at the caller, not at Log.
function Log.error(message: string): never
    error(format(message), 2)
end

--[[
    NOTE: Luau evaluates args eagerly. `format(message)` runs even when cond
    is true, paying one debug.info call per Log.assert call. Use only with
    LITERAL strings (no interpolation). For interpolated messages prefer
    `if cond then Log.error(...) end`.
]]
function Log.assert<T>(cond: T, message: string): T
    return assert(cond, format(message))
end

function Log.setSilent(silent: boolean): ()
    _silent = silent
end

function Log.reset(): ()
    _silent = false
end

return table.freeze(Log)
