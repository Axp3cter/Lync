--!strict
export type Codec<T> = { read _value: T, size: number }
local function make(size: number): any
	return { size = size }
end
local M = {}
function M.enum<T>(...: T): Codec<T>
	return make(1)
end
function M.enumList<T>(list: { T }): Codec<T>
	return make(1)
end
function M.enumSet<S>(set: S): Codec<keyof<S>>
	return make(1)
end
function M.struct<S>(s: S): S -- identity, to see what a nested enum looks like inside a schema
	return s
end
return M
