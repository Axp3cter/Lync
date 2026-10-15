--!strict
-- U9 `derive`: where an unmodified client's outcome can differ from the server's recomputation of it.
-- Part A: interpreted vs native results of the same Luau code (math.lerp, vector.lerp, a closed-form
--   projectile, transcendentals). Run both modes and compare the printed hashes.
-- Part B: f32 (`vector`, as Roblox Vector3) vs f64 (numbers) for the same projectile formula, and what that
--   does to quantized indices at t.vector3 step 1/32 under tolerance 0 and 1 step.
-- Part C: per-frame integration (as client code often does it) vs the closed form the server would run.
-- Run: luau -O2 derive_determinism.luau  and  luau -O2 --codegen derive_determinism.luau   (Luau 0.742)

local N = 200_000

-- FNV-1a over the exact f64 bits of each result
local hbuf = buffer.create(8)
local function mix(h: number, x: number): number
	buffer.writef64(hbuf, 0, x)
	for i = 0, 7 do
		h = bit32.bxor(h, buffer.readu8(hbuf, i))
		h = (h * 16777619) % 4294967296
	end
	return h
end

math.randomseed(42)
local function rnd(lo: number, hi: number): number
	return lo + (hi - lo) * math.random()
end
local A, B, T = table.create(N, 0), table.create(N, 0), table.create(N, 0)
for i = 1, N do
	A[i] = rnd(-2048, 2048)
	B[i] = rnd(-2048, 2048)
	T[i] = math.random()
end

local function hashLerp(): number
	local h = 2166136261
	for i = 1, N do
		h = mix(h, math.lerp(A[i], B[i], T[i]))
	end
	return h
end

local function hashManualLerp(): number
	local h = 2166136261
	for i = 1, N do
		local a, b, t = A[i], B[i], T[i]
		h = mix(h, a + (b - a) * t)
	end
	return h
end

local function hashVectorLerp(): number
	local h = 2166136261
	for i = 1, N, 3 do
		local a = vector.create(A[i], B[i], T[i] * 100)
		local b = vector.create(B[i], A[i], -T[i] * 100)
		local v = vector.lerp(a, b, T[i])
		h = mix(mix(mix(h, v.x), v.y), v.z)
	end
	return h
end

local G = 196.2 -- Roblox default Workspace.Gravity, studs/s^2
local function hashProjectile(): number
	local h = 2166136261
	for i = 1, N do
		local t = T[i] * 2
		local vx, vy = A[i] / 10, B[i] / 10
		local x = 0 + vx * t
		local y = 10 + vy * t - 0.5 * G * t * t
		h = mix(mix(h, x), y)
	end
	return h
end

local function hashTrig(): number
	local h = 2166136261
	for i = 1, N do
		local a = A[i] / 100
		h = mix(mix(mix(h, math.sin(a)), math.atan2(A[i], B[i])), math.exp(T[i] * 10))
	end
	return h
end

print("-- A. exact-bit hashes (compare interpreted vs native)")
print(string.format("math.lerp            %08x", hashLerp()))
print(string.format("a + (b - a) * t      %08x", hashManualLerp()))
print(string.format("vector.lerp          %08x", hashVectorLerp()))
print(string.format("projectile closed    %08x", hashProjectile()))
print(string.format("sin, atan2, exp      %08x", hashTrig()))

-- how many math.lerp results differ from the separately rounded formula in this mode
local diff, maxd = 0, 0
for i = 1, N do
	local a, b, t = A[i], B[i], T[i]
	local l = math.lerp(a, b, t)
	local m = a + (b - a) * t
	if l ~= m then
		diff += 1
		maxd = math.max(maxd, math.abs(l - m))
	end
end
print(string.format("math.lerp ~= a+(b-a)*t: %d of %d, max |diff| %.3g studs", diff, N, maxd))

-- Part B: f32 vs f64 for the same formula, quantized at step 1/32 (t.vector3(-2048, 2048, 1/32))
print("-- B. f32 (vector) vs f64 (number), projectile end point, quantized at step 1/32")
local STEP = 1 / 32
local maxErr, idxDiff0, idxDiffBeyond1 = 0, 0, 0
local M = 100_000
for i = 1, M do
	local t = T[i] * 2
	local o = vector.create(A[i] / 2, 50, B[i] / 2)
	local v = vector.create(B[i] / 20, 60 + T[i] * 40, A[i] / 20)
	-- f32: vector arithmetic (Roblox Vector3 components are f32)
	local p32 = o + v * t + vector.create(0, -0.5 * G * t * t, 0)
	-- f64: the same formula on numbers
	local ox, oy, oz = A[i] / 2, 50, B[i] / 2
	local vx, vy, vz = B[i] / 20, 60 + T[i] * 40, A[i] / 20
	local px, py, pz = ox + vx * t, oy + vy * t - 0.5 * G * t * t, oz + vz * t
	for _, pair in { { p32.x, px }, { p32.y, py }, { p32.z, pz } } do
		local e = math.abs(pair[1] - pair[2])
		maxErr = math.max(maxErr, e)
		local i32 = math.floor(pair[1] / STEP + 0.5)
		local i64 = math.floor(pair[2] / STEP + 0.5)
		local d = math.abs(i32 - i64)
		if d >= 1 then idxDiff0 += 1 end
		if d > 1 then idxDiffBeyond1 += 1 end
	end
end
print(string.format("max |f32 - f64| per component: %.3g studs", maxErr))
print(string.format("components whose index differs (fails tolerance 0): %d of %d (%.3f%%)", idxDiff0, 3 * M, 100 * idxDiff0 / (3 * M)))
print(string.format("components differing by more than 1 step (fail tolerance 1 step): %d", idxDiffBeyond1))

-- Part C: per-frame semi-implicit Euler at a client frame rate vs the closed form, after 1 s of flight
print("-- C. per-frame integration vs closed form, vertical launch 50 studs/s, after 1.0 s")
local function euler(dt: number, total: number): number
	local y, vy = 0, 50
	local t = 0
	while t < total - 1e-12 do
		vy -= G * dt
		y += vy * dt
		t += dt
	end
	return y
end
local closed = 50 * 1 - 0.5 * G * 1 * 1
for _, fps in { 30, 60, 144, 240 } do
	local y = euler(1 / fps, 1)
	print(string.format("%3d FPS: %.4f studs (closed form %.4f): off by %.3f studs = %.1f steps of 1/32", fps, y, closed, math.abs(y - closed), math.abs(y - closed) / STEP))
end
