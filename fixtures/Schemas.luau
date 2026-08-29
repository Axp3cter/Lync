--!strict
--!optimize 2
-- The sample schemas both places mount, each with the values its goldens are cut from.

local Lync = require ("@src")
local Protocol = require ("@src/wire/Protocol")

local Schemas = {}

-- Constants -----------------------------------------------------------

-- The palette `everything` indexes into, named once so a case can hold a member.
const SWATCHES = table.freeze ({
    Color3.new (0, 0, 0),
    Color3.new (1, 0, 0),
    Color3.new (0, 1, 0),
    Color3.new (0, 0, 1),
})

-- A quarter turn in radians, which every rotation case that has an angle is built out of.
const QUARTER = math.pi / 2

-- The largest whole number the wire carries, which is what a vlq case tops out at.
const WIDEST = Protocol.EXACT - 1

-- The widest a roster's health field reaches, which is what every check that sets one stays under.
const HEALTH = 100

-- A byte on the wire read as a fraction and put back as a byte, which is what `as` is for.
local function toFraction (byte: number): number return byte / 255 end

local function fromFraction (fraction: number): number return math.round (fraction * 255) end

-- A decode-time invariant that holds, so the field round-trips and the path is walked.
local function stepOfFive (value: number): string?
    return if value % 5 == 0 then nil else "not a step of five"
end

-- Types ---------------------------------------------------------------

--[[
    One representative value and the name its goldens are filed under. Names are free, and the
    convention is `empty`, `one`, `typical` and `largest` wherever each exists: a size golden is a
    table of fixture against case, so a renamed case reads in review as a byte count that moved.
]]
export type Case = {
    read name: string,
    read value: any,
}

export type Fixture = {
    read name: string,
    read codec: Lync.Codec<any>,
    read cases: { Case },
}

-- Private -------------------------------------------------------------

-- A case and a fixture are frozen down to their lists, and this is the one place that freezes one.
local function case (name: string, value: any): Case
    return table.freeze ({ name = name, value = value })
end

local function fixture (name: string, codec: Lync.Codec<any>, cases: { Case }): Fixture
    return table.freeze ({ name = name, codec = codec, cases = table.freeze (cases) })
end

-- The slot a full inventory repeats, counted so the array is not one value over.
local function slot (index: number): any return { item = "potion", count = index } end

-- A list of whatever a caller makes of each index, which is how every bulk case is built.
local function repeated (count: number, each: (number) -> any): { any }
    local out = table.create (count) :: { any }
    for index = 1, count do
        table.insert (out, each (index))
    end
    return out
end

-- Public --------------------------------------------------------------

--[[
    One flag. The smallest thing that crosses the wire, which is what makes the framing around it a
    visible number rather than a rounding error.
]]
Schemas.flag = fixture ("flag", Lync.bool (), { case ("off", false), case ("on", true) })

--[[
    Six bytes of bounded integer, every field bit-continuous. The packed-run payload: what the
    encoder does here is what it does to most real traffic.
]]
Schemas.entity = fixture (
    "entity",
    Lync.struct ({
        id = Lync.int (0, 255),
        x = Lync.int (0, 255),
        y = Lync.int (0, 255),
        z = Lync.int (0, 255),
        facing = Lync.int (0, 255),
        pose = Lync.int (0, 255),
    }),
    {
        case ("smallest", { id = 0, x = 0, y = 0, z = 0, facing = 0, pose = 0 }),
        case ("typical", { id = 7, x = 10, y = 20, z = 30, facing = 40, pose = 3 }),
        case ("largest", { id = 255, x = 255, y = 255, z = 255, facing = 255, pose = 255 }),
    }
)

--[[
    A character's frame of movement: a quantized position, a direction, an angle and a speed. The
    lossy datatypes, in the shape that sends every tick.
]]
Schemas.motion = fixture (
    "motion",
    Lync.struct ({
        at = Lync.vec3 (Lync.quant (-1024, 1024, 0.05)),
        facing = Lync.vec3.unit (1),
        lean = Lync.angle (0.5),
        speed = Lync.quant (0, 100, 0.25),
    }),
    {
        case ("still", {
            at = Vector3.zero,
            facing = Vector3.new (0, 0, -1),
            lean = 0,
            speed = 0,
        }),
        case ("typical", {
            at = Vector3.new (12.35, 4.5, -87.2),
            facing = Vector3.new (1, 0, 0),
            lean = 12.5,
            speed = 16.25,
        }),
        case ("largest", {
            at = Vector3.new (1024, 1024, -1024),
            facing = Vector3.new (0, 1, 0),
            lean = 359.5,
            speed = 100,
        }),
    }
)

--[[
    What a player carries on join: variable-length text, a name from a set, packed flags, and one
    field that may be absent. Where length is a cost, not a bound.
]]
Schemas.profile = fixture (
    "profile",
    Lync.struct ({
        name = Lync.str (1, 20),
        tag = Lync.str.alphanum (3, 8),
        team = Lync.enum ({ "red", "blue", "spectator" }),
        perks = Lync.bitfield ({ "flight", "shield", "haste", "vision" }),
        title = Lync.optional (Lync.str (1, 24)),
    }),
    {
        case ("shortest", {
            name = "a",
            tag = "abc",
            team = "red",
            perks = { flight = false, shield = false, haste = false, vision = false },
        }),
        case ("typical", {
            name = "Aspecter",
            tag = "asp01",
            team = "blue",
            perks = { flight = false, shield = true, haste = false, vision = true },
            title = "Wayfinder",
        }),
        case ("longest", {
            name = string.rep ("W", 20),
            tag = "ZZZZZZZZ",
            team = "spectator",
            perks = { flight = true, shield = true, haste = true, vision = true },
            title = string.rep ("Q", 24),
        }),
    }
)

--[[
    A list and a dictionary that both run from nothing to their bound. The one fixture with a size
    axis, so the count a byte total moves with is visible.
]]
Schemas.inventory = fixture (
    "inventory",
    Lync.struct ({
        slots = Lync.array (
            Lync.struct ({
                item = Lync.enum ({ "sword", "shield", "potion", "rope" }),
                count = Lync.int (1, 99),
            }),
            0,
            32
        ),
        purse = Lync.map (Lync.enum ({ "gold", "silver", "shard" }), Lync.vlq (), 0, 3),
    }),
    {
        case ("empty", { slots = {}, purse = {} }),
        case ("one", { slots = { { item = "sword", count = 1 } }, purse = { gold = 1 } }),
        case ("typical", {
            slots = {
                { item = "sword", count = 1 },
                { item = "potion", count = 12 },
                { item = "rope", count = 3 },
            },
            purse = { gold = 240, silver = 18 },
        }),
        case ("largest", {
            slots = repeated (32, slot),
            purse = { gold = WIDEST, silver = 65535, shard = 7 },
        }),
    }
)

--[[
    Every modifier and nearly every constructor in one record: the schema a live run drives end to
    end, and the suite's definition of shipped. `team` is what a keyed set keys by, `title` is the
    optional `Lync.none` clears, `score` only climbs, and `carry` replicates unreliably.
]]
Schemas.everything = fixture (
    "everything",
    Lync.struct ({
        flag = Lync.bool (),
        count = Lync.int (0, 1000),
        ratio = Lync.quant (-1, 1, 0.001),
        heading = Lync.angle (0.5),
        single = Lync.f32 (),
        double = Lync.f64 (),
        tally = Lync.vlq (),
        offset = Lync.vli (),

        label = Lync.str (0, 24),
        letters = Lync.str.alphabet ("abc", 0, 6),
        handle = Lync.str.alphanum (1, 12),
        token = Lync.str.base32 (0, 8),
        packed = Lync.str.base64 (0, 8),
        digits = Lync.str.digits (0, 6),
        colour = Lync.str.hex (6, 6),
        payload = Lync.buffer (0, 32),

        team = Lync.enum ({ "red", "blue", "spectator" }),
        perks = Lync.bitfield ({ "flight", "shield", "haste", "vision" }),

        nested = Lync.struct ({ near = Lync.int (0, 15), far = Lync.int (0, 15) }),
        list = Lync.array (Lync.int (0, 63), 0, 8),
        purse = Lync.map (Lync.enum ({ "gold", "silver" }), Lync.vlq (), 0, 2),
        title = Lync.optional (Lync.str (1, 24)),
        event = Lync.tagged ("kind", {
            spawn = Lync.struct ({ at = Lync.vec3 () }),
            score = Lync.struct ({ points = Lync.int (0, 100) }),
        }),

        flat = Lync.vec2 (),
        place = Lync.vec3 (),
        facing = Lync.vec3.unit (1),
        push = Lync.vec3.bounded (64, 0.25),
        frame = Lync.cframe (Lync.vec3 (), Lync.rotation.quat (1)),
        fixed = Lync.rotation.none (),
        spin = Lync.rotation.axis (Vector3.yAxis, 1),
        aim = Lync.rotation.direction (1),
        turn = Lync.rotation.quat (1),
        tint = Lync.color3 (),
        cheap = Lync.color3.rgb565 (),
        swatch = Lync.color3.palette (SWATCHES),
        source = Lync.inst (),

        checked = Lync.int (0, 100):validate (stepOfFive),
        scaled = Lync.int (0, 255):as (toFraction, fromFraction),
        score = Lync.vlq ():monotonic (),
        carry = Lync.vec3 (Lync.quant (-1024, 1024, 0.05)):newest (),
    }),
    {
        case ("smallest", {
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
            token = "",
            packed = "",
            digits = "",
            colour = "000000",
            payload = buffer.fromstring (""),

            team = "red",
            perks = { flight = false, shield = false, haste = false, vision = false },

            nested = { near = 0, far = 0 },
            list = {},
            purse = {},
            event = { kind = "score", points = 0 },

            flat = Vector2.zero,
            place = Vector3.zero,
            facing = Vector3.new (0, 0, -1),
            push = Vector3.zero,
            frame = CFrame.identity,
            fixed = CFrame.identity,
            spin = CFrame.identity,
            aim = CFrame.identity,
            turn = CFrame.identity,
            tint = Color3.new (0, 0, 0),
            cheap = Color3.new (0, 0, 0),
            swatch = SWATCHES[1],

            checked = 0,
            scaled = 0,
            score = 0,
            carry = Vector3.zero,
        }),
        case ("typical", {
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
            token = "ABC234",
            packed = "aZ09+/",
            digits = "007",
            colour = "1a2b3c",
            payload = buffer.fromstring ("lync"),

            team = "red",
            perks = { flight = false, shield = true, haste = false, vision = true },

            nested = { near = 3, far = 12 },
            list = { 1, 2, 3 },
            purse = { gold = 240 },
            event = { kind = "spawn", at = Vector3.new (1.5, 0, -2.5) },

            flat = Vector2.new (0.5, -0.25),
            place = Vector3.new (1.5, 2.25, -3.75),
            facing = Vector3.new (0, 0, -1),
            push = Vector3.new (0, 8, 0),
            frame = CFrame.fromAxisAngle (Vector3.yAxis, QUARTER) + Vector3.new (1.5, 0, -2.5),
            fixed = CFrame.identity,
            spin = CFrame.fromAxisAngle (Vector3.yAxis, QUARTER),
            aim = CFrame.fromAxisAngle (Vector3.xAxis, QUARTER),
            turn = CFrame.fromAxisAngle (Vector3.zAxis, QUARTER),
            tint = Color3.new (0.5, 0.25, 0.75),
            cheap = Color3.new (16 / 31, 32 / 63, 8 / 31),
            swatch = SWATCHES[2],

            checked = 45,
            scaled = 128 / 255,
            score = 0,
            carry = Vector3.new (1.25, 0.5, -2.75),
        }),
        case ("largest", {
            flag = true,
            count = 1000,
            ratio = 1,
            heading = 359.5,
            single = 0.5,
            double = 1 / 3,
            tally = WIDEST,
            offset = -WIDEST,

            label = string.rep ("z", 24),
            letters = "cccccc",
            handle = "ZZZZZZZZZZZZ",
            token = "77777777",
            packed = "////////",
            digits = "999999",
            colour = "ffffff",
            payload = buffer.fromstring (string.rep ("\255", 32)),

            team = "spectator",
            perks = { flight = true, shield = true, haste = true, vision = true },

            nested = { near = 15, far = 15 },
            list = { 63, 63, 63, 63, 63, 63, 63, 63 },
            purse = { gold = WIDEST, silver = WIDEST },
            title = string.rep ("Q", 24),
            event = { kind = "score", points = 100 },

            flat = Vector2.new (0.5, -0.25),
            place = Vector3.new (1.5, 2.25, -3.75),
            facing = Vector3.new (0, 1, 0),
            push = Vector3.new (0, 64, 0),
            frame = CFrame.fromAxisAngle (Vector3.yAxis, QUARTER) + Vector3.new (1.5, 0, -2.5),
            fixed = CFrame.identity,
            spin = CFrame.fromAxisAngle (Vector3.yAxis, QUARTER),
            aim = CFrame.fromAxisAngle (Vector3.xAxis, QUARTER),
            turn = CFrame.fromAxisAngle (Vector3.zAxis, QUARTER),
            tint = Color3.new (0.5, 0.25, 0.75),
            cheap = Color3.new (1, 1, 1),
            swatch = SWATCHES[4],

            checked = 100,
            scaled = 255 / 255,
            score = WIDEST,
            carry = Vector3.new (-1024, 1024, -1024),
        }),
    }
)

--[[
    Every fixture, in the order the goldens file them. A suite parametrizes over this list, so a new
    fixture is covered by every suite the moment it lands.
]]
Schemas.all = table.freeze ({
    Schemas.flag,
    Schemas.entity,
    Schemas.motion,
    Schemas.profile,
    Schemas.inventory,
    Schemas.everything,
})

-- The set, its two fields, and the two keys one takes, which three rules suites read it by.
Schemas.ROSTER = "roster"
Schemas.TEAM = "team"
Schemas.HP = "hp"
Schemas.RED = "red"
Schemas.BLUE = "blue"

-- The one packet a bench row fires, under the name those rows reach it by.
Schemas.BEAT = "beat"

-- A set keyed by a field, as the definitions one machine requires.
function Schemas.roster (): any
    return {
        [Schemas.ROSTER] = Lync.replicate (Lync.struct ({
            [Schemas.TEAM] = Lync.enum ({ Schemas.RED, Schemas.BLUE }),
            [Schemas.HP] = Lync.int (0, HEALTH),
        })):keyBy (Schemas.TEAM),
    }
end

-- One packet over a motion codec, which is what a bench row measures a fire of.
function Schemas.beat (): any return { [Schemas.BEAT] = Lync.packet (Schemas.motion.codec) } end

-- The value a fixture files under a name.
function Schemas.cased (of: Fixture, name: string): any
    for _, one in of.cases do
        if one.name == name then return one.value end
    end
    error (`{of.name} has no case named {name}`, 0)
end

--[[
    A payload of exactly this many bytes, for the ladder a live run walks across the unreliable
    cap. It is a function rather than a fixture because the sizes worth probing are the ones the
    measurement chooses, not ones committed here.
]]
function Schemas.ladder (bytes: number): Lync.Codec<buffer>
    assert (bytes >= 0 and bytes % 1 == 0, `a ladder rung wants whole bytes, got {bytes}`)
    return Lync.buffer (bytes, bytes)
end

return table.freeze (Schemas)
