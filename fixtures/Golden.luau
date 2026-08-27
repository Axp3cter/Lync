--!strict
--!optimize 2
-- The pinned artifacts: what every fixture schema reads as, hashes to, and costs on the wire.

local Golden = {}

-- Public --------------------------------------------------------------

-- The canonical text each fixture schema writes.
Golden.descriptors = table.freeze ({
    ["flag"] = "bool()",
    ["entity"] = 'struct(){"facing"=int(0,255);"id"=int(0,25'
        .. '5);"pose"=int(0,255);"x"=int(0,255);"y"=in'
        .. 't(0,255);"z"=int(0,255);}',
    ["motion"] = 'struct(){"at"=vec3(components){"component"'
        .. '=quant(-1024,1024,0.05);};"facing"=vec3(un'
        .. 'it,1);"lean"=angle(0.5);"speed"=quant(0,10'
        .. "0,0.25);}",
    ["profile"] = 'struct(){"name"=str(1,20);"perks"=bitfield'
        .. '(["flight","haste","shield","vision"]);"ta'
        .. 'g"=str("abcdefghijklmnopqrstuvwxyz01234567'
        .. '89ABCDEFGHIJKLMNOPQRSTUVWXYZ",3,8);"team"='
        .. 'enum(["blue","red","spectator"]);"title"=o'
        .. 'ptional(){"inner"=str(1,24);};}',
    ["inventory"] = 'struct(){"purse"=map(0,3){"key"=enum(["gol'
        .. 'd","shard","silver"]);"value"=vlq();};"slo'
        .. 'ts"=array(0,32){"element"=struct(){"count"'
        .. '=int(1,99);"item"=enum(["potion","rope","s'
        .. 'hield","sword"]);};};}',
    ["everything"] = 'struct(){"aim"=rotation(direction,1);"carr'
        .. 'y"=vec3(components):newest{"component"=qua'
        .. 'nt(-1024,1024,0.05);};"cheap"=color3(rgb56'
        .. '5);"checked"=int(0,100):validate;"colour"='
        .. 'str("0123456789abcdef",6,6);"count"=int(0,'
        .. '1000);"digits"=str("0123456789",0,6);"doub'
        .. 'le"=f64();"event"=tagged("kind"){"score"=s'
        .. 'truct(){"points"=int(0,100);};"spawn"=stru'
        .. 'ct(){"at"=vec3(components);};};"facing"=ve'
        .. 'c3(unit,1);"fixed"=rotation(none);"flag"=b'
        .. 'ool();"flat"=vec2();"frame"=cframe(){"posi'
        .. 'tion"=vec3(components);"rotation"=rotation'
        .. '(quat,1);};"handle"=str("abcdefghijklmnopq'
        .. "rstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVW"
        .. 'XYZ",1,12);"heading"=angle(0.5);"label"=st'
        .. 'r(0,24);"letters"=str("abc",0,6);"list"=ar'
        .. 'ray(0,8){"element"=int(0,63);};"nested"=st'
        .. 'ruct(){"far"=int(0,15);"near"=int(0,15);};'
        .. '"offset"=vli();"packed"=str("ABCDEFGHIJKLM'
        .. "NOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz012"
        .. '3456789+/",0,8);"payload"=buffer(0,32);"pe'
        .. 'rks"=bitfield(["flight","haste","shield","'
        .. 'vision"]);"place"=vec3(components);"purse"'
        .. '=map(0,2){"key"=enum(["gold","silver"]);"v'
        .. 'alue"=vlq();};"push"=vec3(bounded,64,0.25)'
        .. ';"ratio"=quant(-1,1,0.001);"scaled"=int(0,'
        .. '255);"score"=vlq():monotonic;"single"=f32('
        .. ');"source"=inst();"spin"=rotation(axis,[0,'
        .. '1,0],1);"swatch"=color3(palette,[[0,0,0],['
        .. '1,0,0],[0,1,0],[0,0,1]]);"tally"=vlq();"te'
        .. 'am"=enum(["blue","red","spectator"]);"tint'
        .. '"=color3(components);"title"=optional(){"i'
        .. 'nner"=str(1,24);};"token"=str("ABCDEFGHIJK'
        .. 'LMNOPQRSTUVWXYZ234567",0,8);"turn"=rotatio'
        .. "n(quat,1);}",
} :: { [string]: string })

-- The number each of those texts folds to.
Golden.hashes = table.freeze ({
    ["flag"] = "5558F0811D9D2532",
    ["entity"] = "D21AFA20EF07FF6A",
    ["motion"] = "8A9F2243D0FE64B4",
    ["profile"] = "0D1698C53E50B9A9",
    ["inventory"] = "6A613C5F0A00DFEF",
    ["everything"] = "0CD1494A53FB042A",
} :: { [string]: string })

-- What each fixture case costs on the wire, in bytes.
Golden.sizes = table.freeze ({
    ["flag.off"] = 1,
    ["flag.on"] = 1,
    ["entity.smallest"] = 6,
    ["entity.typical"] = 6,
    ["entity.largest"] = 6,
    ["motion.still"] = 11,
    ["motion.typical"] = 11,
    ["motion.largest"] = 11,
    ["profile.shortest"] = 7,
    ["profile.typical"] = 25,
    ["profile.longest"] = 54,
    ["inventory.empty"] = 2,
    ["inventory.one"] = 6,
    ["inventory.typical"] = 12,
    ["inventory.largest"] = 79,
    ["everything.smallest"] = 107,
    ["everything.typical"] = 151,
    ["everything.largest"] = 256,
} :: { [string]: number })

-- The bytes each fixture scenario puts on the wire, per flush.
Golden.frames = table.freeze ({
    ["fill.keyframe"] = table.freeze ({
        "all reliable 0081010102027f0028ff0028ff002"
            .. "80007ff0007ff00070003ff0003ff0003000aff000"
            .. "aff000a0014ff0014ff0014001eff001eff001e",
    }),
    ["drift.keyframe"] = table.freeze ({
        "all reliable 0081010102027f0028ff0028ff002"
            .. "80007ff0007ff00070003ff0003ff0003000aff000"
            .. "aff000a0014ff0014ff0014001eff001eff001e",
    }),
    ["drift.delta"] = table.freeze ({
        "all reliable 01b08101012a2a2a2a2a2a2a2a",
    }),
    ["quiet.keyframe"] = table.freeze ({
        "all reliable 0081010102027f0028ff0028ff002"
            .. "80007ff0007ff00070003ff0003ff0003000aff000"
            .. "aff000a0014ff0014ff0014001eff001eff001e",
    }),
    ["quiet.unchanged"] = table.freeze ({
        "",
    }),
    ["quiet.empty"] = table.freeze ({
        "",
    }),
    ["coalesce.keyframe"] = table.freeze ({
        "all reliable 00100100022807030a141e",
    }),
    ["coalesce.net"] = table.freeze ({
        "all reliable 01b0100121",
    }),
    ["fleeting.cancelled"] = table.freeze ({
        "",
    }),
    ["fleeting.merged"] = table.freeze ({
        "all reliable 0010010004000000070000",
    }),
    ["fleeting.replaced"] = table.freeze ({
        "all reliable 0210010010020004ffffffffffff",
    }),
    ["sweep.keyframe"] = table.freeze ({
        "all reliable 0081010102027f0028ff0028ff002"
            .. "80007ff0007ff00070003ff0003ff0003000aff000"
            .. "aff000a0014ff0014ff0014001eff001eff001e",
    }),
    ["sweep.cleared"] = table.freeze ({
        "all reliable 03",
    }),
    ["migrate.granted"] = table.freeze ({
        "a reliable 000110010002006100004020000100",
        "b reliable 0000100100040741737065637465720c0280f4681b00010857617966696e646572",
        "c reliable 0002100100061357575757575757575"
            .. "757575757575757575757570f057ddff77ddff7020"
            .. "117515151515151515151515151515151515151515"
            .. "151515151",
    }),
    ["migrate.migrated"] = table.freeze ({
        "a reliable 02011001",
        "b reliable 000010020002006100004020000000",
    }),
    ["migrate.replaced"] = table.freeze ({
        "a reliable 0000210100040107417370656374657"
            .. "200610c000280f4681b00402000000108576179666"
            .. "96e64657200",
        "b reliable 02002101",
    }),
    ["visitors.keyframe"] = table.freeze ({
        "all reliable 0081010102027f0028ff0028ff002"
            .. "80007ff0007ff00070003ff0003ff0003000aff000"
            .. "aff000a0014ff0014ff0014001eff001eff001e",
    }),
    ["visitors.catch-up"] = table.freeze ({
        "b reliable 0081010102027f0028ff0028ff00280"
            .. "007ff0007ff00070003ff0003ff0003000aff000af"
            .. "f000a0014ff0014ff0014001eff001eff001e",
    }),
    ["visitors.after-leave"] = table.freeze ({
        "",
    }),
    ["starve.prefix"] = table.freeze ({
        "all reliable 00e105010202ffffffffff1f0028f"
            .. "f0028ff0028ff0028ff0028ff0028ff0028ff0028f"
            .. "f0028ff0028ff0028ff0028ff0028ff0028ff0028f"
            .. "f000007ff0007ff0007ff0007ff0007ff0007ff000"
            .. "7ff0007ff0007ff0007ff0007ff0007ff0007ff000"
            .. "7ff0007ff000003ff0003ff0003ff0003ff0003ff0"
            .. "003ff0003ff0003ff0003ff0003ff0003ff0003ff0"
            .. "003ff0003ff0003ff00000aff000aff000aff000af"
            .. "f000aff000aff000aff000aff000aff000aff000af"
            .. "f000aff000aff000aff000aff000014ff0014ff001"
            .. "4ff0014ff0014ff0014ff0014ff0014ff0014ff001"
            .. "4ff0014ff0014ff0014ff0014ff0014ff00001eff0"
            .. "01eff001eff001eff001eff001eff001eff001eff0"
            .. "01eff001eff001eff001eff001eff001eff001eff0"
            .. "000e1052f025effffffffff1f28ff0028ff0028ff0"
            .. "028ff0028ff0028ff0028ff0028ff0028ff0028ff0"
            .. "028ff0028ff0028ff0028ff0028ff002807ff0007f"
            .. "f0007ff0007ff0007ff0007ff0007ff0007ff0007f"
            .. "f0007ff0007ff0007ff0007ff0007ff0007ff00070"
            .. "3ff0003ff0003ff0003ff0003ff0003ff0003ff000"
            .. "3ff0003ff0003ff0003ff0003ff0003ff0003ff000"
            .. "3ff00030aff000aff000aff000aff000aff000aff0"
            .. "00aff000aff000aff000aff000aff000aff000aff0"
            .. "00aff000aff000a14ff0014ff0014ff0014ff0014f"
            .. "f0014ff0014ff0014ff0014ff0014ff0014ff0014f"
            .. "f0014ff0014ff0014ff00141eff001eff001eff001"
            .. "eff001eff001eff001eff001eff001eff001eff001"
            .. "eff001eff001eff001eff001eff001e00e1055d02b"
            .. "a01ffffffffff1fff0028ff0028ff0028ff0028ff0"
            .. "028ff0028ff0028ff0028ff0028ff0028ff0028ff0"
            .. "028ff0028ff0028ff0028ffff0007ff0007ff0007f"
            .. "f0007ff0007ff0007ff0007ff0007ff0007ff0007f"
            .. "f0007ff0007ff0007ff0007ff0007ffff0003ff000"
            .. "3ff0003ff0003ff0003ff0003ff0003ff0003ff000"
            .. "3ff0003ff0003ff0003ff0003ff0003ff0003ffff0"
            .. "00aff000aff000aff000aff000aff000aff000aff0"
            .. "00aff000aff000aff000aff000aff000aff000aff0"
            .. "00affff0014ff0014ff0014ff0014ff0014ff0014f"
            .. "f0014ff0014ff0014ff0014ff0014ff0014ff0014f"
            .. "f0014ff0014ffff001eff001eff001eff001eff001"
            .. "eff001eff001eff001eff001eff001eff001eff001"
            .. "eff001eff001eff001eff",
        "all reliable 00e1058b01029602ffffffffff1f0"
            .. "028ff0028ff0028ff0028ff0028ff0028ff0028ff0"
            .. "028ff0028ff0028ff0028ff0028ff0028ff0028ff0"
            .. "028ff000007ff0007ff0007ff0007ff0007ff0007f"
            .. "f0007ff0007ff0007ff0007ff0007ff0007ff0007f"
            .. "f0007ff0007ff000003ff0003ff0003ff0003ff000"
            .. "3ff0003ff0003ff0003ff0003ff0003ff0003ff000"
            .. "3ff0003ff0003ff0003ff00000aff000aff000aff0"
            .. "00aff000aff000aff000aff000aff000aff000aff0"
            .. "00aff000aff000aff000aff000aff000014ff0014f"
            .. "f0014ff0014ff0014ff0014ff0014ff0014ff0014f"
            .. "f0014ff0014ff0014ff0014ff0014ff0014ff00001"
            .. "eff001eff001eff001eff001eff001eff001eff001"
            .. "eff001eff001eff001eff001eff001eff001eff001"
            .. "eff0000e105b90102f202ffffffffff1f28ff0028f"
            .. "f0028ff0028ff0028ff0028ff0028ff0028ff0028f"
            .. "f0028ff0028ff0028ff0028ff0028ff0028ff00280"
            .. "7ff0007ff0007ff0007ff0007ff0007ff0007ff000"
            .. "7ff0007ff0007ff0007ff0007ff0007ff0007ff000"
            .. "7ff000703ff0003ff0003ff0003ff0003ff0003ff0"
            .. "003ff0003ff0003ff0003ff0003ff0003ff0003ff0"
            .. "003ff0003ff00030aff000aff000aff000aff000af"
            .. "f000aff000aff000aff000aff000aff000aff000af"
            .. "f000aff000aff000aff000a14ff0014ff0014ff001"
            .. "4ff0014ff0014ff0014ff0014ff0014ff0014ff001"
            .. "4ff0014ff0014ff0014ff0014ff00141eff001eff0"
            .. "01eff001eff001eff001eff001eff001eff001eff0"
            .. "01eff001eff001eff001eff001eff001eff001e00a"
            .. "103e70102ce03ffffff01ff0028ff0028ff0028ff0"
            .. "028ff0028ff0028ff0028ff0028ff00ff0007ff000"
            .. "7ff0007ff0007ff0007ff0007ff0007ff0007ff00f"
            .. "f0003ff0003ff0003ff0003ff0003ff0003ff0003f"
            .. "f0003ff00ff000aff000aff000aff000aff000aff0"
            .. "00aff000aff000aff00ff0014ff0014ff0014ff001"
            .. "4ff0014ff0014ff0014ff0014ff00ff001eff001ef"
            .. "f001eff001eff001eff001eff001eff001eff00",
    }),
    ["starve.drain"] = table.freeze ({
        "",
    }),
    ["storm.keyframe"] = table.freeze ({
        "all reliable 00e105010202ffffffffff1f0028f"
            .. "f0028ff0028ff0028ff0028ff0028ff0028ff0028f"
            .. "f0028ff0028ff0028ff0028ff0028ff0028ff0028f"
            .. "f000007ff0007ff0007ff0007ff0007ff0007ff000"
            .. "7ff0007ff0007ff0007ff0007ff0007ff0007ff000"
            .. "7ff0007ff000003ff0003ff0003ff0003ff0003ff0"
            .. "003ff0003ff0003ff0003ff0003ff0003ff0003ff0"
            .. "003ff0003ff0003ff00000aff000aff000aff000af"
            .. "f000aff000aff000aff000aff000aff000aff000af"
            .. "f000aff000aff000aff000aff000014ff0014ff001"
            .. "4ff0014ff0014ff0014ff0014ff0014ff0014ff001"
            .. "4ff0014ff0014ff0014ff0014ff0014ff00001eff0"
            .. "01eff001eff001eff001eff001eff001eff001eff0"
            .. "01eff001eff001eff001eff001eff001eff001eff0"
            .. "000a1022f025effff0128ff0028ff0028ff0028ff0"
            .. "028ff0028ff0007ff0007ff0007ff0007ff0007ff0"
            .. "007ff0003ff0003ff0003ff0003ff0003ff0003ff0"
            .. "00aff000aff000aff000aff000aff000aff0014ff0"
            .. "014ff0014ff0014ff0014ff0014ff001eff001eff0"
            .. "01eff001eff001eff001eff00",
    }),
    ["storm.round-1"] = table.freeze ({
        "all reliable 01b08108010707070707070707070"
            .. "707070707070707070707070707070707070707070"
            .. "707070707070707070707070707070707070707070"
            .. "7070707070707070707070707",
    }),
    ["storm.round-2"] = table.freeze ({
        "all reliable 01b08108010e0e0e0e0e0e0e0e0e0"
            .. "e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0"
            .. "e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0"
            .. "e0e0e0e0e0e0e0e0e0e0e0e0e",
    }),
    ["storm.round-3"] = table.freeze ({
        "all reliable 01b08108011515151515151515151"
            .. "515151515151515151515151515151515151515151"
            .. "515151515151515151515151515151515151515151"
            .. "5151515151515151515151515",
    }),
    ["storm.round-4"] = table.freeze ({
        "all reliable 01b08108011c1c1c1c1c1c1c1c1c1"
            .. "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1"
            .. "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1"
            .. "c1c1c1c1c1c1c1c1c1c1c1c1c",
    }),
    ["storm.round-5"] = table.freeze ({
        "all reliable 01b08108012323232323232323232"
            .. "323232323232323232323232323232323232323232"
            .. "323232323232323232323232323232323232323232"
            .. "3232323232323232323232323",
    }),
    ["acceptance.keyframe"] = table.freeze ({
        "a reliable 00011001000200b4b40050005000500"
            .. "0000000000000000000000000000000000000b4b40"
            .. "000000000000000000000000000000000000000006"
            .. "b69690100000000000000000000000000000000000"
            .. "000000000000000000104000000000000000000000"
            .. "00000000100000000000000000000000000006b696"
            .. "901",
    }),
    ["acceptance.delta"] = table.freeze ({
        "a reliable 0101fbf3ffbfaeffffffff0310015ab"
            .. "410442da1b2c3f403030007555555555555d53f010"
            .. "000c03f00000000000020c0010000003f000080be0"
            .. "000c03f00000000000020c06969d10207f3026044a"
            .. "46de802046c796e63062409038130003c21065a46f"
            .. "7fe0f046c796e630c0000c03f00001040000070c00"
            .. "100f00100010802c413010000003f5a00018020000"
            .. "0003f0000803e0000403f062008bd396a69d102",
        "a unreliable 011000000110010019500a50c94f",
    }),
    ["acceptance.cleared"] = table.freeze ({
        "",
    }),
    ["acceptance.newest"] = table.freeze ({
        "a unreliable 0120000001100100325000506450",
    }),
    ["acceptance.idle"] = table.freeze ({
        "",
    }),
    ["acceptance.removed"] = table.freeze ({
        "a reliable 02011001",
    }),
} :: { [string]: { string } })

return table.freeze (Golden)
