--!strict
-- Does an option typed as a union of path literals check correct and wrong literals,
-- on the generated path (a concrete union) and the runtime path (a type function over the schema)?

-- Generated path: the shard emits the union.
type FightersPositionPath = "position" | "spawn.at"
type GenOptions = { position: FightersPositionPath, radius: number }
local function interestGen(options: GenOptions) end
interestGen({ position = "position", radius = 64 }) -- expect clean
interestGen({ position = "positon", radius = 64 }) -- expect error (misspelled)
interestGen({ position = "health", radius = 64 }) -- expect error (another codec)

-- Runtime path: a type function picks the top-level fields whose codec kind is a position kind.
type Codec<T, K> = { _value: T, _kind: K }
type Schema = {
	position: Codec<Vector3, "vector3">,
	facing: Codec<CFrame, "cframe">,
	health: Codec<number, "int">,
}
type function PositionPaths(schema)
	local members = {}
	for key, prop in schema:properties() do
		local codec = prop.read
		local kind: type? = if codec then codec:readproperty(types.singleton("_kind")) else nil
		if kind and kind:is("singleton") then
			local v = kind:value()
			if v == "vector3" or v == "vector3f32" or v == "cframe" then
				table.insert(members, key)
			end
		end
	end
	if #members == 0 then
		return types.never
	elseif #members == 1 then
		return members[1]
	end
	return types.unionof(table.unpack(members))
end
type RunOptions<S> = { position: PositionPaths<S>, radius: number }
local function interestRun(options: RunOptions<Schema>) end
interestRun({ position = "position", radius = 64 }) -- expect clean
interestRun({ position = "facing", radius = 64 }) -- expect clean
interestRun({ position = "health", radius = 64 }) -- expect error
interestRun({ position = "positon", radius = 64 }) -- expect error
