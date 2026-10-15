#!/usr/bin/env python3
"""Generates the field-typing probes into this directory. Usage: python3 -I gen.py

Schema at N paths: leaves f1..f(N-3) (types cycle vector, string, number by i % 3 = 1, 2, 0) plus
hit: { part: number, at: vector }? (paths hit, hit.part, hit.at), so N field paths in all, as nested_typefn
counts them (records and leaves reachable through records and optionals).
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SIZES = (10, 32, 128)
LT = {0: "number", 1: "vector", 2: "string"}
TS = {0: "number", 1: "Vector3", 2: "string"}


def write(name, text):
    with open(os.path.join(HERE, name), "w") as f:
        f.write(text)


def schema(n):
    leaves = ", ".join(f"f{i}: {LT[i % 3]}" for i in range(1, n - 2))
    return f"type Shot = {{ {leaves}, hit: {{ part: number, at: vector }}? }}"


# Shared type-function helpers (Lync's runtime path would hold these in its own module).
HELPERS = r'''local function handleOf(t)
		return types.newtable({ [types.singleton("derive")] = types.newfunction(
			{ head = { types.any, types.newtable({
				[types.singleton("fn")] = types.newfunction({}, { head = { types.optional(t) } }),
				[types.singleton("policy")] = types.unionof(types.singleton("drop"), types.singleton("deliver")),
			}) } }, {}) })
	end
	local function stripNil(t: any): any
		if t:is("union") then
			local rest = {}
			local hadNil = false
			for _, c in t:components() do
				if c:is("nil") then hadNil = true else table.insert(rest, c) end
			end
			if hadNil and #rest == 1 then return rest[1] end
		end
		return t
	end
	-- calls each(path, inner) for every path through records and optionals
	local function walk(t: any, prefix: string, each)
		for key, prop in t:properties() do
			local name = tostring(key:value())
			local path = if prefix == "" then name else prefix .. "." .. name
			local inner = stripNil(prop.read)
			each(path, inner)
			if inner:is("table") and inner:indexer() == nil then walk(inner, path, each) end
		end
	end'''

H_STR = '{ derive: (any, { fn: () -> string?, policy: "drop" | "deliver" }) -> () }'
H_NUM = '{ derive: (any, { fn: () -> number?, policy: "drop" | "deliver" }) -> () }'


def calls(n, acc, hs=H_STR, hn=H_NUM):
    """Consumer lines; acc(path) is the expression for the handle of path. Returns text (EXPECT marks)."""
    last = n - 3
    return f'''local h2 = {acc("f2")} -- inferred type: see run.out (--annotate)
{acc("f3")}:derive({{ fn = function() return 1 end, policy = "drop" }})
{acc("hit.at")}:derive({{ fn = function() return vector.create(1, 2, 3) end, policy = "deliver" }})
{acc(f"f{last}")}:derive({{ fn = function() return nil end, policy = "drop" }})
local _exact: {hs} = {acc("f2")}
-- EXPECT an error on each line below
local _wrongType: {hn} = {acc("f2")} -- f2 is a string handle
{acc("hit.part")}:derive({{ fn = function() return vector.create(1, 2, 3) end, policy = "drop" }}) -- wrong return
local _wrongPath = {acc("nope")} -- unknown path
{acc("f3")}:derive({{ fn = function() return 1 end, policy = "dorp" }}) -- wrong option
return h2
'''


def method(p):
    return f'v:field("{p}")'


def dot(p):
    return f"v.fields.{p}" if "." not in p else f'v.fields["{p}"]'


for n in SIZES:
    # (0) the review's form: a type function returning an intersection of overloads (nested_typefn)
    write(f"base_overloads_{n}.luau", f'''--!strict
-- Baseline: the review's runtime-path form, {n} paths: a type function returns an intersection of field(path) overloads.
type function FieldOf(rec)
	{HELPERS}
	local parts = {{}}
	walk(rec, "", function(path, inner)
		table.insert(parts, types.newfunction({{ head = {{ types.any, types.singleton(path) }} }}, {{ head = {{ handleOf(inner) }} }}))
	end)
	return types.intersectionof(table.unpack(parts))
end
{schema(n)}
type View = {{ field: FieldOf<Shot> }}
local v: View = nil :: any
{calls(n, method)}''')

    # (a) one generic function; a type function looks the path up from the inferred P
    write(f"a_generic_{n}.luau", f'''--!strict
-- (a) One function type, no overloads: field: <P>(self, path: P) -> FieldAt<Shot, P>, {n} paths.
type function FieldAt(rec, p)
	{HELPERS}
	if not p:is("singleton") then error("field: the path must be a string literal, got a non-singleton") end
	local want = p:value()
	local found = nil
	walk(rec, "", function(path, inner) if path == want then found = handleOf(inner) end end)
	if found == nil then error("field: no path " .. tostring(want)) end
	return found
end
{schema(n)}
type View = {{ field: <P>(self: View, path: P) -> FieldAt<Shot, P> }}
local v: View = nil :: any
{calls(n, method)}''')

    # (a') the same through index<> on a table of handles (index_field's form, on this schema)
    write(f"a_index_{n}.luau", f'''--!strict
-- (a') One generic function over index<>: field: <P>(self, path: P) -> index<FieldsOf<Shot>, P>, {n} paths.
type function FieldsOf(rec)
	{HELPERS}
	local props = {{}}
	walk(rec, "", function(path, inner) props[types.singleton(path)] = handleOf(inner) end)
	return types.newtable(props)
end
{schema(n)}
type View = {{ field: <P>(self: View, path: P) -> index<FieldsOf<Shot>, P> }}
local v: View = nil :: any
{calls(n, method)}''')

    # (b) a table of handles keyed by path: Net.<def>.fields.<name> / .fields["a.b"]
    write(f"b_table_{n}.luau", f'''--!strict
-- (b) A table type of handles keyed by path, read as v.fields.f3 and v.fields["hit.at"], {n} paths.
type function FieldsOf(rec)
	{HELPERS}
	local props = {{}}
	walk(rec, "", function(path, inner) props[types.singleton(path)] = handleOf(inner) end)
	return types.newtable(props)
end
{schema(n)}
type View = {{ fields: FieldsOf<Shot> }}
local v: View = nil :: any
{calls(n, dot)}''')

    # (c) split by nesting level: each record's handle has its own field() over its direct children
    write(f"c_nested_{n}.luau", f'''--!strict
-- (c) Split by nesting level: field(name) overloads per record over its direct children only;
-- v:field("hit"):field("at") for a nested path. Top level here has {n - 2} keys, {n} paths in all.
type function NodeOf(rec)
	{HELPERS}
	local function node(t: any): any
		local parts = {{}}
		for key, prop in t:properties() do
			local inner = stripNil(prop.read)
			local h = handleOf(inner)
			if inner:is("table") and inner:indexer() == nil then
				h:setproperty(types.singleton("field"), node(inner))
			end
			table.insert(parts, types.newfunction({{ head = {{ types.any, types.singleton(tostring(key:value())) }} }}, {{ head = {{ h }} }}))
		end
		return types.intersectionof(table.unpack(parts))
	end
	return node(rec)
end
{schema(n)}
type View = {{ field: NodeOf<Shot> }}
local v: View = nil :: any
{calls(n, lambda p: method(p) if "." not in p else 'v:field("hit"):field("' + p.split(".")[1] + '")')}''')

    # (d) one non-generic function over the union of path singletons, result index<> of that union
    write(f"d_union_{n}.luau", f'''--!strict
-- (d) field: (self, path: Paths) -> index<FieldsOf<Shot>, Paths>, Paths the union of path singletons, {n} paths.
type function FieldsOf(rec)
	{HELPERS}
	local props = {{}}
	walk(rec, "", function(path, inner) props[types.singleton(path)] = handleOf(inner) end)
	return types.newtable(props)
end
{schema(n)}
type Paths = keyof<FieldsOf<Shot>>
type View = {{ field: (self: View, path: Paths) -> index<FieldsOf<Shot>, Paths> }}
local v: View = nil :: any
{calls(n, method)}''')

    # (e) the overloads, each with its own unused generic: the normalizer neither merges nor union-saturates them
    write(f"e_phantom_{n}.luau", f'''--!strict
-- (e) The overloads of the baseline, each with a distinct unused generic G<i>, {n} paths. Normalize.cpp
-- unionSaturatedFunctions and intersectionOfFunctions return nullopt when two overloads' generics differ.
type function FieldOf(rec)
	{HELPERS}
	local parts = {{}}
	walk(rec, "", function(path, inner)
		table.insert(parts, types.newfunction({{ head = {{ types.any, types.singleton(path) }} }}, {{ head = {{ handleOf(inner) }} }},
			{{ types.generic("G" .. tostring(#parts + 1)) }}))
	end)
	return types.intersectionof(table.unpack(parts))
end
{schema(n)}
type View = {{ field: FieldOf<Shot> }}
local v: View = nil :: any
{calls(n, method)}''')

# (e) as a library: the type function in Lync's module, the game's script calls define(schema) and never names it
write("e_lib.luau", f'''--!strict
-- (e) in Lync's own module: the runtime path's define returns View<S>; the game's script never writes the type function.
type function FieldOf(rec)
	{HELPERS}
	local parts = {{}}
	walk(rec, "", function(path, inner)
		table.insert(parts, types.newfunction({{ head = {{ types.any, types.singleton(path) }} }}, {{ head = {{ handleOf(inner) }} }},
			{{ types.generic("G" .. tostring(#parts + 1)) }}))
	end)
	return types.intersectionof(table.unpack(parts))
end
export type View<S> = {{ field: FieldOf<S> }}
local Lync = {{}}
function Lync.define<S>(schema: S): View<S>
	return nil :: any
end
return Lync
''')
write("e_consumer_128.luau", f'''--!strict
-- The game's script on the runtime path, 128 paths, through e_lib's define.
local Lync = require("./e_lib")
{schema(128)}
local v = Lync.define((nil :: any) :: Shot)
{calls(128, method)}''')

# Claim 1: plain overloads (the review's generated-path shape) at 6..16, two handle shapes
for n in range(6, 17):
    for shape, ret in (("H", lambda i: f"H<{LT[i % 3]}>"), ("plain", lambda i: LT[i % 3])):
        parts = " & ".join(f'((self: View, path: "f{i}") -> {ret(i)})' for i in range(1, n + 1))
        write(f"limit/{shape}_{n}.luau", f'''--!strict
export type H<T> = {{ derive: (self: H<T>, options: {{ fn: () -> T?, policy: "drop" | "deliver" }}) -> () }}
export type View = {{ field: {parts} }}
local M: View = nil :: any
return M
''')

# roblox-ts: the .d.ts of the chosen form: one overload per path on an interface (method overloads)
for n in SIZES:
    last = n - 3
    sigs = "\n".join(f'\tfield(path: "f{i}"): Handle<{TS[i % 3]}>;' for i in range(1, n - 2))
    write(f"ts/view_{n}.d.ts", f'''// .d.ts of the chosen form, {n} paths: one field(path) overload per path.
declare interface Vector3 {{ readonly X: number; readonly Y: number; readonly Z: number }}
export interface Handle<T> {{ derive(options: {{ fn: () => T | undefined; policy: "drop" | "deliver" }}): void }}
export interface View {{
{sigs}
\tfield(path: "hit"): Handle<{{ part: number; at: Vector3 }}>;
\tfield(path: "hit.part"): Handle<number>;
\tfield(path: "hit.at"): Handle<Vector3>;
}}
''')
    write(f"ts/use_{n}.ts", f'''import type {{ View, Handle }} from "./view_{n}";
declare const v: View;
declare const p: Vector3;
const h2 = v.field("f2"); // Handle<string>
v.field("f3").derive({{ fn: () => 1, policy: "drop" }});
v.field("hit.at").derive({{ fn: () => p, policy: "deliver" }});
v.field("f{last}").derive({{ fn: () => undefined, policy: "drop" }});
const exact: Handle<string> = v.field("f2");
// EXPECT an error on each line below
const wrongType: Handle<number> = v.field("f2");
v.field("hit.part").derive({{ fn: () => p, policy: "drop" }});
const wrongPath = v.field("nope");
v.field("f3").derive({{ fn: () => 1, policy: "dorp" }});
export {{ h2, exact, wrongType, wrongPath }};
''')

# roblox-ts runtime path: the handle type derived from the schema type S (no generation step)
TS_LIB = '''declare interface Vector3 { readonly X: number; readonly Y: number; readonly Z: number }
export interface Handle<T> { derive(options: { fn: () => T | undefined; policy: "drop" | "deliver" }): void }
type Leaf = Vector3 | number | string | boolean;
// every path through records and optionals, dotted
export type Paths<S, Pre extends string = ""> = {
	[K in keyof S & string]-?: `${Pre}${K}` | (NonNullable<S[K]> extends Leaf ? never : Paths<NonNullable<S[K]>, `${Pre}${K}.`>);
}[keyof S & string];
export type At<S, P extends string> = P extends `${infer H}.${infer R}`
	? H extends keyof S ? At<NonNullable<S[H]>, R> : never
	: P extends keyof S ? NonNullable<S[P]> : never;
export interface View<S> { field<P extends Paths<S>>(path: P): Handle<At<S, P>> }
'''
for n in SIZES:
    last = n - 3
    leaves = "; ".join(f"f{i}: {TS[i % 3]}" for i in range(1, n - 2))
    write(f"ts/generic_{n}.ts", f'''// roblox-ts runtime path, {n} paths: View<S> derives field(path) from the schema type S.
{TS_LIB}
type Shot = {{ {leaves}; hit?: {{ part: number; at: Vector3 }} }};
declare const v: View<Shot>;
declare const p: Vector3;
const h2 = v.field("f2"); // Handle<string>
v.field("f3").derive({{ fn: () => 1, policy: "drop" }});
v.field("hit.at").derive({{ fn: () => p, policy: "deliver" }});
v.field("f{last}").derive({{ fn: () => undefined, policy: "drop" }});
const exact: Handle<string> = v.field("f2");
// EXPECT an error on each line below
const wrongType: Handle<number> = v.field("f2");
v.field("hit.part").derive({{ fn: () => p, policy: "drop" }});
const wrongPath = v.field("nope");
v.field("f3").derive({{ fn: () => 1, policy: "dorp" }});
export {{ h2, exact, wrongType, wrongPath }};
''')

# (a2) form (a) with explicit type instantiation, which keeps the literal: v:field<<"f3">>("f3")
for n in SIZES:
    src = open(os.path.join(HERE, f"a_generic_{n}.luau")).read()
    head, _, _ = src.partition("local h2")
    head = head.replace("-- (a) One function type", "-- (a2) (a) called with explicit instantiation v:field<<\"p\">>(\"p\"); one function type")
    write(f"a_explicit_{n}.luau", head + calls(n, lambda p: f'v:field<<"{p}">>("{p}")'))

# (b) as a library: FieldsOf in Lync's module, the game's script reads Net.<def>.fields
B_FIELDS = f'''type function FieldsOf(rec)
	{HELPERS}
	local props = {{}}
	walk(rec, "", function(path, inner) props[types.singleton(path)] = handleOf(inner) end)
	return types.newtable(props)
end'''
write("b_lib.luau", f'''--!strict
-- (b) in Lync's own module: define returns View<S> with fields: FieldsOf<S>.
{B_FIELDS}
export type View<S> = {{ fields: FieldsOf<S> }}
local Lync = {{}}
function Lync.define<S>(schema: S): View<S>
	return nil :: any
end
return Lync
''')
write("b_consumer_128.luau", f'''--!strict
-- The game's script on the runtime path, 128 paths, through b_lib's define.
local Lync = require("./b_lib")
{schema(128)}
local v = Lync.define((nil :: any) :: Shot)
{calls(128, dot)}''')

# (f) no type function: the schema's codec values carry the handle type; fields is the schema table itself.
# Records nest as fields (v.fields.hit.at); a record's own handle is not derivable without a type function.
F_LIB = '''type Handle<T> = { derive: (self: Handle<T>, options: { fn: () -> T?, policy: "drop" | "deliver" }) -> () }
local t = {}
function t.leaf<T>(): Handle<T> return nil :: any end
function t.optional<C>(c: C): C return c end -- an optional record keeps its children's handles
local function define<S>(fields: S): { fields: S } return { fields = fields } end'''
for n in SIZES:
    leaves = ", ".join(f"f{i} = t.leaf() :: Handle<{LT[i % 3]}>" for i in range(1, n - 2))
    write(f"f_codec_{n}.luau", f'''--!strict
-- (f) No type function, {n} paths: the handle is the codec value's own type, fields is the schema table (generic S).
{F_LIB}
local v = define({{ {leaves}, hit = t.optional({{ part = t.leaf() :: Handle<number>, at = t.leaf() :: Handle<vector> }}) }})
{calls(n, lambda p: "v.fields." + p, "Handle<string>", "Handle<number>")}''')

# (b) library with --!nocheck: does the old solver still report, and what does the consumer get?
write("b_lib_nocheck.luau", open(os.path.join(HERE, "b_lib.luau")).read().replace("--!strict", "--!nocheck", 1))
write("b_consumer_nocheck_128.luau", open(os.path.join(HERE, "b_consumer_128.luau")).read().replace('"./b_lib"', '"./b_lib_nocheck"'))
