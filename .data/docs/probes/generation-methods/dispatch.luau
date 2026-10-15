--!strict
--!optimize 2
-- M6 dispatch cost: how a view reaches a per-session variant's encoder. The encoder is one writebits so the
-- difference is the dispatch. (1) upvalue fixed at build (one variant), (2) a field of the view set once per
-- session at WELCOME, (3) a per-call index into the pool by the session's index.
-- Run: luau -O2 dispatch.luau   and   luau -O2 --codegen dispatch.luau
local wb = buffer.writebits
local function e1(b: buffer, bit: number, v: number): number wb(b, bit, 8, v); return bit + 8 end
local function e2(b: buffer, bit: number, v: number): number wb(b, bit, 8, bit32.bxor(v, 0x5a)); return bit + 8 end
local function e3(b: buffer, bit: number, v: number): number wb(b, bit, 8, bit32.band(v + 77, 255)); return bit + 8 end
local function e4(b: buffer, bit: number, v: number): number wb(b, bit, 8, 255 - v); return bit + 8 end
local POOL = { e1, e2, e3, e4 }
local session = { index = 3 }

local buf = buffer.create(8)
local fixed = e3
local ViewA = {}
function ViewA.fire(self: any, v: number) return fixed(buf, 0, v) end
local ViewB = { enc = POOL[session.index] }
function ViewB.fire(self: any, v: number) return self.enc(buf, 0, v) end
local ViewC = {}
function ViewC.fire(self: any, v: number) return POOL[session.index](buf, 0, v) end

local N = 5_000_000
local best = { math.huge, math.huge, math.huge }
local views = { ViewA, ViewB, ViewC }
for _ = 1, 9 do
	for i, view in views do
		local t0 = os.clock()
		for k = 1, N do view:fire(k % 256) end
		best[i] = math.min(best[i], os.clock() - t0)
	end
end
local names = { "(1) build-fixed upvalue", "(2) view field set at WELCOME", "(3) per-call pool index" }
for i = 1, 3 do print(string.format("%-32s %6.1f ns per fire", names[i], best[i] / N * 1e9)) end
