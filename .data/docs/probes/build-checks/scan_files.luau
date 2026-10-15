--!nocheck
-- Runs the creation-site half of scan.luau over loose files (Lune 0.11.0): lune run scan_files.luau FILE...
local fs = require("@lune/fs")
local process = require("@lune/process")
local scan = require("./scan")
local scripts = {}
for _, p in process.args do
	table.insert(scripts, { path = string.match(p, "[^/]+$"), name = p, source = fs.readFile(p), client = false, lync = false })
end
for _, f in scan(scripts, {}) do
	print(string.format("%s kind=%d %s:%d:%d %s", f.check, f.kind, f.path, f.line, f.col, f.detail))
end
