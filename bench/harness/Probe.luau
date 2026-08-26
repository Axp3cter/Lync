--!strict
--!optimize 2
-- The host a report was measured on, so nobody reads its numbers against the wrong machine.

local RunService = game:GetService ("RunService")

local Probe = {}

-- Types ---------------------------------------------------------------

--[[
    What a report can say about where it came from. Metadata only: nothing in the bench or the
    library branches on any of it, and a row that behaved differently on a host would be a row
    measuring the host.
]]
export type Host = {
    read side: string,
    read studio: boolean,
    read luau: string,
}

-- Public --------------------------------------------------------------

-- The host, as far as anything can be asked about it.
function Probe.host (side: string): Host
    return table.freeze ({
        side = side,
        studio = RunService:IsStudio (),
        luau = _VERSION,
    })
end

return table.freeze (Probe)
