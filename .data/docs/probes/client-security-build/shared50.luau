local function enc(b,o,id,x,y,z,flags,name)
buffer.writeu16(b, o, id)
buffer.writef32(b, o + 2, x); buffer.writef32(b, o + 6, y); buffer.writef32(b, o + 10, z)
buffer.writeu8(b, o + 14, flags)
local n = #name
buffer.writeu8(b, o + 15, n)
buffer.writestring(b, o + 16, name)
o = o + 16 + n
return o end
local function site0(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site1(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site2(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site3(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site4(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site5(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site6(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site7(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site8(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site9(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site10(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site11(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site12(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site13(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site14(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site15(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site16(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site17(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site18(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site19(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site20(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site21(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site22(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site23(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site24(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site25(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site26(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site27(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site28(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site29(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site30(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site31(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site32(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site33(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site34(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site35(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site36(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site37(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site38(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site39(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site40(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site41(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site42(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site43(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site44(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site45(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site46(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site47(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site48(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
local function site49(b,o,id,x,y,z,flags,name) return enc(b,o,id,x,y,z,flags,name) end
return 1
