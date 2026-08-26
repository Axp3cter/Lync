--!strict
--!optimize 2
-- Every constructor a schema is written from, in one frozen table.

local Composites = require ("@src/codec/Composites")
local Datatypes = require ("@src/codec/Datatypes")
local Scalars = require ("@src/codec/Scalars")
local Text = require ("@src/codec/Text")

local Codecs = {
    bool = Scalars.bool,
    int = Scalars.int,
    quant = Scalars.quant,
    angle = Scalars.angle,
    f32 = Scalars.f32,
    f64 = Scalars.f64,
    vlq = Scalars.vlq,
    vli = Scalars.vli,

    str = Text.str,
    buffer = Text.buffer,

    struct = Composites.struct,
    array = Composites.array,
    map = Composites.map,
    optional = Composites.optional,
    tagged = Composites.tagged,
    enum = Composites.enum,
    bitfield = Composites.bitfield,

    vec2 = Datatypes.vec2,
    vec3 = Datatypes.vec3,
    cframe = Datatypes.cframe,
    rotation = Datatypes.rotation,
    color3 = Datatypes.color3,
    inst = Datatypes.inst,
}

return table.freeze (Codecs)
