--!strict
--!optimize 2
-- The sample schemas both places mount, each with the values its goldens are cut from.

local Codecs = require("@src/codec")
local Packet = require("@src/api/Packet")
local Protocol = require("@src/wire/Protocol")
local Set = require("@src/api/Set")
local Types = require("@src/Types")

local Schemas = {}

-- Constants -----------------------------------------------------------

local ALPHANUMERIC = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local HEX = "0123456789abcdef"

-- A quarter turn in radians, which every rotation case that has an angle is built out of.
local QUARTER = math.pi / 2

-- The largest whole number the wire carries, which is what a vlq case tops out at.
local WIDEST = Protocol.EXACT - 1

-- The widest a roster's health field reaches, which every check that sets one stays under.
local HEALTH = 100

-- A byte on the wire read as a fraction and put back as a byte, which is what `as` is for.
local function toFraction(byte: number): number
    return byte / 255
end

local function fromFraction(fraction: number): number
    return math.round(fraction * 255)
end

-- A decode-time invariant that holds, so the field round-trips and the path is walked.
local function stepOfFive(value: number): string?
    return if value % 5 == 0 then nil else "not a step of five"
end

-- Types ---------------------------------------------------------------

-- One representative value and the name its goldens are filed under: `empty`, `one`, `typical`
-- and `largest` wherever each exists, so a size golden reads as a byte count that moved.
export type Case = {
    read name: string,
    read value: any,
}

export type Fixture = {
    read name: string,
    read codec: Types.Codec<any>,
    read cases: { Case },
}

-- Private -------------------------------------------------------------

local function case(name: string, value: any): Case
    return table.freeze({ name = name, value = value })
end

local function fixture(name: string, codec: Types.Codec<any>, cases: { Case }): Fixture
    return table.freeze({ name = name, codec = codec, cases = table.freeze(cases) })
end

-- A list of whatever a caller makes of each index, which is how every bulk case is built.
local function repeated(count: number, each: (number) -> any): { any }
    local out = table.create(count) :: { any }
    for index = 1, count do
        table.insert(out, each(index))
    end
    return out
end

local function slot(index: number): any
    return { item = "potion", count = index }
end

-- Public --------------------------------------------------------------

-- One flag: the smallest thing that crosses the wire, which makes the framing around it visible.
Schemas.flag = fixture("flag", Codecs.bool(), { case("off", false), case("on", true) })

-- Nothing at all: the one kind whose payload is the fact of the call, pinned so the framing around
-- an empty payload never grows a byte.
Schemas.nothing = fixture("nothing", Codecs.empty(), { case("only", nil) })

-- Six bytes of bounded integer, every field bit-continuous, which is most real traffic.
Schemas.entity = fixture(
    "entity",
    Codecs.struct({
        id = Codecs.int(0, 255),
        x = Codecs.int(0, 255),
        y = Codecs.int(0, 255),
        z = Codecs.int(0, 255),
        facing = Codecs.int(0, 255),
        pose = Codecs.int(0, 255),
    }),
    {
        case("smallest", { id = 0, x = 0, y = 0, z = 0, facing = 0, pose = 0 }),
        case("typical", { id = 7, x = 10, y = 20, z = 30, facing = 40, pose = 3 }),
        case("largest", { id = 255, x = 255, y = 255, z = 255, facing = 255, pose = 255 }),
    }
)

-- A character's frame of movement: the lossy datatypes in the shape that sends every tick.
Schemas.motion = fixture(
    "motion",
    Codecs.struct({
        at = Codecs.vec3(Codecs.quant(-1024, 1024, 0.05)),
        facing = Codecs.vec3.unit(1),
        lean = Codecs.angle(0.5),
        speed = Codecs.quant(0, 100, 0.25),
    }),
    {
        case("still", { at = Vector3.zero, facing = Vector3.new(0, 0, -1), lean = 0, speed = 0 }),
        case("typical", {
            at = Vector3.new(12.35, 4.5, -87.2),
            facing = Vector3.new(1, 0, 0),
            lean = 12.5,
            speed = 16.25,
        }),
        case("largest", {
            at = Vector3.new(1024, 1024, -1024),
            facing = Vector3.new(0, 1, 0),
            lean = 359.5,
            speed = 100,
        }),
    }
)

-- What a player carries on join: text, a name from a set, packed flags, and a field that may be
-- absent. Where length is a cost, not a bound.
Schemas.profile = fixture(
    "profile",
    Codecs.struct({
        name = Codecs.str(1, 20),
        tag = Codecs.str.alphabet(ALPHANUMERIC, 3, 8),
        team = Codecs.enum({ "red", "blue", "spectator" }),
        perks = Codecs.bitfield({ "flight", "shield", "haste", "vision" }),
        title = Codecs.optional(Codecs.str(1, 24)),
    }),
    {
        case("shortest", {
            name = "a",
            tag = "abc",
            team = "red",
            perks = { flight = false, shield = false, haste = false, vision = false },
        }),
        case("typical", {
            name = "Aspecter",
            tag = "asp01",
            team = "blue",
            perks = { flight = false, shield = true, haste = false, vision = true },
            title = "Wayfinder",
        }),
        case("longest", {
            name = string.rep("W", 20),
            tag = "ZZZZZZZZ",
            team = "spectator",
            perks = { flight = true, shield = true, haste = true, vision = true },
            title = string.rep("Q", 24),
        }),
    }
)

-- A list and a dictionary that both run from nothing to their bound: the one fixture with a size
-- axis.
Schemas.inventory = fixture(
    "inventory",
    Codecs.struct({
        slots = Codecs.array(
            Codecs.struct({
                item = Codecs.enum({ "sword", "shield", "potion", "rope" }),
                count = Codecs.int(1, 99),
            }),
            0,
            32
        ),
        purse = Codecs.map(Codecs.enum({ "gold", "silver", "shard" }), Codecs.vlq(), 0, 3),
    }),
    {
        case("empty", { slots = {}, purse = {} }),
        case("one", { slots = { { item = "sword", count = 1 } }, purse = { gold = 1 } }),
        case("typical", {
            slots = {
                { item = "sword", count = 1 },
                { item = "potion", count = 12 },
                { item = "rope", count = 3 },
            },
            purse = { gold = 240, silver = 18 },
        }),
        case("largest", {
            slots = repeated(32, slot),
            purse = { gold = WIDEST, silver = 65535, shard = 7 },
        }),
    }
)

-- Every modifier and every constructor in one record: the schema the acceptance scenario drives
-- end to end.
-- `team` is what a keyed set keys by, `title` the optional `none` clears, `carry` replicates on
-- the newest lane.
Schemas.everything = fixture(
    "everything",
    Codecs.struct({
        flag = Codecs.bool(),
        count = Codecs.int(0, 1000),
        ratio = Codecs.quant(-1, 1, 0.001),
        heading = Codecs.angle(0.5),
        single = Codecs.f32(),
        double = Codecs.f64(),
        tally = Codecs.vlq(),
        offset = Codecs.vli(),

        label = Codecs.str(0, 24),
        letters = Codecs.str.alphabet("abc", 0, 6),
        handle = Codecs.str.alphabet(ALPHANUMERIC, 1, 12),
        colour = Codecs.str.alphabet(HEX, 6, 6),
        payload = Codecs.buffer(0, 32),

        team = Codecs.enum({ "red", "blue", "spectator" }),
        perks = Codecs.bitfield({ "flight", "shield", "haste", "vision" }),

        nested = Codecs.struct({ near = Codecs.int(0, 15), far = Codecs.int(0, 15) }),
        list = Codecs.array(Codecs.int(0, 63), 0, 8),
        purse = Codecs.map(Codecs.enum({ "gold", "silver" }), Codecs.vlq(), 0, 2),
        title = Codecs.optional(Codecs.str(1, 24)),
        event = Codecs.tagged("kind", {
            spawn = Codecs.struct({ at = Codecs.vec3() }),
            score = Codecs.struct({ points = Codecs.int(0, 100) }),
        }),

        flat = Codecs.vec2(),
        place = Codecs.vec3(),
        facing = Codecs.vec3.unit(1),
        frame = Codecs.cframe(Codecs.vec3(), Codecs.rotation.quat(1)),
        fixed = Codecs.rotation.none(),
        turn = Codecs.rotation.quat(1),
        tint = Codecs.color3(),
        cheap = Codecs.color3.rgb565(),
        source = Codecs.inst(),

        checked = Codecs.int(0, 100):validate(stepOfFive),
        scaled = Codecs.int(0, 255):as(toFraction, fromFraction),
        carry = Codecs.vec3(Codecs.quant(-1024, 1024, 0.05)):newest(),
    }),
    {
        case("smallest", {
            flag = false,
            count = 0,
            ratio = -1,
            heading = 0,
            single = 0,
            double = 0,
            tally = 0,
            offset = 0,
            label = "",
            letters = "",
            handle = "a",
            colour = "000000",
            payload = buffer.fromstring(""),
            team = "red",
            perks = { flight = false, shield = false, haste = false, vision = false },
            nested = { near = 0, far = 0 },
            list = {},
            purse = {},
            event = { kind = "score", points = 0 },
            flat = Vector2.zero,
            place = Vector3.zero,
            facing = Vector3.new(0, 0, -1),
            frame = CFrame.identity,
            fixed = CFrame.identity,
            turn = CFrame.identity,
            tint = Color3.new(0, 0, 0),
            cheap = Color3.new(0, 0, 0),
            checked = 0,
            scaled = 0,
            carry = Vector3.zero,
        }),
        case("typical", {
            flag = true,
            count = 250,
            ratio = 0.25,
            heading = 90,
            single = 0.5,
            double = 1 / 3,
            tally = 4096,
            offset = -17,
            label = "lync",
            letters = "abcabc",
            handle = "Player01",
            colour = "1a2b3c",
            payload = buffer.fromstring("lync"),
            team = "red",
            perks = { flight = false, shield = true, haste = false, vision = true },
            nested = { near = 3, far = 12 },
            list = { 1, 2, 3 },
            purse = { gold = 240 },
            event = { kind = "spawn", at = Vector3.new(1.5, 0, -2.5) },
            flat = Vector2.new(0.5, -0.25),
            place = Vector3.new(1.5, 2.25, -3.75),
            facing = Vector3.new(0, 0, -1),
            frame = CFrame.fromAxisAngle(Vector3.yAxis, QUARTER) + Vector3.new(1.5, 0, -2.5),
            fixed = CFrame.identity,
            turn = CFrame.fromAxisAngle(Vector3.zAxis, QUARTER),
            tint = Color3.new(0.5, 0.25, 0.75),
            cheap = Color3.new(16 / 31, 32 / 63, 8 / 31),
            checked = 45,
            scaled = 128 / 255,
            carry = Vector3.new(1.25, 0.5, -2.75),
        }),
        case("largest", {
            flag = true,
            count = 1000,
            ratio = 1,
            heading = 359.5,
            single = 0.5,
            double = 1 / 3,
            tally = WIDEST,
            offset = -WIDEST,
            label = string.rep("z", 24),
            letters = "cccccc",
            handle = "ZZZZZZZZZZZZ",
            colour = "ffffff",
            payload = buffer.fromstring(string.rep("\255", 32)),
            team = "spectator",
            perks = { flight = true, shield = true, haste = true, vision = true },
            nested = { near = 15, far = 15 },
            list = { 63, 63, 63, 63, 63, 63, 63, 63 },
            purse = { gold = WIDEST, silver = WIDEST },
            title = string.rep("Q", 24),
            event = { kind = "score", points = 100 },
            flat = Vector2.new(0.5, -0.25),
            place = Vector3.new(1.5, 2.25, -3.75),
            facing = Vector3.new(0, 1, 0),
            frame = CFrame.fromAxisAngle(Vector3.yAxis, QUARTER) + Vector3.new(1.5, 0, -2.5),
            fixed = CFrame.identity,
            turn = CFrame.fromAxisAngle(Vector3.zAxis, QUARTER),
            tint = Color3.new(0.5, 0.25, 0.75),
            cheap = Color3.new(1, 1, 1),
            checked = 100,
            scaled = 255 / 255,
            carry = Vector3.new(-1024, 1024, -1024),
        }),
    }
)

-- Every fixture, in the order the goldens file them, so a new fixture is covered by every suite
-- the moment it lands.
Schemas.all = table.freeze({
    Schemas.flag,
    Schemas.nothing,
    Schemas.entity,
    Schemas.motion,
    Schemas.profile,
    Schemas.inventory,
    Schemas.everything,
})

-- The set, its two fields, and the two keys one takes, which the rules suites read it by.
Schemas.ROSTER = "roster"
Schemas.TEAM = "team"
Schemas.HP = "hp"
Schemas.RED = "red"
Schemas.BLUE = "blue"

-- The one packet a bench row fires, under the name those rows reach it by.
Schemas.BEAT = "beat"

-- A set keyed by a field, as the definitions one machine requires.
function Schemas.roster(): any
    local record = Codecs.struct({
        [Schemas.TEAM] = Codecs.enum({ Schemas.RED, Schemas.BLUE }),
        [Schemas.HP] = Codecs.int(0, HEALTH),
    })
    return { [Schemas.ROSTER] = Set.new(record):keyBy(Schemas.TEAM) }
end

-- One packet over a motion codec, which is what a bench row measures a fire of.
function Schemas.beat(): any
    return { [Schemas.BEAT] = Packet.new(Schemas.motion.codec) }
end

-- The value a fixture files under a name.
function Schemas.cased(of: Fixture, name: string): any
    for _, one in of.cases do
        if one.name == name then return one.value end
    end
    error(`{of.name} has no case named {name}`, 0)
end

return table.freeze(Schemas)
