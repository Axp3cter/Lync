--!strict
--!optimize 2
-- The datatype constructors: the form each records, and the parameters each turns away.

local Base = require("@src/codec/Base")
local Codecs = require("@src/codec")
local Datatypes = require("@src/codec/Datatypes")
local Scalars = require("@src/codec/Scalars")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local TURN = Scalars.TURN
local FINE = 1
local NOT_A_NAME = 7

local function params(of: any): Base.Params
    return Base.cell(of).params
end

local function children(of: any): { [string]: any }
    return Base.cell(of).children :: any
end

return {
    -- A form is recorded wherever one name carries more than one wire object.
    Harness.case("datatypes.forms", function()
        Expect.equal(params(Datatypes.vec3()).form, "components")
        Expect.equal(params(Datatypes.vec3.unit(FINE)).form, "unit")
        Expect.equal(params(Datatypes.vec3.unit(FINE)).step, FINE)
        Expect.equal(params(Datatypes.rotation.none()).form, "none")
        Expect.equal(params(Datatypes.rotation.quat(FINE)).form, "quat")
        Expect.equal(params(Datatypes.color3()).form, "components")
        Expect.equal(params(Datatypes.color3.rgb565()).form, "rgb565")
        Expect.equal(Base.cell(Datatypes.vec2()).kind, "vec2")
        Expect.equal(params(Datatypes.inst("Part")).class, "Part")
        Expect.equal(params(Datatypes.inst()).class, nil)
    end),

    -- A component codec is a bare child, on either vector.
    Harness.case("datatypes.components", function()
        local q = Scalars.quant(-1, 1, 0.5)
        Expect.equal(Base.cell(children(Datatypes.vec2(q)).component).kind, "quant")
        Expect.equal(Base.cell(children(Datatypes.vec3(q)).component).kind, "quant")
        Expect.throws(function()
            Datatypes.vec3(Scalars.empty())
        end, "no empty for component")
        Expect.throws(function()
            Datatypes.vec2(NOT_A_NAME :: any)
        end, "takes a codec for component")
    end),

    -- A precision means the same thing wherever the surface takes one.
    Harness.case("datatypes.precision-everywhere", function()
        for _, make in { Datatypes.vec3.unit, Datatypes.rotation.quat } do
            make(TURN)
            make(FINE)
            for _, bad in { 0, -FINE, TURN + FINE, 0 / 0, 1 / 0 } do
                Expect.throws(function()
                    make(bad)
                end, "precision")
            end
        end
    end),

    Harness.case("datatypes.cframe", function()
        local of = Datatypes.cframe(Datatypes.vec3(), Datatypes.rotation.quat(FINE))
        Expect.equal(Base.cell(of).kind, "cframe")
        Expect.equal(Base.cell(children(of).position).kind, "vec3")
        Expect.equal(Base.cell(children(of).rotation).kind, "rotation")
        Expect.throws(function()
            Datatypes.cframe(NOT_A_NAME :: any, Datatypes.rotation.none())
        end, "takes a codec for position")
    end),

    Harness.case("datatypes.inst-class", function()
        for _, bad in { NOT_A_NAME, "", true } do
            Expect.throws(function()
                Datatypes.inst(bad :: any)
            end, "takes a class name")
        end
    end),

    -- The constructor table names every kind once and nothing else.
    Harness.case("codecs.table", function()
        local wanted = {
            "empty",
            "bool",
            "int",
            "quant",
            "angle",
            "f32",
            "f64",
            "vlq",
            "vli",
            "str",
            "buffer",
            "struct",
            "array",
            "map",
            "optional",
            "tagged",
            "enum",
            "bitfield",
            "vec2",
            "vec3",
            "cframe",
            "rotation",
            "color3",
            "inst",
        }
        local count = 0
        for _ in Codecs :: { [string]: any } do
            count += 1
        end
        Expect.equal(count, #wanted)
        for _, name in wanted do
            Expect.holds((Codecs :: any)[name] ~= nil, `the table has no {name}`)
        end
        Expect.equal(table.isfrozen(Codecs :: any), true)
        Expect.equal(Base.cell(Codecs.int(0, 1)).kind, "int")
        Expect.equal(Base.cell(Codecs.str.alphabet("ab", 0, 1)).params.symbols, "ab")
    end),
}
