--!strict
--!optimize 2
-- The persisted failing cases: parsed on the way in, and a block to paste on the way out.

local Rng = require ("@self/Rng")

local Corpus = {}

-- Constants -----------------------------------------------------------

--[[
    Where the corpus sits: the runner walks these two folders by name inside the test tree, and a
    case a run reports is pasted into the matching folder on disk.
]]
const UNDER = "data"
const FOLDER = "corpus"
const STORE = `test/{UNDER}/{FOLDER}`

-- The empty tape has no words to print, so it gets a mark of its own.
const NOTHING = "-"

const COMMENT = "#"

-- A tape holds the words a generator drew, so a word is whatever one draw answers.
const WORD = Rng.LARGEST

-- Types ---------------------------------------------------------------

export type Tape = { number }

-- Every tape a run may replay, what it has already seen, and what it would add.
export type Corpus = {
    _cases: { [string]: { Tape } },
    _known: { [string]: boolean },
    _pending: { [string]: { string } },
}

-- Private -------------------------------------------------------------

--[[
    One line into a tape, or an error naming where it went wrong. A corpus is a file a person edits,
    so a bad line has to say so: silently skipping one would mean a committed case stopped being
    replayed and nothing said a word about it.
]]
local function tape (name: string, at: number, text: string): Tape
    if text == NOTHING then return table.freeze ({} :: Tape) end

    local words: Tape = {}
    for token in string.gmatch (text, "%S+") do
        local word = tonumber (token)
        if word == nil or word % 1 ~= 0 or word < 0 or word > WORD then
            error (`{STORE}/{name}.txt line {at}: "{token}" is not a 32-bit word`, 0)
        end
        table.insert (words, word)
    end

    if #words == 0 then
        error (`{STORE}/{name}.txt line {at}: no words, and "{NOTHING}" means the empty tape`, 0)
    end
    return table.freeze (words)
end

--[[
    Blank lines separate, `#` annotates, and everything else is a case. Carriage returns are
    stripped because the corpus is committed with its bytes left alone, so a file edited on Windows
    arrives with them attached.
]]
local function parse (name: string, text: string): ({ Tape }, { [string]: boolean })
    local cases = {}
    local known = {}

    local at = 0
    for raw in string.gmatch (`{text}\n`, "([^\n]*)\n") do
        at += 1

        local trimmed = string.match (string.gsub (raw, "\r", ""), "^%s*(.-)%s*$") :: string
        if trimmed == "" then continue end
        if string.sub (trimmed, 1, 1) == COMMENT then continue end

        local parsed = tape (name, at, trimmed)
        local key = Corpus.line (parsed)
        if known[key] then continue end

        known[key] = true
        table.insert (cases, parsed)
    end
    return cases, known
end

-- Public --------------------------------------------------------------

Corpus.UNDER = UNDER
Corpus.FOLDER = FOLDER

-- One tape as a corpus file holds it, so a reported case reads as a pasted one.
function Corpus.line (tape: Tape): string
    if #tape == 0 then return NOTHING end
    return table.concat (tape, " ")
end

--[[
    Built from the text of every corpus file, keyed by the name the suite declared. Reading the tree
    is the runner's job, so this module holds the format alone and can be exercised without a place
    around it.
]]
function Corpus.new (sources: { [string]: string }): Corpus
    local cases = {}
    local known = {}

    for name, text in sources do
        local parsed, seen = parse (name, text)
        cases[name] = parsed
        for key in seen do
            known[`{name}|{key}`] = true
        end
    end

    return { _cases = cases, _known = known, _pending = {} }
end

-- Every case committed for this name, in file order, replayed before anything generated.
function Corpus.cases (of: Corpus, name: string): { Tape }
    local held = of._cases[name]
    if held == nil then return {} end
    return table.clone (held)
end

--[[
    Notes a case worth keeping, answering whether it was new. Studio cannot write to the tree, so a
    run cannot grow the corpus by itself. It collects what it found and `pending` says where to put
    it. Recording a case the file already holds is how a replayed corpus case avoids asking to be
    added twice.
]]
function Corpus.record (of: Corpus, name: string, drawn: Tape): boolean
    local written = Corpus.line (drawn)

    local key = `{name}|{written}`
    if of._known[key] then return false end
    of._known[key] = true

    local queued = of._pending[name]
    if queued == nil then
        queued = {}
        of._pending[name] = queued
    end
    table.insert (queued, written)
    return true
end

--[[
    What a person pastes to keep this run's findings, or nil when the run found nothing the corpus
    does not already hold. Names are sorted so two runs that found the same cases print the same
    block.
]]
function Corpus.pending (of: Corpus): string?
    local names = {}
    for name in of._pending do
        table.insert (names, name)
    end
    if #names == 0 then return nil end
    table.sort (names)

    local total = 0
    local out = {}
    for _, name in names do
        local queued = of._pending[name]
        total += #queued

        table.insert (out, `\n  {STORE}/{name}.txt`)
        for _, entry in queued do
            table.insert (out, `    {entry}`)
        end
    end

    local subject = if total == 1 then "1 case" else `{total} cases`
    table.insert (out, 1, `{subject} to add, so a later run replays them:`)
    return table.concat (out, "\n")
end

return table.freeze (Corpus)
