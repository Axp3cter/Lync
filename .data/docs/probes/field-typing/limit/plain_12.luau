--!strict
export type H<T> = { derive: (self: H<T>, options: { fn: () -> T?, policy: "drop" | "deliver" }) -> () }
export type View = { field: ((self: View, path: "f1") -> vector) & ((self: View, path: "f2") -> string) & ((self: View, path: "f3") -> number) & ((self: View, path: "f4") -> vector) & ((self: View, path: "f5") -> string) & ((self: View, path: "f6") -> number) & ((self: View, path: "f7") -> vector) & ((self: View, path: "f8") -> string) & ((self: View, path: "f9") -> number) & ((self: View, path: "f10") -> vector) & ((self: View, path: "f11") -> string) & ((self: View, path: "f12") -> number) }
local M: View = nil :: any
return M
