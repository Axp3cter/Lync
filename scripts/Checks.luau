--!strict
-- The repository held to its own rules: one function per check, each judging files it reads.

local fs = require ("@lune/fs")

local Reading = require ("./Reading")
local Repo = require ("./Repo")
local Ruling = require ("./Ruling")
local Tools = require ("./Tools")

local Checks = {}

-- Constants -----------------------------------------------------------

--[[
    The layer stack, as the set each layer may reach. It is not the reading order: codec may reach
    kernel but never wire, and channel may reach wire but never codec, so an index comparison would
    pass edges the table forbids. A require inside one layer is always legal.
]]
local PERMITTED: { [string]: { [string]: boolean } } = {
    kernel = {},
    wire = { kernel = true },
    codec = { kernel = true },
    shape = { codec = true, wire = true, kernel = true },
    channel = { wire = true, kernel = true },
    state = { shape = true, channel = true, wire = true, kernel = true },
    runtime = { state = true, channel = true, shape = true, wire = true, kernel = true },
    api = {
        runtime = true,
        state = true,
        channel = true,
        shape = true,
        codec = true,
        wire = true,
        kernel = true,
    },
}

--[[
    Every module that is the one home of a number. The format keeps its own and the vocabulary
    keeps a turn, which cannot join them because the two sit beside each other rather than stacked.
]]
local DECLARING_NUMBERS = table.freeze ({
    table.freeze ({ path = `{Repo.SRC}/wire/Protocol.luau`, name = "Protocol" }),
    table.freeze ({ path = `{Repo.SRC}/codec/Scalars.luau`, name = "Scalars" }),
})

--[[
    Values a wire constant may share with ordinary code: none, and the powers of two up to a byte.

    A rule rather than a list, since byte arithmetic produces these and nothing else. It costs
    `VARINT_GROUPS` and `NEWEST_GENS`, which are counted in exactly these numbers anyway.
]]
local COINCIDENTAL: { [string]: boolean } =
    { ["0"] = true, ["1"] = true, ["2"] = true, ["4"] = true, ["8"] = true }

--[[
    Below this a wire constant is also a number a person chooses: a schema bound, a budget, a depth,
    a count. Inside src choosing one is still a second home, because src has no business picking a
    bound at all. Outside it the collisions are constant, so the other trees are held to the values
    nobody types by accident.
]]
local ORDINARY = 10000

--[[
    The numbers under that bound a tree still may not choose, because each is a word rather than a
    magnitude. A turn is three hundred and sixty whatever anybody wants, so a suite spelling it is a
    suite that goes on saying a turn is that after the vocabulary has stopped. Three units and a
    generator spelled it before this held them.
]]
local VOCABULARY: { [string]: boolean } = { ["360"] = true }

--[[
    Values past that bound a person still chooses, held inside `src` alone.

    A round power of ten falsifies the bound: `MAX_FIRE` is a million and so is a bench batch.
    Raising it instead would carry `32768` out, which nobody arrives at twice by chance.
]]
local CHOSEN: { [string]: boolean } = { ["1000000"] = true }

--[[
    Every alias the two .luaurc files declare, spelled from this module's paths. Luau follows a
    value only when it opens ./ or ../, and darklua leaves an alias it cannot resolve as a literal
    string require and still exits zero, so an alias left behind by a rename ships a broken package
    rather than failing.
]]
local ALIASED: { [string]: { [string]: string } } = {
    [Repo.LUAURC] = {
        [Repo.BENCH] = `./{Repo.BENCH}`,
        [Repo.FIXTURES] = `./{Repo.FIXTURES}`,
        [Repo.SRC] = `./{Repo.SRC}`,
        [Repo.TEST] = `./{Repo.TEST}`,
    },
    [Repo.SCRIPTS_LUAURC] = { lune = `../{Repo.LUNE_TYPES}` },
}

-- What each walk is looking for.
local LUAU = "%.luau$"
local MARKDOWN = "%.md$"

--[[
    The marks banned from prose, spelled by escape so no file has to carry the one it forbids.

    A semicolon and either dash are prose anywhere. An asterisk is hunted in sentences alone, since
    in a Luau pattern it is an operator, and both readers drop what sits in backticks first.
]]
local BANNED = table.freeze ({
    table.freeze ({ mark = ";", name = "a semicolon", anywhere = true }),
    table.freeze ({ mark = "\u{2014}", name = "an em dash", anywhere = true }),
    table.freeze ({ mark = "\u{2013}", name = "an en dash", anywhere = true }),
    table.freeze ({ mark = "*", name = "an asterisk", anywhere = false }),
})

--[[
    A design document named in a line, which is what a comment may not do.

    Numbered and lower case, so the pattern is the numbering and a run of letters rather than five
    names to keep in step. Hexadecimal is lower case too, so a name needs a letter it has not.
]]
local REGISTER = "(0[1-5]%l%l%l%l%l+)"
local SPELLED = "[g-z]"

-- The one line allowed to name one, which is a unit's coverage claim rather than a reference.
local BANNER = "^%s*Owned by 0[1-5]%l+, "

--[[
    What a diagnostic looks like when it is not going through the door. Matched where it is
    called, so `Log.error` is the door and a bare `error` is somebody walking past it, and the
    guard in front keeps a method of that name from reading as one.
]]
local DIAGNOSTICS = table.freeze ({
    "[^%w_.:]print%s*%(",
    "[^%w_.:]warn%s*%(",
    "[^%w_.:]error%s*%(",
    "[^%w_.:]assert%s*%(",
})

--[[
    The module the door is, whose own raises are the door raising rather than a site avoiding it.

    Held by path rather than by name, since a suite or a script may reasonably be called the same
    thing and this gate reads `src` alone.
]]
local DOOR = "src/kernel/Log.luau"

-- Where the diagnoses are declared and named, and the union that says which strings they are.
local CATALOG = "src/kernel/Catalog.luau"
local CODES = "Code"

--[[
    How many raises may still stand outside it: two, each saying why at its site.

    One answers three numbers and cannot return a refusal, since nothing is not three of them. The
    other passes along a rejection built below, which is propagation. It falls and never rises.
]]
local ASIDE = 2

--[[
    A vocabulary declared as a union of string literals, and a constant carrying a member of one.

    Two patterns for the union, since a short one is whole on the line that opens it and a long
    one runs on below, and a third for the constant. The long ones are the ones worth holding.
]]
local DECLARES = "^export type (%w+) ="
local CARRIED = '^%s*|?%s*"'
local CARRIES = '^const [A-Z][A-Z0-9_]* = ("[^"]+")$'

--[[
    How many constants outside `src` may carry a member of one without naming the type that owns
    it. None may inside it, where the vocabularies are declared. Outside, a word is a word: a
    namespace named `apart`, a suite's own label. Annotating those would say something untrue.
]]
local UNOWNED = 5

--[[
    A value a caller reaches into with a colon. Two spellings, both refused outside a double: a
    field declared as taking `self`, and a type built out of `setmetatable`.
]]
local METHODS = table.freeze ({ "read %w+: %(self:", "typeof%(setmetatable" })

--[[
    The one module that may wear the shape of what it stands in for, and the one that may carry a
    metatable to be known by. A double goes where the engine's object goes, so a wire has methods
    because a `RemoteEvent` does. A marker is never called through: it tells one raise from
    another.
]]
local WEARS = table.freeze ({ Repo.DOUBLES, Repo.EXPECT })

--[[
    A place inside a document, which is the same refusal reached the other way: a comment naming
    no register can still send a reader into one by number. `section` alone stays free, since it
    is this protocol's own word for part of a frame. What is refused is the word and a number.
]]
local PLACES = table.freeze ({
    "([sS]ection %d[%d%.]*)",
    "([cC]hapter %d[%d%.]*)",
    "([pP]age %d[%d%.]*)",
    "([aA]ppendix %a)",
    "(\u{00A7})",
})

--[[
    The door a debug record leaves by, and where a release build closes it.

    `Log.debug` is the one producer, and the gate above it is a global darklua folds to a literal.
    Folded, an unconditional return opens the body, so what is under it is bytes nothing reaches.
]]
local DEBUGGING = "function Log.debug"
local SHUT = "do return end"
local COMPOSES = "said ("

--[[
    How long a block may run, and how many longer ones still stand. Six counts the brackets, so
    four lines: one thought about the line below. Twelve bought a hundred and thirty one blocks
    written to exactly twelve. The count came down to nothing, so one long block is a red run.
]]
local SAYING = 6
local SAID = 0

-- Private -------------------------------------------------------------

-- Every file with a suffix under a directory, depth first.
local function walk (dir: string, suffix: string): { string }
    local found = {}
    if not Repo.exists (dir) then return found end

    for _, entry in fs.readDir (dir) do
        local path = `{dir}/{entry}`
        if fs.isDir (path) then
            local nested = walk (path, suffix)
            table.move (nested, 1, #nested, #found + 1, found)
        elseif string.match (entry, suffix) ~= nil then
            table.insert (found, path)
        end
    end
    return found
end

--[[
    Every document the prose rules bind: the README, and whatever markdown the authored trees
    carry. The design register is not a tree, so no exception has to be written for it.
]]
local function documents (): { string }
    local found = {}
    if Repo.exists (Repo.README) then table.insert (found, Repo.README) end

    for _, dir in Repo.formatted () do
        local nested = walk (dir, MARKDOWN)
        table.move (nested, 1, #nested, #found + 1, found)
    end
    return found
end

-- The layer a source path belongs to, or nil for the entry module itself.
local function layerOf (path: string): string?
    local layer = string.match (path, `^{Repo.SRC}/([^/]+)/`)
    return layer
end

--[[
    Whether a value is one a tree outside src may have chosen for itself rather than copied. Inside
    src nothing is: src has no business picking a bound.
]]
local function ordinary (value: string): boolean
    if VOCABULARY[value] then return false end
    return CHOSEN[value] or (tonumber (value) :: number) < ORDINARY
end

local function failure (faults: { string }): Ruling.Ruling
    if #faults == 0 then return { ok = true } end
    return { ok = false, note = table.concat (faults, ", ") }
end

-- Every way a .luaurc's aliases disagree with ALIASED, in both directions.
local function aliasFaults (path: string): { string }
    local config = Repo.decode ("json", path)
    local declared = if config ~= nil then config.aliases else nil
    if typeof (declared) ~= "table" then return { `{path} declares no aliases` } end

    local expected = ALIASED[path]
    local faults = {}
    for name, value in expected do
        if declared[name] ~= value then
            table.insert (faults, `{path} does not alias {name} to {value}`)
        end
    end
    for name in declared do
        if expected[name] == nil then table.insert (faults, `{path} aliases stray {name}`) end
    end
    return faults
end

-- The whole convert_require rule a darklua config declares, or nil when absent.
local function convertRule (path: string): { [string]: any }?
    local config = Repo.decode ("json", path)
    local rules = if config ~= nil then config.rules else nil
    if typeof (rules) ~= "table" then return nil end

    for _, rule in rules :: { any } do
        if typeof (rule) == "table" and rule.rule == "convert_require" then return rule end
    end
    return nil
end

-- Public --------------------------------------------------------------

--[[
    wally.toml is the one home of the release version. package.json and the README install line are
    copies, and this is what keeps them honest.
]]
function Checks.versions (): Ruling.Ruling
    local wally = Repo.decode ("toml", Repo.WALLY)
    local package = if wally ~= nil then wally.package else nil
    if typeof (package) ~= "table" then
        return { ok = false, note = `{Repo.WALLY} has no package` }
    end

    local declared = (package :: { [string]: any }).version
    local name = (package :: { [string]: any }).name
    if typeof (declared) ~= "string" then
        return { ok = false, note = `{Repo.WALLY} has no version` }
    end

    local wrong = {}

    local npm = Repo.decode ("json", Repo.NPM)
    if npm == nil or npm.version ~= declared then
        local found = if npm ~= nil then tostring (npm.version) else "unreadable"
        table.insert (wrong, `{Repo.NPM} is {found}`)
    end

    local readme = Repo.read (Repo.README)
    if readme == nil or string.find (readme, `{name}@{declared}`, 1, true) == nil then
        table.insert (wrong, `{Repo.README} does not name {name}@{declared}`)
    end

    return failure (wrong)
end

--[[
    The facts more than one file states: the require conversion both darklua configs perform, what
    both .luaurc files declare, and every path the darklua and editor JSON restate from here. The
    conversion is pinned to Luau's own resolution, since darklua's path mode misreads a relative
    require inside a folder module, does not know @self, and exits zero regardless.
]]
function Checks.configs (): Ruling.Ruling
    local wrong = {}

    local dev = convertRule (Repo.DARKLUA)
    local release = convertRule (Repo.DARKLUA_RELEASE)
    if dev == nil or release == nil then
        table.insert (wrong, "a darklua config declares no convert_require")
    elseif not Reading.same (dev, release) then
        table.insert (wrong, "the darklua configs convert requires differently")
    elseif dev.current.name ~= "luau" then
        table.insert (wrong, `darklua reads requires as {dev.current.name}`)
    elseif dev.target.rojo_sourcemap ~= Repo.SOURCEMAP then
        table.insert (wrong, `darklua names sourcemap {dev.target.rojo_sourcemap}`)
    end

    local root = Repo.decode ("json", Repo.LUAURC)
    local tooling = Repo.decode ("json", Repo.SCRIPTS_LUAURC)
    if root == nil or tooling == nil then
        table.insert (wrong, "a .luaurc is unreadable")
    else
        for key, value in root do
            if key ~= "aliases" and not Reading.same (value, tooling[key]) then
                table.insert (wrong, `.luaurc files disagree on {key}`)
            end
        end
        for key in tooling do
            if key ~= "aliases" and root[key] == nil then
                table.insert (wrong, `.luaurc files disagree on {key}`)
            end
        end
    end

    for _, path in { Repo.LUAURC, Repo.SCRIPTS_LUAURC } do
        local faults = aliasFaults (path)
        table.move (faults, 1, #faults, #wrong + 1, wrong)
    end

    local settings = Repo.decode ("json", Repo.SETTINGS)
    if settings == nil then
        table.insert (wrong, `{Repo.SETTINGS} is unreadable`)
    else
        local files = settings["luau-lsp.types.definitionFiles"]
        local roblox = if typeof (files) == "table"
            then (files :: { [string]: any }).roblox
            else nil
        if roblox ~= `./{Repo.DEFINITIONS}` then
            table.insert (wrong, `{Repo.SETTINGS} does not name ./{Repo.DEFINITIONS}`)
        end

        local project = settings["luau-lsp.sourcemap.rojoProjectFile"]
        if project ~= Repo.project (Repo.TEST) then
            table.insert (wrong, `{Repo.SETTINGS} maps against {tostring (project)}`)
        end
    end

    local tasks = Repo.decode ("json", Repo.TASKS)
    local declared = if tasks ~= nil then tasks.tasks else nil
    if typeof (declared) ~= "table" then
        table.insert (wrong, `{Repo.TASKS} declares no tasks`)
    else
        for _, task in declared :: { { [string]: any } } do
            local args = task.args
            local entry = if typeof (args) == "table" then (args :: { string })[2] else nil
            if entry ~= Repo.RUN then
                table.insert (
                    wrong,
                    `{Repo.TASKS} task {tostring (task.label)} runs {tostring (entry)}`
                )
            end
        end
    end

    return failure (wrong)
end

--[[
    Every require in src resolved to its layer and held to the permitted set. An edge that climbs or
    crosses names both ends, so the fix is unambiguous.
]]
function Checks.edges (): Ruling.Ruling
    local wrong = {}

    for _, path in walk (Repo.SRC, LUAU) do
        local from = layerOf (path)
        local source = Repo.read (path)
        if from == nil or source == nil then continue end

        for required in string.gmatch (source, `require%s*%("@{Repo.SRC}/([^"]+)"%)`) do
            local to = string.match (required, "^([^/]+)/")
            if to ~= nil and to ~= from and PERMITTED[from][to] == nil then
                table.insert (wrong, `{path} reaches {to}`)
            end
        end
    end

    return failure (wrong)
end

--[[
    Wire constants have one home in code, so every number `Protocol` declares is hunted across
    every other module of every tree, suites included. Only the numeric declarations: a derived
    value states its derivation, and a table is not a number a file repeats by accident.
]]
function Checks.constants (): Ruling.Ruling
    local values = {}
    local homes: { [string]: boolean } = {}

    for _, home in DECLARING_NUMBERS do
        local source = Repo.read (home.path)
        if source == nil then continue end

        homes[home.path] = true
        for name, value in string.gmatch (source, `{home.name}%.([%u_]+)%s*=%s*([^\n]+)`) do
            --[[
                The version is left out. Its value says which grammar is spoken and nothing
                about how a byte is laid out, so no other file can restate it, and
                holding every digit it lands on would break this the first time it is small.
            ]]
            if name == "VERSION" then continue end

            local trimmed = string.match (value, "^%s*(.-)%s*$") :: string
            if tonumber (trimmed) ~= nil and COINCIDENTAL[trimmed] == nil then
                values[trimmed] = true
            end
        end
    end
    if next (values) == nil then
        return { ok = false, note = `{Repo.PROTOCOL} declares no numbers to hold` }
    end

    local wrong = {}
    for _, dir in Repo.trees () do
        local strict = dir == Repo.SRC
        for _, path in walk (dir, LUAU) do
            if homes[path] then continue end
            local source = Repo.read (path)
            if source == nil then continue end

            --[[
                An exponent collapsed into what it multiplies, because a number written in
                scientific notation is one number and the digits after its `e` are not a second use
                of that value. Without this a tolerance of `1e-9` reads as a repeat of nine.
            ]]
            source = string.gsub (Reading.stripped (source), "(%d)[eE][-+]?%d+", "%1")
            for value in values do
                if not strict and ordinary (value) then continue end
                local pattern = `%f[%w]{string.gsub (value, "%p", "%%%0")}%f[%W]`
                if string.find (source, pattern) ~= nil then
                    table.insert (wrong, `{path} repeats {value}`)
                end
            end
        end
    end

    return failure (wrong)
end

--[[
    The punctuation discipline, over every line of prose the project ships: a comment, a composed
    message and a document, but not code. The one rule the formatter cannot hold, since StyLua
    reads a comment as opaque text and a document not at all.
]]
function Checks.prose (): Ruling.Ruling
    local wrong = {}

    local function hunt (path: string, spoken: { string }, sentence: boolean)
        for number, line in spoken do
            for _, banned in BANNED do
                if not sentence and not banned.anywhere then continue end
                if string.find (line, banned.mark, 1, true) == nil then continue end
                table.insert (wrong, `{path}:{number} carries {banned.name}`)
            end
        end
    end

    for _, dir in Repo.formatted () do
        for _, path in walk (dir, LUAU) do
            local source = Repo.read (path)
            if source == nil then continue end

            local sentences, messages = Reading.prosed (source)
            hunt (path, sentences, true)
            hunt (path, messages, false)
        end
    end

    for _, path in documents () do
        local text = Repo.read (path)
        if text ~= nil then hunt (path, Reading.written (text), true) end
    end

    local declared = Repo.read (Repo.DTS)
    if declared ~= nil then hunt (Repo.DTS, Reading.declared (declared), true) end

    return failure (wrong)
end

--[[
    How much of a comment may already be in the names beside it before it is a restatement.

    What is asked is whether the sentence carries a word no name could hold. Three quarters rather
    than all, since a label over a call is allowed to be the call's own words.
]]
local ECHOED = 0.75

--[[
    A comment about the code's own shape: one naming the place its line was put, and one naming the
    spelling it was given. Both leave the reason as an afterthought where it is the whole of what a
    comment is for. Spelled by parts so this file does not carry what it forbids.
]]
local NARRATES =
    table.freeze ({ "%f[%w][Hh]ere rat" .. "her than", "[Ww]ritten as .- rat" .. "her than" })

-- How many code lines under a comment count as the line it is about.
local BESIDE = 3

-- Whether the line under this one is anything a comment could be about.
local function loose (lines: { string }, at: number): boolean
    local after = lines[at + 1]
    return after == nil or after == "" or string.match (after, "^%s*%-%-") ~= nil
end

--[[
    Comment blocks held to what they run to and what they stand over. A rationale is a why and a
    contract is what a public function costs, and neither is an essay. Length is counted rather
    than refused, since a hard limit would cut what is worth saying. Standing over nothing is
    absolute, since a block over nothing is one whose line moved out from under it.
]]
function Checks.saying (): Ruling.Ruling
    local over = {}

    for _, dir in Repo.formatted () do
        for _, path in walk (dir, LUAU) do
            local source = Repo.read (path)
            if source == nil then continue end

            --[[
                Where the banner ends, which is the one block that answers to the file rather than
                to a line. Nothing but the pragmas stands above it, so the first line that is
                neither is where every other block has something under it to be about.
            ]]
            local lines = Reading.lines (source)
            local banner = 0
            for number, line in lines do
                if line ~= "" and string.match (line, "^%-%-!") == nil then
                    banner = number
                    break
                end
            end

            local opens, run = 0, 0
            for number, line in lines do
                if opens == 0 then
                    if string.match (line, "^%s*%-%-%[%[") == nil then continue end

                    opens, run = number, 1
                    continue
                end

                run += 1
                if string.match (line, "^%s*%]%]") == nil then continue end

                if run > SAYING then table.insert (over, `{path}:{opens} says {run} lines`) end

                if loose (lines, number) and opens ~= banner then
                    table.insert (over, `{path}:{opens} says it to nothing`)
                end

                opens = 0
            end

            --[[
                The same of a line comment, which stands over one line and has to have one. A
                divider is a shape rather than a saying and stands over whatever follows it.
            ]]
            for number, line in lines do
                if string.match (line, "^%s*%-%- ") == nil then continue end
                if Reading.dashed (line) ~= nil or not loose (lines, number) then continue end
                if number == banner then continue end

                table.insert (over, `{path}:{number} says it to nothing`)
            end
        end
    end

    if #over <= SAID then
        if #over == SAID then return { ok = true } end
        return { ok = false, note = `{#over} blocks run long, so the ceiling is stale at {SAID}` }
    end
    return failure (over)
end

--[[
    Whether a module a comment names is one the repository has. Tried under each tree as well as
    bare, since a comment names one the way a reader says it and a tree is what they leave off.
]]
local function reaches (held: string): boolean
    if Repo.exists (held) then return true end

    for _, dir in { "" } do
        if Repo.exists (`{dir}{held}.luau`) or Repo.exists (`{dir}{held}/init.luau`) then
            return true
        end
    end

    for _, dir in Repo.formatted () do
        if Repo.exists (`{dir}/{held}.luau`) or Repo.exists (`{dir}/{held}/init.luau`) then
            return true
        end
    end
    return false
end

--[[
    Every comment standing on its own, naming a module or a constant and never a document, a
    section or a page. A module it names has to be one the repository has, since a reference a tool
    can follow is only one where following it arrives. A unit's banner is the one exception, since
    it is the coverage gate's claim rather than a reader sent anywhere.
]]
function Checks.citing (): Ruling.Ruling
    local wrong = {}

    for _, dir in Repo.formatted () do
        for _, path in walk (dir, LUAU) do
            local source = Repo.read (path)
            if source == nil then continue end

            for number, line in Reading.lines (source) do
                if string.match (line, BANNER) ~= nil then continue end

                for _, place in PLACES do
                    local at = string.match (line, place)
                    if at == nil then continue end

                    table.insert (wrong, `{path}:{number} sends a reader to {at}`)
                end

                for held in string.gmatch (line, "`([%w%.]+/[%w%./]+)`") do
                    if not reaches (held) then
                        table.insert (wrong, `{path}:{number} names {held}, which is nothing`)
                    end
                end

                local named = string.match (line, REGISTER)
                if named == nil then continue end
                if string.match (named, SPELLED) == nil then continue end

                table.insert (wrong, `{path}:{number} sends a reader to {named}`)
            end
        end
    end

    return failure (wrong)
end

--[[
    Every authored line inside the formatter's column, read from the formatter's own configuration
    so the number keeps one home. StyLua wraps code to it and leaves comments alone, so a comment is
    the one line in a Luau file that can outgrow the width with the formatter reporting nothing.
    Documents wrap to the same column, except a table row, which has no break that reads well.
]]
function Checks.width (): Ruling.Ruling
    local config = Repo.decode ("toml", Repo.STYLUA)
    local column = if config ~= nil then config.column_width else nil
    if typeof (column) ~= "number" then
        return { ok = false, note = `{Repo.STYLUA} declares no column width` }
    end

    local wrong = {}
    local function measure (path: string, text: string, skipTables: boolean)
        for number, line in Reading.lines (text) do
            if #line <= column then continue end
            if skipTables and Reading.tabular (line) then continue end
            table.insert (wrong, `{path}:{number} runs to {#line}`)
        end
    end

    for _, dir in Repo.formatted () do
        for _, path in walk (dir, LUAU) do
            local source = Repo.read (path)
            if source ~= nil then measure (path, source, false) end
        end
    end

    for _, path in documents () do
        local text = Repo.read (path)
        if text ~= nil then measure (path, text, true) end
    end

    return failure (wrong)
end

-- Every member of the diagnosis vocabulary, read off the union that declares it.
local function diagnoses (): { [string]: boolean }
    local source = Repo.read (CATALOG)
    if source == nil then return {} end

    local held: { [string]: boolean } = {}
    local inside = false

    for _, line in Reading.lines (source) do
        local opens = string.match (line, DECLARES)
        if opens ~= nil then inside = opens == CODES end
        if not inside then continue end

        if opens == nil and string.find (line, CARRIED) == nil then
            inside = false
            continue
        end
        for one in string.gmatch (line, '"([^"]+)"') do
            held[one] = true
        end
    end
    return held
end

-- How much of a function has to be its own before two of it are one fact.
local WORKING = 30

-- One function's body, with its own name and its whitespace taken off.
local function bodied (lines: { string }, at: number): (string?, number)
    local opens = string.match (lines[at], "^l?o?c?a?l? ?function [%w.:]+ ?%((.*)$")
    if opens == nil then return nil, at end

    if string.sub (opens, -4) == " end" then return string.sub (opens, 1, -5), at end

    local held = { opens }
    local seek = at + 1
    while seek <= #lines and lines[seek] ~= "end" do
        table.insert (held, lines[seek])
        seek += 1
    end

    return table.concat (held, " "), seek
end

--[[
    The same working written in more than one place, which is a derivation with two homes. Numbers,
    vocabularies and prose each have a gate. This is the fourth kind of fact: two modules working
    one answer out of one input agree until either is edited.
]]
function Checks.derived (): Ruling.Ruling
    local held: { [string]: { string } } = {}

    for _, dir in Repo.trees () do
        for _, path in walk (dir, LUAU) do
            local source = Repo.read (path)
            if source == nil then continue end

            local lines = Reading.lines (source)
            local at = 1
            while at <= #lines do
                local body, ends = bodied (lines, at)
                if body == nil then
                    at += 1
                    continue
                end

                local text = string.gsub (string.gsub (body, "%s+", " "), "^ *(.-) *$", "%1")
                if #text >= WORKING then
                    local where = held[text] or {}
                    table.insert (where, `{path}:{at}`)
                    held[text] = where
                end
                at = ends + 1
            end
        end
    end

    local twice = {}
    for _, where in held do
        if #where < 2 then continue end
        table.insert (twice, `one working stands at {table.concat (where, " and ")}`)
    end

    table.sort (twice)
    return failure (twice)
end

--[[
    A constant that spells a number, and whether anything above it says which kind it is. Nothing
    about the digits tells a wire number from a module's own, so the one that stays has to say so.
    A constant bound from another module's name is exempt, the binding having said it already.
]]
function Checks.stated (): Ruling.Ruling
    local bare = {}

    for _, path in walk (Repo.SRC, LUAU) do
        if path == Repo.PROTOCOL then continue end

        local source = Repo.read (path)
        if source == nil then continue end

        local lines = Reading.lines (source)
        for number, line in lines do
            local name, value = string.match (line, "^const ([A-Z][A-Z0-9_]*) = (.+)$")
            if name == nil then continue end
            if string.match (value :: string, '^["`{]') ~= nil then continue end
            if string.match (value :: string, "%u%w*%.%u") ~= nil then continue end

            local above = number - 1
            while above >= 1 and string.match (lines[above], "^const ") ~= nil do
                above -= 1
            end
            while above >= 1 and string.match (lines[above], "^local ") ~= nil do
                above -= 1
            end
            if above >= 1 and string.match (lines[above], "^%s*%-%-") ~= nil then continue end
            if above >= 1 and string.match (lines[above], "^%s*%]%]") ~= nil then continue end

            table.insert (bare, `{path}:{number} states {name} and says nothing about it`)
        end
    end

    return failure (bare)
end

--[[
    A diagnosis spelled rather than named, which is a code with a second home. One union declares
    every member, so a site writing the string out is one a rename leaves compiling and a caller's
    branch quietly missing. Only the code half of a line is read.
]]
function Checks.catalogued (): Ruling.Ruling
    local codes = diagnoses ()
    local spelled = {}

    for _, dir in Repo.trees () do
        for _, path in walk (dir, LUAU) do
            if path == CATALOG then continue end

            local source = Repo.read (path)
            if source == nil then continue end

            for number, line in Reading.lines (source) do
                local code = string.match (line, "^(.-)%-%-") or line
                for one in string.gmatch (code, '"([^"]+)"') do
                    if codes[one] then table.insert (spelled, `{path}:{number} says {one}`) end
                end
            end
        end
    end

    if #spelled == 0 then return { ok = true } end
    return {
        ok = false,
        note = `{#spelled} diagnoses are spelled rather than named: `
            .. table.concat (spelled, ", "),
    }
end

--[[
    Every diagnostic in `src` through the one door. Every site takes a rung of one ladder, so what
    this refuses is the shape taking none, which is a bare call to the engine. A comment naming one
    is prose about it, so a line is read up to where its comment opens.
]]
function Checks.doors (): Ruling.Ruling
    local outside = {}

    for _, path in walk (Repo.SRC, LUAU) do
        if path == DOOR then continue end

        local source = Repo.read (path)
        if source == nil then continue end

        for number, line in Reading.lines (source) do
            local code = string.match (line, "^(.-)%-%-") or line
            for _, one in DIAGNOSTICS do
                if string.find (` {code}`, one) == nil then continue end

                table.insert (outside, `{path}:{number}`)
            end
        end
    end

    if #outside <= ASIDE then return { ok = true } end
    return {
        ok = false,
        note = `{#outside} raises stand outside the door, which allows {ASIDE}: `
            .. table.concat (outside, ", "),
    }
end

--[[
    Every spelling of a declared vocabulary held to the type that owns it. A constant carrying a
    member either names the type, and a checker catches a typo where it is written, or it does not,
    and a typo is a value nothing answers to and nothing says so. The owning module is skipped.
]]
function Checks.spelling (): Ruling.Ruling
    local owners: { [string]: string } = {}
    local held: { { path: string, name: string, value: string } } = {}

    for _, dir in Repo.formatted () do
        for _, path in walk (dir, LUAU) do
            local source = Repo.read (path)
            if source == nil then continue end

            local kind = nil
            for number, line in Reading.lines (source) do
                local opens = string.match (line, DECLARES)
                if opens ~= nil then kind = opens end

                if kind ~= nil and (opens ~= nil or string.find (line, CARRIED) ~= nil) then
                    for one in string.gmatch (line, '"([^"]+)"') do
                        if owners[one] == nil then owners[one] = `{path} as {kind}` end
                    end
                    if opens == nil or string.find (line, '"') ~= nil then continue end
                end
                if opens == nil then kind = nil end

                local value = string.match (line, CARRIES)
                if value == nil then continue end

                table.insert (held, { path = path, name = `{path}:{number}`, value = value })
            end
        end
    end

    local inside, outside = {}, {}
    for _, one in held do
        local owner = owners[string.sub (one.value, 2, -2)]
        if owner == nil or string.find (owner, one.path, 1, true) == 1 then continue end

        local where = if string.find (one.path, Repo.SRC, 1, true) == 1 then inside else outside
        table.insert (where, one.name)
    end

    if #inside > 0 then
        return {
            ok = false,
            note = `{#inside} in {Repo.SRC} spell a vocabulary without naming it: `
                .. table.concat (inside, ", "),
        }
    end

    if #outside <= UNOWNED then return { ok = true } end
    return {
        ok = false,
        note = `{#outside} constants spell a vocabulary without naming it, which allows {UNOWNED}: `
            .. table.concat (outside, ", "),
    }
end

--[[
    One shape for what the verification trees build: a module of functions over a record it hands
    back. A value with methods is what an engine object looks like, and two places earn that.
    Everywhere else it is a second way of writing one thing.
]]
function Checks.doubles (): Ruling.Ruling
    local wrong = {}
    local held: { [string]: string } = {}
    local read: { [string]: string } = {}

    for _, dir in { Repo.TEST, Repo.FIXTURES, Repo.BENCH } do
        for _, path in walk (dir, LUAU) do
            local source = Repo.read (path)
            if source == nil then continue end

            for name in string.gmatch (source, "%f[%w_](_%l[%w]*):") do
                held[name] = path
            end

            for number, line in Reading.lines (source) do
                if table.find (WEARS, path) == nil then
                    for _, one in METHODS do
                        if string.find (line, one) == nil then continue end

                        table.insert (wrong, `{path}:{number}`)
                    end
                end

                for name in string.gmatch (line, "%.(_%l[%w]*)") do
                    if read[name] == nil then read[name] = `{path}:{number}` end
                end
            end
        end
    end

    -- A field one of the trees marks as its own, reached for somewhere other than where it lives.
    for name, where in read do
        local owner = held[name]
        if owner == nil or string.find (where, owner, 1, true) == 1 then continue end

        table.insert (wrong, `{where} reads {name}, which is {owner}'s own`)
    end

    return failure (wrong)
end

--[[
    A check whose answer nothing reads, which is a line that cannot fail. There are two kinds: one
    raises where the claim is wrong, and one answers so a caller can decide. Written as a statement
    they read alike, and the answering kind asserts nothing. Which is which is read out of
    the module rather than listed here, a check being the kind that can reach `raise`.
]]
function Checks.answered (): Ruling.Ruling
    local source = Repo.read (Repo.EXPECT)
    if source == nil then return { ok = false, note = `{Repo.EXPECT} is missing` } end

    -- Every declaration in the surface, each holding what its body reaches until the next begins.
    local answers: { [string]: boolean } = {}
    local naming: string? = nil
    for _, line in Reading.lines (source) do
        local name = string.match (line, "^function Expect%.(%a+) ")
        if name ~= nil then
            naming = name
            answers[name] = true
            continue
        end
        if naming ~= nil and string.find (line, "raise (", 1, true) ~= nil then
            answers[naming] = false
        end
    end

    local wrong = {}
    for _, dir in Repo.trees () do
        for _, path in walk (dir, LUAU) do
            if path == Repo.EXPECT then continue end

            local text = Repo.read (path)
            if text == nil then continue end

            for number, line in Reading.lines (text) do
                local name = string.match (line, "^%s*Expect%.(%a+) %(")
                if name == nil or not answers[name] then continue end

                local why = `{path}:{number} asks {name}, which answers rather than raises`
                table.insert (wrong, why)
            end
        end
    end

    return failure (wrong)
end

--[[
    The debug door, held shut in the build that ships. Measured by making one rather than read off
    the configuration: the module is converted through the release config and the door is read out
    of what came back, a body opening with an unconditional return composing nothing.
]]
function Checks.folded (): Ruling.Ruling
    local into = `{Repo.BUILD}/folded`
    if Repo.exists (into) then fs.removeDir (into) end
    fs.writeDir (into)

    local out = `{into}/Log.luau`
    local ran = Tools.run ("darklua", { "process", DOOR, out, "-c", Repo.DARKLUA_RELEASE })
    if not ran.ok then return ran end

    local text = Repo.read (out)
    if text == nil then return { ok = false, note = `the release build wrote no {out}` } end

    local at = string.find (text, DEBUGGING, 1, true)
    if at == nil then return { ok = false, note = `{DOOR} declares no {DEBUGGING}` } end

    local body = string.sub (text, at + #DEBUGGING)
    local shut = string.find (body, SHUT, 1, true)
    local composes = string.find (body, COMPOSES, 1, true)

    if shut == nil or (composes ~= nil and composes < shut) then
        return { ok = false, note = `{DEBUGGING} composes a record in a release build` }
    end
    return { ok = true }
end

-- How many sentences the trees may say in two places.
local SAID_TWICE = 0

--[[
    How much of one sentence has to be another before the two are one reason in two homes. Two
    thirds and a little: under every pair a reading found, and above the band a unit sits in by
    naming its own subject. Under eight significant words a match is chance.
]]
local ALIKE = 0.68
local ALIKE_ENOUGH = 8

-- Where a file's opening block ends, which is the one place a suite and its module agree by design.
local BANNER_ENDS = 8

--[[
    The trees a suite may reach under and the alias each is reached by. `src` is not the only thing
    below a suite: a pair of machines builds its definitions once a side, and five suites re-derived
    that before this read them.
]]
local ALIASES: { [string]: string } = { src = Repo.SRC, fixtures = Repo.FIXTURES, test = Repo.TEST }

--[[
    The two comments the standard bans: the one that says only what its line says, and the one that
    says where its line was put rather than why.
]]
function Checks.restating (): Ruling.Ruling
    local wrong = {}

    for _, dir in Repo.formatted () do
        for _, path in walk (dir, LUAU) do
            local source = Repo.read (path)
            if source == nil then continue end

            local sentences = Reading.prosed (source)
            local code = Reading.lines (Reading.stripped (source))

            --[[
                A comment describing where its own line was put, which is a thing the code shows. A
                reason for a placement is worth saying and the placement is not, so what is refused
                is the phrasing that leads with it.
            ]]
            local inside = false
            for number, line in Reading.lines (source) do
                local opens = string.match (line, "^%s*%-%-%[%[") ~= nil
                if opens then inside = true end

                local said = inside or string.match (line, "^%s*%-%-") ~= nil
                if string.match (line, "^%s*%]%]") ~= nil then inside = false end
                if not said then continue end

                for _, one in NARRATES do
                    if string.find (line, one) == nil then continue end

                    table.insert (wrong, `{path}:{number} says where its line is, not why`)
                end
            end

            local at = 1
            while at <= #sentences do
                if sentences[at] == "" or Reading.divides (sentences[at]) then
                    at += 1
                    continue
                end

                local opens = at
                local said = {}
                while at <= #sentences and sentences[at] ~= "" do
                    table.insert (said, sentences[at])
                    at += 1
                end

                local beside = {}
                local under = at
                while under <= #code and #beside < BESIDE do
                    if string.match (code[under], "^%s*$") ~= nil then
                        if #beside > 0 then break end
                    else
                        table.insert (beside, code[under])
                    end
                    under += 1
                end

                if #beside == 0 then continue end

                local held = Reading.echoed (table.concat (said, " "), table.concat (beside, " "))
                if held < ECHOED then continue end

                local much = string.format ("%.2f", held)
                table.insert (wrong, `{path}:{opens} says {much} of what the line below it says`)
            end
        end
    end

    return failure (wrong)
end

--[[
    The shape half of the comment standard: one divider column, no two comment lines stacked, and
    no word broken across a line.
]]
function Checks.shaped (): Ruling.Ruling
    local wrong = {}

    for _, dir in Repo.formatted () do
        for _, path in walk (dir, LUAU) do
            local source = Repo.read (path)
            if source == nil then continue end

            local lines = Reading.lines (source)
            local inside = false
            local was = false
            for number, line in lines do
                local want = Reading.dashed (line)
                if want ~= nil and want ~= line then
                    table.insert (wrong, `{path}:{number} is dashed to {#line} rather than {#want}`)
                end

                if inside then
                    if string.match (line, "%a%-$") ~= nil then
                        table.insert (wrong, `{path}:{number} breaks a word across the line`)
                    end

                    inside = string.find (line, "]]", 1, true) == nil
                    was = false
                    continue
                end

                local bare = string.match (line, "^%s*(.*)$") :: string
                if string.sub (bare, 1, 4) == "--[[" then
                    inside = string.find (bare, "]]", 1, true) == nil
                    was = false
                    continue
                end

                local single = string.sub (bare, 1, 2) == "--"
                    and string.sub (bare, 1, 3) ~= "--!"
                    and want == nil

                if single and was then
                    table.insert (wrong, `{path}:{number} stacks a second comment line`)
                end

                --[[
                    A word broken across two lines, which reads as two and rejoins as one with a
                    space in the middle. Both happened: `byte- lexicographic` and `rate- gated`
                    were compounds a rewrap put back together wrongly.
                ]]
                if single and string.match (line, "%a%-$") ~= nil then
                    table.insert (wrong, `{path}:{number} breaks a word across the line`)
                end
                was = single
            end
        end
    end

    return failure (wrong)
end

-- A sentence as the words that say something about it, or nothing where it says too little.
local function meant (said: string): { [string]: boolean }?
    local words = Reading.words (said)
    if #words < ALIKE_ENOUGH then return nil end

    local held: { [string]: boolean } = {}
    for _, one in words do
        held[one] = true
    end
    return held
end

-- How much two sentences share, against the shorter of them, so a long one cannot dilute a match.
local function shares (mine: { [string]: boolean }, theirs: { [string]: boolean }): number
    local both, count, other = 0, 0, 0
    for one in mine do
        count += 1
        if theirs[one] then
            both += 1
        end
    end
    for _ in theirs do
        other += 1
    end
    return both / math.min (count, other)
end

--[[
    Every sentence a file says about its subject, with the banner left out: a suite's header and
    the header of the module it is about name one subject, so the two agree by design.
]]
local function about (path: string): { { at: number, said: string } }
    local source = Repo.read (path)
    if source == nil then return {} end

    local held = Reading.sentenced ((Reading.prosed (source)))
    local out = {}
    for _, one in held do
        if one.at > BANNER_ENDS then table.insert (out, one) end
    end
    return out
end

function Checks.twice (): Ruling.Ruling
    local homes: { [string]: { string } } = {}

    for _, dir in Repo.formatted () do
        for _, path in walk (dir, LUAU) do
            local source = Repo.read (path)
            if source == nil then continue end

            local spoken = Reading.prosed (source)
            for _, one in Reading.sentenced (spoken) do
                local normal = Reading.normal (one.said)
                if normal == nil then continue end

                local held = homes[normal]
                if held == nil then
                    homes[normal] = { `{path}:{one.at}` }
                    continue
                end
                table.insert (held, `{path}:{one.at}`)
            end
        end
    end

    local wrong = {}
    for _, where in homes do
        if #where < 2 then continue end
        table.insert (wrong, table.concat (where, " and "))
    end

    --[[
        The same reason in a suite and in the module it is about, written out differently. The
        copy above is what a paste makes and this is what a rewrite makes, which drifts alike and
        which no comparison of whole sentences sees. A suite is read against what it requires.
    ]]
    for _, dir in { Repo.TEST, Repo.FIXTURES, Repo.BENCH } do
        for _, path in walk (dir, LUAU) do
            local source = Repo.read (path)
            if source == nil then continue end

            local mine = about (path)
            for alias, named in string.gmatch (source, 'require %("@(%a+)/([%w/]+)"%)') do
                local under = ALIASES[alias]
                if under == nil then continue end

                local owner = `{under}/{named}.luau`
                if not Repo.exists (owner) then owner = `{under}/{named}/init.luau` end
                if not Repo.exists (owner) or owner == path then continue end

                for _, one in mine do
                    local said = meant (one.said)
                    if said == nil then continue end

                    for _, theirs in about (owner) do
                        local other = meant (theirs.said)
                        if other == nil or shares (said, other) < ALIKE then continue end

                        table.insert (wrong, `{path}:{one.at} says what {owner}:{theirs.at} says`)
                    end
                end
            end
        end
    end

    table.sort (wrong)

    if #wrong <= SAID_TWICE then
        if #wrong == SAID_TWICE then return { ok = true } end
        return { ok = false, note = `{#wrong} sentences are said twice, so the ceiling is stale` }
    end
    return failure (wrong)
end

--[[
    Where a path in a comment can start. A slash is a fraction as often as it is a path, so a token
    counts only where it opens at a tree or a layer this repository actually has.
]]
local WITHIN: { [string]: boolean } = {
    api = true,
    bench = true,
    channel = true,
    codec = true,
    emit = true,
    fixtures = true,
    harness = true,
    kernel = true,
    live = true,
    rules = true,
    runtime = true,
    scripts = true,
    shape = true,
    src = true,
    state = true,
    suite = true,
    test = true,
    units = true,
    wire = true,
}

--[[
    Every path a run of prose names that belongs to a tree here. The readme is hunted by name for
    the trees held to prose, and never where naming a document is the thing being described.
]]
local function sends (path: string, spoken: { string }, readme: boolean, wrong: { string })
    for number, line in spoken do
        for head, tail in string.gmatch (line, "(%a+)/([%w_/%.]+)") do
            if not WITHIN[head] then continue end
            table.insert (wrong, `{path}:{number} sends a reader to {head}/{tail}`)
        end

        if readme and string.find (line, "README", 1, true) ~= nil then
            table.insert (wrong, `{path}:{number} sends a reader to the readme`)
        end
    end
end

--[[
    A comment that hands a reader a map where an answer was wanted, which goes stale the moment the
    thing it points at moves. Backticks are no part of it, since a path in plain prose sends a
    reader exactly as far.
]]
function Checks.standing (): Ruling.Ruling
    local wrong = {}

    for _, dir in Repo.formatted () do
        local readme = dir ~= Repo.SCRIPTS

        for _, path in walk (dir, LUAU) do
            local source = Repo.read (path)
            if source == nil then continue end

            local sentences = Reading.prosed (source)
            sends (path, sentences, readme, wrong)
        end
    end

    for _, path in documents () do
        local text = Repo.read (path)
        if text ~= nil then sends (path, Reading.written (text), false, wrong) end
    end

    local declared = Repo.read (Repo.DTS)
    if declared ~= nil then sends (Repo.DTS, Reading.declared (declared), true, wrong) end

    if #wrong == 0 then return { ok = true } end
    return {
        ok = false,
        note = `{#wrong} comments send a reader elsewhere: ` .. table.concat (wrong, ", "),
    }
end

--[[
    Every way the entry can name a member of the surface: an entry in the table it freezes, a
    function hung on that table, and an assignment to it. The entry uses the first, and all
    three are as public as each other, so a gate reading one spelling holds one spelling.
]]
local NAMES = table.freeze ({
    "\n    ([%a_][%w_]*) = ",
    "\nfunction Lync%.([%a_][%w_]*)",
    "\nLync%.([%a_][%w_]*) = ",
})

--[[
    Every name the entry module binds must appear in the README, so an export cannot ship
    undocumented. The README may say more than the surface offers.
]]
function Checks.surface (): Ruling.Ruling
    local entry = Repo.read (Repo.ENTRY)
    local readme = Repo.read (Repo.README)
    if entry == nil then return { ok = true } end
    if readme == nil then return { ok = false, note = `{Repo.README} is unreadable` } end

    local wrong = {}
    for _, mark in NAMES do
        for binding in string.gmatch (entry, mark) do
            if string.find (readme, `%f[%w]{binding}%f[%W]`) ~= nil then continue end

            table.insert (wrong, `{binding} is undocumented`)
        end
    end

    return failure (wrong)
end

return table.freeze (Checks)
