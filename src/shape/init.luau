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

-- What a build interns and what it hands a sidecar, declared below and passed on unchanged.
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
    local write, read = Emit.emit (shape, site)
    read = Emit.rooted (read)

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
