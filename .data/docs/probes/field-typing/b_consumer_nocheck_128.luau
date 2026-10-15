--!strict
-- The game's script on the runtime path, 128 paths, through b_lib's define.
local Lync = require("./b_lib_nocheck")
type Shot = { f1: vector, f2: string, f3: number, f4: vector, f5: string, f6: number, f7: vector, f8: string, f9: number, f10: vector, f11: string, f12: number, f13: vector, f14: string, f15: number, f16: vector, f17: string, f18: number, f19: vector, f20: string, f21: number, f22: vector, f23: string, f24: number, f25: vector, f26: string, f27: number, f28: vector, f29: string, f30: number, f31: vector, f32: string, f33: number, f34: vector, f35: string, f36: number, f37: vector, f38: string, f39: number, f40: vector, f41: string, f42: number, f43: vector, f44: string, f45: number, f46: vector, f47: string, f48: number, f49: vector, f50: string, f51: number, f52: vector, f53: string, f54: number, f55: vector, f56: string, f57: number, f58: vector, f59: string, f60: number, f61: vector, f62: string, f63: number, f64: vector, f65: string, f66: number, f67: vector, f68: string, f69: number, f70: vector, f71: string, f72: number, f73: vector, f74: string, f75: number, f76: vector, f77: string, f78: number, f79: vector, f80: string, f81: number, f82: vector, f83: string, f84: number, f85: vector, f86: string, f87: number, f88: vector, f89: string, f90: number, f91: vector, f92: string, f93: number, f94: vector, f95: string, f96: number, f97: vector, f98: string, f99: number, f100: vector, f101: string, f102: number, f103: vector, f104: string, f105: number, f106: vector, f107: string, f108: number, f109: vector, f110: string, f111: number, f112: vector, f113: string, f114: number, f115: vector, f116: string, f117: number, f118: vector, f119: string, f120: number, f121: vector, f122: string, f123: number, f124: vector, f125: string, hit: { part: number, at: vector }? }
local v = Lync.define((nil :: any) :: Shot)
local h2 = v.fields.f2 -- inferred type: see run.out (--annotate)
v.fields.f3:derive({ fn = function() return 1 end, policy = "drop" })
v.fields["hit.at"]:derive({ fn = function() return vector.create(1, 2, 3) end, policy = "deliver" })
v.fields.f125:derive({ fn = function() return nil end, policy = "drop" })
local _exact: { derive: (any, { fn: () -> string?, policy: "drop" | "deliver" }) -> () } = v.fields.f2
-- EXPECT an error on each line below
local _wrongType: { derive: (any, { fn: () -> number?, policy: "drop" | "deliver" }) -> () } = v.fields.f2 -- f2 is a string handle
v.fields["hit.part"]:derive({ fn = function() return vector.create(1, 2, 3) end, policy = "drop" }) -- wrong return
local _wrongPath = v.fields.nope -- unknown path
v.fields.f3:derive({ fn = function() return 1 end, policy = "dorp" }) -- wrong option
return h2
