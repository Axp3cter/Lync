--!strict
-- (f) No type function, 10 paths: the handle is the codec value's own type, fields is the schema table (generic S).
type Handle<T> = { derive: (self: Handle<T>, options: { fn: () -> T?, policy: "drop" | "deliver" }) -> () }
local t = {}
function t.leaf<T>(): Handle<T> return nil :: any end
function t.optional<C>(c: C): C return c end -- an optional record keeps its children's handles
local function define<S>(fields: S): { fields: S } return { fields = fields } end
local v = define({ f1 = t.leaf() :: Handle<vector>, f2 = t.leaf() :: Handle<string>, f3 = t.leaf() :: Handle<number>, f4 = t.leaf() :: Handle<vector>, f5 = t.leaf() :: Handle<string>, f6 = t.leaf() :: Handle<number>, f7 = t.leaf() :: Handle<vector>, hit = t.optional({ part = t.leaf() :: Handle<number>, at = t.leaf() :: Handle<vector> }) })
local h2 = v.fields.f2 -- inferred type: see run.out (--annotate)
v.fields.f3:derive({ fn = function() return 1 end, policy = "drop" })
v.fields.hit.at:derive({ fn = function() return vector.create(1, 2, 3) end, policy = "deliver" })
v.fields.f7:derive({ fn = function() return nil end, policy = "drop" })
local _exact: Handle<string> = v.fields.f2
-- EXPECT an error on each line below
local _wrongType: Handle<number> = v.fields.f2 -- f2 is a string handle
v.fields.hit.part:derive({ fn = function() return vector.create(1, 2, 3) end, policy = "drop" }) -- wrong return
local _wrongPath = v.fields.nope -- unknown path
v.fields.f3:derive({ fn = function() return 1 end, policy = "dorp" }) -- wrong option
return h2
