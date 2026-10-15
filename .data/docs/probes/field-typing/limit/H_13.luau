--!strict
export type H<T> = { derive: (self: H<T>, options: { fn: () -> T?, policy: "drop" | "deliver" }) -> () }
export type View = { field: ((self: View, path: "f1") -> H<vector>) & ((self: View, path: "f2") -> H<string>) & ((self: View, path: "f3") -> H<number>) & ((self: View, path: "f4") -> H<vector>) & ((self: View, path: "f5") -> H<string>) & ((self: View, path: "f6") -> H<number>) & ((self: View, path: "f7") -> H<vector>) & ((self: View, path: "f8") -> H<string>) & ((self: View, path: "f9") -> H<number>) & ((self: View, path: "f10") -> H<vector>) & ((self: View, path: "f11") -> H<string>) & ((self: View, path: "f12") -> H<number>) & ((self: View, path: "f13") -> H<vector>) }
local M: View = nil :: any
return M
