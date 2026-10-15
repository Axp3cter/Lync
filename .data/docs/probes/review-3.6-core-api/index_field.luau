--!strict
-- Rejected alternative for the runtime path: one generic field method over a table of handles via index<>.
-- Result: the literal widens to string at the generic, so every call fails (correct ones too).
type H<T> = { derive: (self: H<T>, options: { fn: () -> T?, policy: "drop" | "deliver" }) -> () }
type Fields = { ["f1.x"]: H<vector>, ["f2.x"]: H<string>, ["f3.x"]: H<number>, ["f4.x"]: H<vector>, ["f5.x"]: H<string>, ["f6.x"]: H<number>, ["f7.x"]: H<vector>, ["f8.x"]: H<string>, ["f9.x"]: H<number>, ["f10.x"]: H<vector>, ["f11.x"]: H<string>, ["f12.x"]: H<number>, ["f13.x"]: H<vector>, ["f14.x"]: H<string>, ["f15.x"]: H<number>, ["f16.x"]: H<vector>, ["f17.x"]: H<string>, ["f18.x"]: H<number>, ["f19.x"]: H<vector>, ["f20.x"]: H<string>, ["f21.x"]: H<number>, ["f22.x"]: H<vector>, ["f23.x"]: H<string>, ["f24.x"]: H<number>, ["f25.x"]: H<vector>, ["f26.x"]: H<string>, ["f27.x"]: H<number>, ["f28.x"]: H<vector>, ["f29.x"]: H<string>, ["f30.x"]: H<number>, ["f31.x"]: H<vector>, ["f32.x"]: H<string>, }
type View = { field: <P>(self: View, path: P) -> index<Fields, P> }
local v: View = nil :: any
v:field("f3.x"):derive({ fn = function() return 1 end, policy = "drop" })
v:field("f1.x"):derive({ fn = function() return 1 end, policy = "drop" }) -- EXPECT error: vector
v:field("nope") -- EXPECT error
v:field("f3.x"):derive({ fn = function() return 1 end, policy = "dorp" }) -- EXPECT error
