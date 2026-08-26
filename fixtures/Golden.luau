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
        "all reliable 0041017f020406080a0c0e100028f"
            .. "f0028ff00280007ff0007ff00070003ff0003ff000"
            .. "3000aff000aff000a0014ff0014ff0014001eff001"
            .. "eff001e",
    }),
    ["drift.keyframe"] = table.freeze ({
        "all reliable 0041017f020406080a0c0e100028f"
            .. "f0028ff00280007ff0007ff00070003ff0003ff000"
            .. "3000aff000aff000a0014ff0014ff0014001eff001"
            .. "eff001e",
    }),
    ["drift.delta"] = table.freeze ({
        "all reliable 01b041017f2a2a2a2a2a2a2a2a",
    }),
    ["quiet.keyframe"] = table.freeze ({
        "all reliable 0041017f020406080a0c0e100028f"
            .. "f0028ff00280007ff0007ff00070003ff0003ff000"
            .. "3000aff000aff000a0014ff0014ff0014001eff001"
            .. "eff001e",
    }),
    ["quiet.unchanged"] = table.freeze ({
        "",
    }),
    ["quiet.empty"] = table.freeze ({
        "",
    }),
    ["coalesce.keyframe"] = table.freeze ({
        "all reliable 000801022807030a141e",
    }),
    ["coalesce.net"] = table.freeze ({
        "all reliable 01b0080121",
    }),
    ["fleeting.cancelled"] = table.freeze ({
        "",
    }),
    ["fleeting.merged"] = table.freeze ({
        "all reliable 00080104000000070000",
    }),
    ["fleeting.replaced"] = table.freeze ({
        "all reliable 02080100080204ffffffffffff",
    }),
    ["sweep.keyframe"] = table.freeze ({
        "all reliable 0041017f020406080a0c0e100028f"
            .. "f0028ff00280007ff0007ff00070003ff0003ff000"
            .. "3000aff000aff000a0014ff0014ff0014001eff001"
            .. "eff001e",
    }),
    ["sweep.cleared"] = table.freeze ({
        "all reliable 03",
    }),
    ["migrate.granted"] = table.freeze ({
        "a reliable 0001080102006100004020000100",
        "b reliable 00000801040741737065637465720c0280f4681b00010857617966696e646572",
        "c reliable 0002080106135757575757575757575"
            .. "7575757575757575757570f057ddff77ddff702011"
            .. "751515151515151515151515151515151515151515"
            .. "1515151",
    }),
    ["migrate.migrated"] = table.freeze ({
        "a reliable 02010801",
        "b reliable 0000080202006100004020000000",
    }),
    ["migrate.replaced"] = table.freeze ({
        "a reliable 0000100101040207417370656374657"
            .. "200610c000280f4681b00402000000108576179666"
            .. "96e64657200",
        "b reliable 0200100101",
    }),
    ["visitors.keyframe"] = table.freeze ({
        "all reliable 0041017f020406080a0c0e100028f"
            .. "f0028ff00280007ff0007ff00070003ff0003ff000"
            .. "3000aff000aff000a0014ff0014ff0014001eff001"
            .. "eff001e",
    }),
    ["visitors.catch-up"] = table.freeze ({
        "b reliable 0041017f020406080a0c0e100028ff0"
            .. "028ff00280007ff0007ff00070003ff0003ff00030"
            .. "00aff000aff000a0014ff0014ff0014001eff001ef"
            .. "f001e",
    }),
    ["visitors.after-leave"] = table.freeze ({
        "",
    }),
    ["starve.prefix"] = table.freeze ({
        "all reliable 00f10201ffffffffff1f020406080"
            .. "a0c0e10121416181a1c1e20222426282a2c2e30323"
            .. "436383a3c3e40424446484a4c4e50525456585a5c0"
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
            .. "eff0000f1022fffffffffff1f5e60626466686a6c6"
            .. "e70727476787a7c7e800182018401860188018a018"
            .. "c018e01900192019401960198019a019c019e01a00"
            .. "1a201a401a601a801aa01ac01ae01b001b201b401b"
            .. "601b80128ff0028ff0028ff0028ff0028ff0028ff0"
            .. "028ff0028ff0028ff0028ff0028ff0028ff0028ff0"
            .. "028ff0028ff002807ff0007ff0007ff0007ff0007f"
            .. "f0007ff0007ff0007ff0007ff0007ff0007ff0007f"
            .. "f0007ff0007ff0007ff000703ff0003ff0003ff000"
            .. "3ff0003ff0003ff0003ff0003ff0003ff0003ff000"
            .. "3ff0003ff0003ff0003ff0003ff00030aff000aff0"
            .. "00aff000aff000aff000aff000aff000aff000aff0"
            .. "00aff000aff000aff000aff000aff000aff000a14f"
            .. "f0014ff0014ff0014ff0014ff0014ff0014ff0014f"
            .. "f0014ff0014ff0014ff0014ff0014ff0014ff0014f"
            .. "f00141eff001eff001eff001eff001eff001eff001"
            .. "eff001eff001eff001eff001eff001eff001eff001"
            .. "eff001eff001e",
        "all reliable 00f1025dffffffffff1fba01bc01b"
            .. "e01c001c201c401c601c801ca01cc01ce01d001d20"
            .. "1d401d601d801da01dc01de01e001e201e401e601e"
            .. "801ea01ec01ee01f001f201f401f601f801fa01fc0"
            .. "1fe01800282028402860288028a028c028e0290029"
            .. "2029402ff0028ff0028ff0028ff0028ff0028ff002"
            .. "8ff0028ff0028ff0028ff0028ff0028ff0028ff002"
            .. "8ff0028ff0028ffff0007ff0007ff0007ff0007ff0"
            .. "007ff0007ff0007ff0007ff0007ff0007ff0007ff0"
            .. "007ff0007ff0007ff0007ffff0003ff0003ff0003f"
            .. "f0003ff0003ff0003ff0003ff0003ff0003ff0003f"
            .. "f0003ff0003ff0003ff0003ff0003ffff000aff000"
            .. "aff000aff000aff000aff000aff000aff000aff000"
            .. "aff000aff000aff000aff000aff000aff000affff0"
            .. "014ff0014ff0014ff0014ff0014ff0014ff0014ff0"
            .. "014ff0014ff0014ff0014ff0014ff0014ff0014ff0"
            .. "014ffff001eff001eff001eff001eff001eff001ef"
            .. "f001eff001eff001eff001eff001eff001eff001ef"
            .. "f001eff001eff00f1028b01ffffffffff1f9602980"
            .. "29a029c029e02a002a202a402a602a802aa02ac02a"
            .. "e02b002b202b402b602b802ba02bc02be02c002c20"
            .. "2c402c602c802ca02cc02ce02d002d202d402d602d"
            .. "802da02dc02de02e002e202e402e602e802ea02ec0"
            .. "2ee02f0020028ff0028ff0028ff0028ff0028ff002"
            .. "8ff0028ff0028ff0028ff0028ff0028ff0028ff002"
            .. "8ff0028ff0028ff000007ff0007ff0007ff0007ff0"
            .. "007ff0007ff0007ff0007ff0007ff0007ff0007ff0"
            .. "007ff0007ff0007ff0007ff000003ff0003ff0003f"
            .. "f0003ff0003ff0003ff0003ff0003ff0003ff0003f"
            .. "f0003ff0003ff0003ff0003ff0003ff00000aff000"
            .. "aff000aff000aff000aff000aff000aff000aff000"
            .. "aff000aff000aff000aff000aff000aff000aff000"
            .. "014ff0014ff0014ff0014ff0014ff0014ff0014ff0"
            .. "014ff0014ff0014ff0014ff0014ff0014ff0014ff0"
            .. "014ff00001eff001eff001eff001eff001eff001ef"
            .. "f001eff001eff001eff001eff001eff001eff001ef"
            .. "f001eff001eff00",
        "all reliable 00f102b901ffffffffff1ff202f40"
            .. "2f602f802fa02fc02fe02800382038403860388038"
            .. "a038c038e03900392039403960398039a039c039e0"
            .. "3a003a203a403a603a803aa03ac03ae03b003b203b"
            .. "403b603b803ba03bc03be03c003c203c403c603c80"
            .. "3ca03cc0328ff0028ff0028ff0028ff0028ff0028f"
            .. "f0028ff0028ff0028ff0028ff0028ff0028ff0028f"
            .. "f0028ff0028ff002807ff0007ff0007ff0007ff000"
            .. "7ff0007ff0007ff0007ff0007ff0007ff0007ff000"
            .. "7ff0007ff0007ff0007ff000703ff0003ff0003ff0"
            .. "003ff0003ff0003ff0003ff0003ff0003ff0003ff0"
            .. "003ff0003ff0003ff0003ff0003ff00030aff000af"
            .. "f000aff000aff000aff000aff000aff000aff000af"
            .. "f000aff000aff000aff000aff000aff000aff000a1"
            .. "4ff0014ff0014ff0014ff0014ff0014ff0014ff001"
            .. "4ff0014ff0014ff0014ff0014ff0014ff0014ff001"
            .. "4ff00141eff001eff001eff001eff001eff001eff0"
            .. "01eff001eff001eff001eff001eff001eff001eff0"
            .. "01eff001eff001e00d101e701ffffff01ce03d003d"
            .. "203d403d603d803da03dc03de03e003e203e403e60"
            .. "3e803ea03ec03ee03f003f203f403f603f803fa03f"
            .. "c03fe038004ff0028ff0028ff0028ff0028ff0028f"
            .. "f0028ff0028ff0028ff00ff0007ff0007ff0007ff0"
            .. "007ff0007ff0007ff0007ff0007ff00ff0003ff000"
            .. "3ff0003ff0003ff0003ff0003ff0003ff0003ff00f"
            .. "f000aff000aff000aff000aff000aff000aff000af"
            .. "f000aff00ff0014ff0014ff0014ff0014ff0014ff0"
            .. "014ff0014ff0014ff00ff001eff001eff001eff001"
            .. "eff001eff001eff001eff001eff00",
    }),
    ["starve.drain"] = table.freeze ({
        "",
    }),
    ["storm.keyframe"] = table.freeze ({
        "all reliable 00f10201ffffffffff1f020406080"
            .. "a0c0e10121416181a1c1e20222426282a2c2e30323"
            .. "436383a3c3e40424446484a4c4e50525456585a5c0"
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
            .. "eff000091012fffff015e60626466686a6c6e70727"
            .. "476787a7c7e800128ff0028ff0028ff0028ff0028f"
            .. "f0028ff0007ff0007ff0007ff0007ff0007ff0007f"
            .. "f0003ff0003ff0003ff0003ff0003ff0003ff000af"
            .. "f000aff000aff000aff000aff000aff0014ff0014f"
            .. "f0014ff0014ff0014ff0014ff001eff001eff001ef"
            .. "f001eff001eff001eff00",
    }),
    ["storm.round-1"] = table.freeze ({
        "all reliable 01b0810401ffffffffffffff7f070"
            .. "707070707070707070707070707070707070707070"
            .. "707070707070707070707070707070707070707070"
            .. "70707070707070707070707070707070707070707",
    }),
    ["storm.round-2"] = table.freeze ({
        "all reliable 01b0810401ffffffffffffff7f0e0"
            .. "e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0"
            .. "e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0"
            .. "e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e",
    }),
    ["storm.round-3"] = table.freeze ({
        "all reliable 01b0810401ffffffffffffff7f151"
            .. "515151515151515151515151515151515151515151"
            .. "515151515151515151515151515151515151515151"
            .. "51515151515151515151515151515151515151515",
    }),
    ["storm.round-4"] = table.freeze ({
        "all reliable 01b0810401ffffffffffffff7f1c1"
            .. "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1"
            .. "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1"
            .. "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c",
    }),
    ["storm.round-5"] = table.freeze ({
        "all reliable 01b0810401ffffffffffffff7f232"
            .. "323232323232323232323232323232323232323232"
            .. "323232323232323232323232323232323232323232"
            .. "32323232323232323232323232323232323232323",
    }),
    ["acceptance.keyframe"] = table.freeze ({
        "a reliable 000108010200b4b4005000500050000"
            .. "00000000000000000000000000000000000b4b4000"
            .. "0000000000000000000000000000000000000006b6"
            .. "969010000000000000000000000000000000000000"
            .. "000000000000000010400000000000000000000000"
            .. "000000100000000000000000000000000006b69690"
            .. "1",
    }),
    ["acceptance.delta"] = table.freeze ({
        "a reliable 0101fbf3ffbfaeffffffff0308015ab"
            .. "410442da1b2c3f403030007555555555555d53f010"
            .. "000c03f00000000000020c0010000003f000080be0"
            .. "000c03f00000000000020c06969d10207f3026044a"
            .. "46de802046c796e63062409038130003c21065a46f"
            .. "7fe0f046c796e630c0000c03f00001040000070c00"
            .. "100f00100010802c413010000003f5a00018020000"
            .. "0003f0000803e0000403f062008bd396a69d102",
        "a unreliable 4100000108010019500a50c94f",
    }),
    ["acceptance.cleared"] = table.freeze ({
        "",
    }),
    ["acceptance.newest"] = table.freeze ({
        "a unreliable 81000001080100325000506450",
    }),
    ["acceptance.idle"] = table.freeze ({
        "",
    }),
    ["acceptance.removed"] = table.freeze ({
        "a reliable 02010801",
    }),
} :: { [string]: { string } })

return table.freeze (Golden)
