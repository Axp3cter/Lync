--!strict
-- The throwaway consumer project the roblox-ts compiler is pointed at: a scoped package under
-- the build directory that installs Lync's declaration the way a game would and compiles the
-- surface test against it. Nothing here is checked in, and every run lays it down again.

local fs = require("@lune/fs")
local process = require("@lune/process")

local Repo = require("./Repo")
local Tools = require("./Tools")

local Gate = {}

-- Constants -----------------------------------------------------------

-- A scoped name makes the compiler treat the project as a package, which needs no Rojo project
-- and reaches every scoped dependency through its own type roots.
local MANIFEST = '{ "name": "@gate/surface", "private": true }\n'

-- Every option the compiler enforces, the two type roots it reads, and the one file it compiles.
local CONFIG = table.concat({
    "{",
    '    "compilerOptions": {',
    '        "target": "ESNext",',
    '        "module": "CommonJS",',
    '        "moduleDetection": "force",',
    '        "moduleResolution": "Node10",',
    '        "noLib": true,',
    '        "strict": true,',
    '        "allowSyntheticDefaultImports": true,',
    '        "typeRoots": ["node_modules/@rbxts", "node_modules/@axpecter"],',
    '        "types": ["compiler-types", "types"],',
    '        "skipLibCheck": true,',
    '        "rootDir": "src",',
    '        "outDir": "out"',
    "    },",
    '    "files": ["src/Declaration.ts"]',
    "}",
    "",
}, "\n")

-- Private -------------------------------------------------------------

local function within(path: string): string
    return `{Repo.GATE}/{path}`
end

-- A directory junction, which needs no privilege on Windows and is a plain symlink elsewhere.
local function linked(link: string, target: string): Tools.Ruling
    if Repo.exists(link) then return { ok = true } end
    local script = "require('fs').symlinkSync(process.argv[1], process.argv[2], 'junction')"
    return Tools.run("node", { "-e", script, target, link })
end

-- Public --------------------------------------------------------------

-- Lays the project down: the manifest, the config, the surface test as its one source, the
-- library's declaration and manifest as an installed scoped package, and the roblox types.
function Gate.stage(): Tools.Ruling
    local package = within("node_modules/@axpecter/lync")
    fs.writeDir(within("src"))
    fs.writeDir(package)
    fs.writeFile(within("package.json"), MANIFEST)
    fs.writeFile(within("tsconfig.json"), CONFIG)
    fs.copy(Repo.SURFACE, within("src/Declaration.ts"), true)
    fs.copy(Repo.DECLARATION, `{package}/index.d.ts`, true)
    fs.copy(Repo.MANIFEST, `{package}/package.json`, true)
    return linked(within("node_modules/@rbxts"), `{process.cwd}/node_modules/@rbxts`)
end

return table.freeze(Gate)
