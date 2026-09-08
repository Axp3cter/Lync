--!strict
--!optimize 2
-- What a schema costs to build, which is join latency rather than frame cost.

local Compile = require("@src/shape/Compile")
local Packet = require("@src/api/Packet")
local Query = require("@src/api/Query")
local Set = require("@src/api/Set")
local Shape = require("@src/shape")

local Schemas = require("@fixtures/Schemas")

local Harness = require("@bench/harness")

-- Fixed rather than drawn, since a namespace hash folds the name in and a build is that hash too.
local SPACE = "bench"

-- The field a keyed set partitions by, which the widest fixture declares for exactly this.
local TEAM = "team"

-- Private -------------------------------------------------------------

-- One of each kind: a marker outside a set is refused at start so the widest fixture can only be
-- a set, motion is what a packet is for, and a query takes two of what is left.
local function defined(): any
    return {
        moving = Packet.new(Schemas.motion.codec),
        asking = Query.new(Schemas.flag.codec, Schemas.profile.codec),
        holding = Set.new(Schemas.everything.codec):keyBy(TEAM),
    }
end

local function shaped(of: Schemas.Fixture): any
    return Shape.build(of.codec, of.name)
end

-- Public --------------------------------------------------------------

return {
    -- The narrowest schema, so what every row below costs is this plus what its own holds.
    Harness.row({
        name = "compile.schema-flag",
        run = function(): any
            return shaped(Schemas.flag)
        end,
    }),

    -- The other end: nearly every constructor and every modifier, a caller's widest definition.
    Harness.row({
        name = "compile.schema-everything",
        run = function(): any
            return shaped(Schemas.everything)
        end,
    }),

    -- The wait a player sits through at join, timed alone.
    Harness.row({
        name = "compile.namespace",
        setup = defined,
        run = function(specs: any): any
            return Compile.build(SPACE, specs)
        end,
    }),
}
