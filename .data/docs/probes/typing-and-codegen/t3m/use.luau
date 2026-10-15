--!strict
local S = require("./schema")
local _r1: "R_single" = S.Single._value
local _r2: "R_variadic" = S.Variadic._value
local _r3: "R_list" = S.List._value
local _r4: "R_set" = S.Set._value
local _r5: "R_mixed" = S.Mixed._value
local _r6: "R_inline" = S.Inline.mode._value
local _r7: "R_inlinelist" = S.InlineList.mode._value
local _b1: typeof(S.Variadic._value) = "d" -- must fail
local _b2: typeof(S.List._value) = "d" -- must fail
local _b3: typeof(S.Inline.mode._value) = "d" -- must fail
return nil
