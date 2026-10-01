--!strict
--!optimize 2
-- The pinned artifacts: what a schema reads as, hashes to and costs, and what a scenario ships.

local Golden = {}

-- The canonical text each fixture schema writes.
Golden.descriptors = table.freeze({
    flag = "bool()",
    nothing = "empty()",
    entity = 'struct(){"facing"=int(0,255);"id"=int(0,255);"pose"=int(0,255);"x"=int(0,255);"y'
        .. '"=int(0,255);"z"=int(0,255);}',
    motion = 'struct(){"at"=vec3(components){"component"=quant(-1024,1024,0.05);};"facing"=vec'
        .. '3(unit,1);"lean"=angle(0.5);"speed"=quant(0,100,0.25);}',
    profile = 'struct(){"name"=str(1,20);"perks"=bitfield(["flight","haste","shield","vision"])'
        .. ';"tag"=str("abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ",3,8)'
        .. ';"team"=enum(["blue","red","spectator"]);"title"=optional(){"inner"=str(1,24);};'
        .. "}",
    inventory = 'struct(){"purse"=map(0,3){"key"=enum(["gold","shard","silver"]);"value"=vlq();};'
        .. '"slots"=array(0,32){"element"=struct(){"count"=int(1,99);"item"=enum(["potion","'
        .. 'rope","shield","sword"]);};};}',
    everything = 'struct(){"carry"=vec3(components):newest{"component"=quant(-1024,1024,0.05);};"c'
        .. 'heap"=color3(rgb565);"colour"=str("0123456789abcde'
        .. 'f",6,6);"count"=int(0,1000);"double"=f64();"event"=tagged("kind"){"score"=struct'
        .. '(){"points"=int(0,100);};"spawn"=struct(){"at"=vec3(components);};};"facing"=vec'
        .. '3(unit,1);"fixed"=rotation(none);"flag"=bool();"flat"=vec2();"frame"=cframe(){"p'
        .. 'osition"=vec3(components);"rotation"=rotation(quat,1);};"handle"=str("abcdefghij'
        .. 'klmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ",1,12);"heading"=angle(0.5)'
        .. ';"label"=str(0,24);"letters"=str("abc",0,6);"list"=array(0,8){"element"=int(0,63'
        .. ');};"nested"=struct(){"far"=int(0,15);"near"=int(0,15);};"offset"=vli();"payload'
        .. '"=buffer(0,32);"perks"=bitfield(["flight","haste","shield","vision"]);"place"=ve'
        .. 'c3(components);"purse"=map(0,2){"key"=enum(["gold","silver"]);"value"=vlq();};"r'
        .. 'atio"=quant(-1,1,0.001);"scaled"=int(0,255);"single"=f32();"source"=inst();"tall'
        .. 'y"=vlq();"team"=enum(["blue","red","spectator"]);"tint"=color3(components);"titl'
        .. 'e"=optional(){"inner"=str(1,24);};"turn"=rotation(quat,1);}',
} :: { [string]: string })

-- The number each of those texts folds to.
Golden.hashes = table.freeze({
    flag = "5558F0811D9D2532",
    nothing = "6474C28F2BF14261",
    entity = "D21AFA20EF07FF6A",
    motion = "8A9F2243D0FE64B4",
    profile = "0D1698C53E50B9A9",
    inventory = "6A613C5F0A00DFEF",
    everything = "8B423F59BD9E1D48",
} :: { [string]: string })

-- What each fixture case costs on the wire, in bytes.
Golden.sizes = table.freeze({
    ["flag.off"] = 1,
    ["flag.on"] = 1,
    ["nothing.only"] = 0,
    ["entity.smallest"] = 6,
    ["entity.typical"] = 6,
    ["entity.largest"] = 6,
    ["motion.still"] = 11,
    ["motion.typical"] = 11,
    ["motion.largest"] = 11,
    ["profile.shortest"] = 6,
    ["profile.typical"] = 24,
    ["profile.longest"] = 53,
    ["inventory.empty"] = 1,
    ["inventory.one"] = 5,
    ["inventory.typical"] = 11,
    ["inventory.largest"] = 78,
    ["everything.smallest"] = 93,
    ["everything.typical"] = 126,
    ["everything.largest"] = 221,
} :: { [string]: number })

-- The bytes each fixture scenario puts on the wire, per flush.
Golden.frames = table.freeze({
    ["fill.keyframe"] = table.freeze({
        "all reliable 0081010102027f0028ff0028ff00280007ff0007ff00070003ff0003ff0003000af"
            .. "f000aff000a0014ff0014ff0014001eff001eff001e",
    }),
    ["drift.keyframe"] = table.freeze({
        "all reliable 0081010102027f0028ff0028ff00280007ff0007ff00070003ff0003ff0003000af"
            .. "f000aff000a0014ff0014ff0014001eff001eff001e",
    }),
    ["drift.delta"] = table.freeze({
        "all reliable 01b08101012a2a2a2a2a2a2a2a",
    }),
    ["parted.keyframe"] = table.freeze({
        "all reliable 0081010102027f0028ff0028ff00280007ff0007ff00070003ff0003ff0003000af"
            .. "f000aff000a0014ff0014ff0014001eff001eff001e",
    }),
    ["parted.delta"] = table.freeze({
        "all reliable 013100810101aa2a2a2a2a552a2a2a2a",
    }),
    ["quiet.keyframe"] = table.freeze({
        "all reliable 0081010102027f0028ff0028ff00280007ff0007ff00070003ff0003ff0003000af"
            .. "f000aff000a0014ff0014ff0014001eff001eff001e",
    }),
    ["quiet.unchanged"] = table.freeze({
        "",
    }),
    ["quiet.empty"] = table.freeze({
        "",
    }),
    ["coalesce.keyframe"] = table.freeze({
        "all reliable 00100100022807030a141e",
    }),
    ["coalesce.net"] = table.freeze({
        "all reliable 01b0100121",
    }),
    ["fleeting.cancelled"] = table.freeze({
        "",
    }),
    ["fleeting.merged"] = table.freeze({
        "all reliable 0010010004000000070000",
    }),
    ["fleeting.replaced"] = table.freeze({
        "all reliable 0210010010020004ffffffffffff",
    }),
    ["sweep.keyframe"] = table.freeze({
        "all reliable 0081010102027f0028ff0028ff00280007ff0007ff00070003ff0003ff0003000af"
            .. "f000aff000a0014ff0014ff0014001eff001eff001e",
    }),
    ["sweep.cleared"] = table.freeze({
        "all reliable 03",
    }),
    ["migrate.granted"] = table.freeze({
        "a reliable 000110010002006100004020000100",
        "b reliable 0000100100040741737065637465720c0280f4681b00010857617966696e646572",
        "c reliable 0002100100061357575757575757575757575757575757575757570f057ddff77ddff"
            .. "7020117515151515151515151515151515151515151515151515151",
    }),
    ["migrate.migrated"] = table.freeze({
        "a reliable 02011001",
        "b reliable 000010020002006100004020000000",
    }),
    ["migrate.replaced"] = table.freeze({
        "a reliable 0000210100040107417370656374657200610c000280f4681b0040200000010857617"
            .. "966696e64657200",
        "b reliable 02002101",
    }),
    ["visitors.keyframe"] = table.freeze({
        "all reliable 0081010102027f0028ff0028ff00280007ff0007ff00070003ff0003ff0003000af"
            .. "f000aff000a0014ff0014ff0014001eff001eff001e",
    }),
    ["visitors.catch-up"] = table.freeze({
        "b reliable 0081010102027f0028ff0028ff00280007ff0007ff00070003ff0003ff0003000aff0"
            .. "00aff000a0014ff0014ff0014001eff001eff001e",
    }),
    ["visitors.after-leave"] = table.freeze({
        "",
    }),
    ["starve.prefix"] = table.freeze({
        "all reliable 00e105010202ffffffffff1f0028ff0028ff0028ff0028ff0028ff0028ff0028ff0"
            .. "028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff000007ff0007ff0007ff0007ff0007ff0"
            .. "007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff000003ff0003ff0003ff0"
            .. "003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff00000aff0"
            .. "00aff000aff000aff000aff000aff000aff000aff000aff000aff000aff000aff000aff000aff000"
            .. "aff000014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff001"
            .. "4ff0014ff0014ff00001eff001eff001eff001eff001eff001eff001eff001eff001eff001eff001"
            .. "eff001eff001eff001eff001eff0000e1052f025effffffffff1f28ff0028ff0028ff0028ff0028f"
            .. "f0028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff002807ff0007ff0007f"
            .. "f0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff000703f"
            .. "f0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0"
            .. "003ff00030aff000aff000aff000aff000aff000aff000aff000aff000aff000aff000aff000aff0"
            .. "00aff000aff000aff000a14ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0"
            .. "014ff0014ff0014ff0014ff0014ff00141eff001eff001eff001eff001eff001eff001eff001eff0"
            .. "01eff001eff001eff001eff001eff001eff001eff001e00e1055d02ba01ffffffffff1fff0028ff0"
            .. "028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff002"
            .. "8ffff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff000"
            .. "7ff0007ff0007ffff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff000"
            .. "3ff0003ff0003ff0003ff0003ffff000aff000aff000aff000aff000aff000aff000aff000aff000"
            .. "aff000aff000aff000aff000aff000aff000affff0014ff0014ff0014ff0014ff0014ff0014ff001"
            .. "4ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ffff001eff001eff001eff001eff001"
            .. "eff001eff001eff001eff001eff001eff001eff001eff001eff001eff001eff",
    }),
    ["starve.drain"] = table.freeze({
        "all reliable 00e1058b01029602ffffffffff1f0028ff0028ff0028ff0028ff0028ff0028ff002"
            .. "8ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff000007ff0007ff0007ff0007ff000"
            .. "7ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff000003ff0003ff000"
            .. "3ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff00000"
            .. "aff000aff000aff000aff000aff000aff000aff000aff000aff000aff000aff000aff000aff000af"
            .. "f000aff000014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0014f"
            .. "f0014ff0014ff0014ff00001eff001eff001eff001eff001eff001eff001eff001eff001eff001ef"
            .. "f001eff001eff001eff001eff001eff0000e105b90102f202ffffffffff1f28ff0028ff0028ff002"
            .. "8ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff002807ff000"
            .. "7ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007f"
            .. "f000703ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003f"
            .. "f0003ff0003ff00030aff000aff000aff000aff000aff000aff000aff000aff000aff000aff000af"
            .. "f000aff000aff000aff000aff000a14ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0014f"
            .. "f0014ff0014ff0014ff0014ff0014ff0014ff00141eff001eff001eff001eff001eff001eff001ef"
            .. "f001eff001eff001eff001eff001eff001eff001eff001eff001e00a103e70102ce03ffffff01ff0"
            .. "028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff00ff0007ff0007ff0007ff0007ff0007f"
            .. "f0007ff0007ff0007ff00ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff00ff000af"
            .. "f000aff000aff000aff000aff000aff000aff000aff00ff0014ff0014ff0014ff0014ff0014ff001"
            .. "4ff0014ff0014ff00ff001eff001eff001eff001eff001eff001eff001eff001eff00",
    }),
    ["storm.keyframe"] = table.freeze({
        "all reliable 00e105010202ffffffffff1f0028ff0028ff0028ff0028ff0028ff0028ff0028ff0"
            .. "028ff0028ff0028ff0028ff0028ff0028ff0028ff0028ff000007ff0007ff0007ff0007ff0007ff0"
            .. "007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff0007ff000003ff0003ff0003ff0"
            .. "003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff0003ff00000aff0"
            .. "00aff000aff000aff000aff000aff000aff000aff000aff000aff000aff000aff000aff000aff000"
            .. "aff000014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff0014ff001"
            .. "4ff0014ff0014ff00001eff001eff001eff001eff001eff001eff001eff001eff001eff001eff001"
            .. "eff001eff001eff001eff001eff0000a1022f025effff0128ff0028ff0028ff0028ff0028ff0028f"
            .. "f0007ff0007ff0007ff0007ff0007ff0007ff0003ff0003ff0003ff0003ff0003ff0003ff000aff0"
            .. "00aff000aff000aff000aff000aff0014ff0014ff0014ff0014ff0014ff0014ff001eff001eff001"
            .. "eff001eff001eff001eff00",
    }),
    ["storm.round-1"] = table.freeze({
        "all reliable 01b0810801070707070707070707070707070707070707070707070707070707070"
            .. "70707070707070707070707070707070707070707070707070707070707070707070707",
    }),
    ["storm.round-2"] = table.freeze({
        "all reliable 01b08108010e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0"
            .. "e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e",
    }),
    ["storm.round-3"] = table.freeze({
        "all reliable 01b0810801151515151515151515151515151515151515151515151515151515151"
            .. "51515151515151515151515151515151515151515151515151515151515151515151515",
    }),
    ["storm.round-4"] = table.freeze({
        "all reliable 01b08108011c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1"
            .. "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c",
    }),
    ["storm.round-5"] = table.freeze({
        "all reliable 01b0810801232323232323232323232323232323232323232323232323232323232"
            .. "32323232323232323232323232323232323232323232323232323232323232323232323",
    }),
    ["acceptance.keyframe"] = table.freeze({
        "a reliable 000110010002000050005000500000000000000000000000000000000000b4b4000000000"
            .. "0000000000000000000000000000000006b6969010000000000000000000000000000000000000000"
            .. "0000000000000000000000000001000000000000000000000000006b696901",
    }),
    ["acceptance.delta"] = table.freeze({
        "a reliable 01017dfeffabffffff0110011044a1b2c3f403555555555555d53f010000c03f000000000"
            .. "00020c0010000003f000080be0000c03f00000000000020c0d06ad10207f3026044a46de802046c79"
            .. "6e63062409038130003c21046c796e630c0000c03f00001040000070c00100f001c413800000003f8"
            .. "0200000003f0000803e0000403f68d1d202",
        "a unreliable 000400000110010019500a50c94f",
    }),
    ["acceptance.cleared"] = table.freeze({
        "",
    }),
    ["acceptance.newest"] = table.freeze({
        "a unreliable 0008000001100100325000506450",
    }),
    ["acceptance.idle"] = table.freeze({
        "",
    }),
    ["acceptance.removed"] = table.freeze({
        "a reliable 02011001",
    }),
} :: { [string]: { string } })

return table.freeze(Golden)
