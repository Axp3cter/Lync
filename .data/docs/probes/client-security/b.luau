local function f(b)
  return math.floor(buffer.readu8(b, 0) / 2)
end
local _ = getfenv
return f
