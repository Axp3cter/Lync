--!strict
--!optimize 2
-- What a schema costs to build, which is join latency rather than frame cost.

local Compile = require ("@src/shape/Compile")
local Lync = require ("@src")
local Shape = require ("@src/shape")

local Schemas = require ("@fixtures/Schemas")

local Harness = require ("@bench/harness")

-- Constants -----------------------------------------------------------

-- Fixed rather than drawn, since a namespace hash folds the name in and a build is that hash too.
const SPACE = "bench"

-- The field a keyed set partitions by, which the widest fixture declares for exactly this.
const TEAM = "team"

-- Private -------------------------------------------------------------

--[[
    One of each kind, assigned rather than chosen: a marker outside a set is refused at `start` so
    the widest fixture can only be a set, `motion` is what a packet is for, and a query takes two
    of what is left. Built once, so a loop measures the build rather than the first of them.
]]
local function defined (): any
    return {
        moving = Lync.packet (Schemas.motion.codec),
        asking = Lync.query (Schemas.flag.codec, Schemas.profile.codec),
        holding = Lync.replicate (Schemas.everything.codec):keyBy (TEAM),
    }
end

-- One schema built, whose emitted record lands in the harness's sink.
local function shaped (of: Schemas.Fixture): any return Shape.build (of.codec, of.name) end

-- Public --------------------------------------------------------------

return {
    -- The narrowest schema, so what every row below costs is this plus what its own holds.
    Harness.row ({
        name = "compile.schema-flag",
        run = function (): any return shaped (Schemas.flag) end,
    }),

    -- The other end: every constructor and modifier at once, which is a caller's widest definition.
    Harness.row ({
        name = "compile.schema-everything",
        run = function (): any return shaped (Schemas.everything) end,
    }),

    --[[
        The wait a player sits through at join, timed alone because an encode row a microsecond
        slower and a join a tenth of a second slower are two conversations.
    ]]
    Harness.row ({
        name = "compile.namespace",
        setup = defined,
        run = function (specs: any): any return Compile.build (SPACE, specs) end,
    }),
}
