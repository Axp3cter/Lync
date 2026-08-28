--!strict
--!optimize 2
-- One declaration to the pair that writes it and reads it back, which is the whole compile path.

local Base = require ("@src/codec/Base")
local Emit = require ("@src/shape/emit")
local Grid = require ("@src/shape/Grid")
local Ir = require ("@src/shape/Ir")
local Lower = require ("@src/shape/Lower")
local Serial = require ("@src/shape/Serial")
local Types = require ("@src/Types")

local Shape = {}

-- Types ---------------------------------------------------------------

-- What a build interns and the sidecar it fills, declared in the emitter and re-exported here.
export type Site = Emit.Site

-- A declaration compiled: the pair, what it costs, and the facts everything above reads off it.
export type Built = {
    read cell: Base.Cell,
    read write: Ir.Write,
    read read: Ir.Read,
    read maxBytes: number,
    read fixed: boolean,
    read tag: Ir.Tag,
    read grid: Grid.Grid?,
    read marker: Base.Marker,
    read sidecar: Ir.Sidecar,
    read paths: Serial.Interner,
    read expected: Serial.Interner,
}

-- Private -------------------------------------------------------------

-- The grid a whole declaration is one index on, where it is one, and nothing where it is not.
local function gridded (of: Ir.Shape): Grid.Grid?
    if of.op == "xform" then return gridded (of.inner) end
    if of.op == "wide" then return of.grid end
    if of.op ~= "word" then return nil end

    -- A pull spreads one value over several leaves, so there is no single index to answer with.
    if of.joins[1].pull ~= nil then return nil end
    return of.leaves[1]
end

-- Public --------------------------------------------------------------

-- A codec and where a refusal inside it says it is, as the build everything above holds.
function Shape.build (of: Types.Codec<any>, at: string, shared: Site?): Built
    local cell = Base.cell (of)
    local site: Site = shared
        or {
            paths = Serial.interner (),
            expected = Serial.interner (),
            sidecar = { refs = {}, slotOf = {}, bears = false },
        }

    local shape = Lower.of (cell, at, site)

    --[[
        The collector put round the read only where something under it can park a reason. A tree
        with no check in it has nothing that ever parks one, so the clearing and the asking either
        side of every read it does would be a question with one answer.
    ]]
    local before = Emit.wrapped ()
    local write, read = Emit.emit (shape, site)
    if Emit.wrapped () > before then read = Emit.rooted (read) end

    return table.freeze ({
        cell = cell,
        write = write,
        read = read,
        maxBytes = shape.maxBytes,
        fixed = shape.fixed,
        tag = shape.tag,
        grid = gridded (shape),
        marker = cell.marker,
        sidecar = site.sidecar,
        paths = site.paths,
        expected = site.expected,
    })
end

return table.freeze (Shape)
