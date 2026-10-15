--!strict
-- R5: which constructor signature keeps `from` (and `timestamped`) exact for a full option table?
export type Codec<T> = { read _value: T }
local function make(): any return {} end
local str: Codec<string> = make()
type function Show(d)
	local out = {}
	for _, k in { "from", "lane", "timestamped", "rate" } do
		local f = d:readproperty(types.singleton(k))
		if f then
			table.insert(out, `{k}={if f:is("singleton") then tostring(f:value()) else f.tag}`)
		end
	end
	return types.singleton(table.concat(out, " "))
end

-- (i) intersection with only `from`
local function i<D>(def: D & { from: "client" | "server" }): Show<D> return make() end
local a = i({ from = "client", data = str, lane = "unreliable", timestamped = true, rate = 5 })
local _ra: "REVEAL_i" = a

-- (ii) intersection with every option typed
type Options = { from: "client" | "server", lane: ("reliable" | "unreliable")?, timestamped: boolean?, rate: number? }
local function ii<D>(def: D & Options): Show<D> return make() end
local b = ii({ from = "client", data = str, rate = 5 })
local _rb: "REVEAL_ii" = b

-- (iii) overloads selected by `from`, other options untyped
type Ov = (<D>(def: D & { from: "client" }) -> ("C" & Show<D>)) & (<D>(def: D & { from: "server" }) -> ("S" & Show<D>))
local iii: Ov = make()
local c = iii({ from = "client", data = str, timestamped = true })
local _rc: "REVEAL_iii" = c

-- (iv) typo in from under (i)
local d = i({ from = "clinet", data = str })

-- (v) misspelled option names under (i): accepted silently?
local _e = i({ from = "client", data = str, timestampd = true, rtae = 5, lnae = "unreliable" })
