--!strict
-- R6: isolate the spurious error on `Lync.request({ ..., timeout = 10 })` seen in pipe/schema.luau:19
export type Codec<T> = { read _value: T }
local function make(): any return {} end
local int: Codec<number> = make()
local function request<D>(def: D & { from: "client" | "server" }): D return make() end
local _a = request({ from = "client", data = int, reply = int }) -- no timeout
local _b = request({ from = "client", data = int, reply = int, timeout = 10 }) -- timeout = number literal
local _c = request({ from = "client", data = { item = int }, reply = int })
local function enum<T>(names: { T }): Codec<T> return make() end
local _d = request({ from = "client", data = { item = enum({ "sword", "shield" }) }, reply = int })
local _e = request({ from = "client", data = { item = enum({ "sword", "shield" }) }, reply = int, timeout = 10 })
local _f = request({ from = "client", data = { item = int }, reply = int, timeout = 10 })
