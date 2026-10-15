-- drives the fixture Weapon script's functions with sampled values and prints the bytes the runtime holds
local out = {}
local modes = { "x", "y", "z" }
for i = 1, 200 do
	RT.reset()
	W.onHit(i * 7919 % 1099511627776 + 1, vector.normalize(vector.create(math.sin(i), math.cos(i * 3), math.sin(i * 0.7) - 0.5)))
	W.onMove({ a = i % 1001, b = (i * 13) % 1001, crouch = i % 2 == 0, speed = (i % 97) / 97, mode = modes[i % 3 + 1], frame = i % 256 })
	W.shop()
	table.insert(out, RT.snapshot())
end
-- refusals: a value out of range must raise the same message from both forms
local ok, err = pcall(W.onMove, { a = 1001, b = 0, crouch = false, speed = 0, mode = "x", frame = 0 })
table.insert(out, tostring(ok) .. " " .. tostring(err))
print(#table.concat(out, "\n"), string.format("%08x", (function(s) local h = 2166136261 for k = 1, #s do h = bit32.bxor(h, string.byte(s, k)) h = (h * 16777619) % 4294967296 end return h end)(table.concat(out, "\n"))))
print(out[#out])
return nil
