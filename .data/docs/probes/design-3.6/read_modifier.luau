--!strict
export type A = { read x: number }
local a: A = { x = 1 }
print(a.x)
