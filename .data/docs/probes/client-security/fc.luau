local function f(b: buffer)
  local t = os.clock()
  local u = buffer.readu32(b, 0)
  local v = bit32.bxor(u, 5)
  local s = string.byte("a")
  local n = typeof(b)
  return t, v, s, n
end
return f
