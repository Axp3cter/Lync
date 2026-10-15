-- Fail derives Lync's source prefix with "^(.-)%.?diag[%./\\]fail$", which drops the separator, so sibling
-- modules whose names start with the package name count as Lync. Run: luau p14_lync_prefix.luau (or lune run)
local own = "ReplicatedStorage.Packages.Lync.diag.fail"
local prefix = string.match(own, "^(.-)%.?diag[%./\\]fail$")
print(prefix)
for _, source in { "ReplicatedStorage.Packages.Lync.codec.rows", "ReplicatedStorage.Packages.LyncNet.client", "ReplicatedStorage.Packages.Lync2.schema" } do
	print(source, string.sub(source, 1, #prefix) == prefix)
end
