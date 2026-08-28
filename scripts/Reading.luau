--!strict
-- Every judgement the tooling makes that needs no repository.

local Reading = {}

-- Constants -----------------------------------------------------------

-- The words a sentence is made of that say nothing about its subject.
local BARE = "a an and are as at be been but by can could do does for from had has have how if in "
    .. "into is it its of on or the their them then there they this to was were what when where "
    .. "which who with would"

-- How many words a sentence needs before saying it twice is saying a fact twice.
local ENOUGH = 8

-- The column a divider is dashed out to.
local COLUMN = 72

local EMPTY: { [string]: boolean } = {}
for word in string.gmatch (BARE, "%a+") do
    EMPTY[word] = true
end

-- Public --------------------------------------------------------------

-- Every line of a text, so a fault can name the line it sits on.
function Reading.lines (text: string): { string }
    local found = {}
    for line in string.gmatch (`{text}\n`, "([^\n]*)\n") do
        table.insert (found, line)
    end
    return found
end

-- A span between backticks is quoted code, so it goes, unless what it holds is a path.
function Reading.quoted (line: string): string
    local out = string.gsub (line, "`([^`]*)`", function (held: string): string
        if string.match (held, "^[%w%.]+/[%w%./]+$") ~= nil then return `\`{held}\`` end
        return "``"
    end)
    return out
end

--[[
    Source with its prose removed. The constant hunt reads code: a comment saying "32-bit", or a
    message spelling a width out, is not a second home for anything, and left in they bury the
    matches that are.
]]
function Reading.stripped (source: string): string
    local without = string.gsub (source, '"[^"\n]*"', '""')
    without = string.gsub (without, "'[^'\n]*'", "''")
    without = string.gsub (without, "`[^`\n]*`", "``")
    without = string.gsub (without, "%-%-%[%[.-%]%]", " ")
    return (string.gsub (without, "%-%-[^\n]*", " "))
end

--[[
    The prose a declaration carries, line for line, with everything that is not a comment cut.

    A doc comment's own asterisks are its syntax and its close can sit beside a statement, so the
    delimiters come off and a line is read only as far as the close.
]]
function Reading.declared (source: string): { string }
    local spoken = {}
    local inside = false

    local function bare (held: string): string
        local out = string.gsub (held, "/%*+", "")
        out = string.gsub (out, "%*+/", "")
        out = string.gsub (out, "^%s*%*+", "")
        return Reading.quoted (out)
    end

    for _, line in Reading.lines (source) do
        if inside then
            table.insert (spoken, bare (line))
            inside = string.find (line, "*/", 1, true) == nil
            continue
        end

        local opens = string.find (line, "/*", 1, true)
        if opens ~= nil then
            local closes = string.find (line, "*/", opens, true)
            if closes == nil then
                table.insert (spoken, bare (string.sub (line, opens)))
                inside = true
            else
                table.insert (spoken, bare (string.sub (line, opens, closes + 1)))
            end
            continue
        end

        local slashes = string.find (line, "//", 1, true)
        if slashes == nil then
            table.insert (spoken, "")
            continue
        end
        table.insert (spoken, Reading.quoted (string.sub (line, slashes)))
    end

    return spoken
end

--[[
    The two prose streams a Luau file carries, line for line, which together are the inverse of
    `stripped`. Comments are sentences. Composed messages are the other place a module speaks to a
    person, and they are not sentences here, because a Luau pattern lives in the same syntax and a
    repeat in one is an operator rather than a bullet.
]]
function Reading.prosed (source: string): ({ string }, { string })
    local sentences, messages = {}, {}
    local inside = false

    for _, line in Reading.lines (source) do
        if inside then
            table.insert (sentences, Reading.quoted (line))
            table.insert (messages, "")
            inside = string.find (line, "]]", 1, true) == nil
            continue
        end

        local bare = string.gsub (line, '"[^"]*"', '""')
        bare = string.gsub (bare, "'[^']*'", "''")

        local comment = string.match (bare, "%-%-.*$")
        if comment == nil then
            table.insert (sentences, "")
            table.insert (messages, string.match (bare, "`[^`]*`") or "")
            continue
        end

        table.insert (sentences, Reading.quoted (comment))
        table.insert (messages, "")
        inside = string.find (comment, "--[[", 1, true) ~= nil
            and string.find (comment, "]]", 1, true) == nil
    end
    return sentences, messages
end

--[[
    A document's prose, line for line, with its code out of the way. A fenced block and a span
    between backticks are both code quoted into a sentence, and an asterisk inside either is an
    operator that was never the reader's to read.
]]
function Reading.written (document: string): { string }
    local kept = {}
    local fenced = false

    for _, line in Reading.lines (document) do
        if string.match (line, "^%s*```") ~= nil then
            fenced = not fenced
            table.insert (kept, "")
            continue
        end
        table.insert (kept, if fenced then "" else Reading.quoted (line))
    end
    return kept
end

-- A comment stream split where a reader would stop, as the line each sentence opens on.
function Reading.sentenced (spoken: { string }): { { at: number, said: string } }
    local out = {}
    local held, opens = {}, 0

    local function cut ()
        if #held == 0 then return end

        local run = table.concat (held, " ")
        for piece in string.gmatch (`{run} `, "(.-[%.:])%s") do
            table.insert (out, { at = opens, said = piece })
        end
        held, opens = {}, 0
    end

    for number, line in spoken do
        if line == "" or Reading.divides (line) then
            cut ()
            continue
        end

        if opens == 0 then opens = number end
        table.insert (held, (string.gsub (line, "^%s*%-%-%[?%[?%s*", "")))
    end

    cut ()
    return out
end

--[[
    A sentence as the one string two sayings of it both come to, and nothing where it names a path
    or is too short to say a fact twice.
]]
function Reading.normal (said: string): string?
    if string.match (said, "`[%w/]+/[%w/]+`") ~= nil then return nil end

    local words = Reading.words (said)
    if #words < ENOUGH then return nil end

    table.sort (words)
    return table.concat (words, " ")
end

-- Whether a comment line is a divider rather than a sentence.
function Reading.divides (line: string): boolean return Reading.dashed (line) ~= nil end

-- A divider as the one it would be at the column, or nothing where the line is no divider.
function Reading.dashed (line: string): string?
    local opens, name = string.match (line, "^(%s*)%-%-%s*([%w ]-)%s%-%-%-+%s*$")
    if opens == nil or name == nil or name == "" then return nil end

    local held = `{opens}-- {name} `
    return held .. string.rep ("-", math.max (1, COLUMN - #held))
end

-- Whether a document line is a table row, which has no break that reads well.
function Reading.tabular (line: string): boolean return string.match (line, "^%s*|") ~= nil end

--[[
    Whether two decoded config values are the same shape and content. Both directions, because a
    table holding everything the other does and one key more is a config that agrees about every
    fact anybody thought to compare.
]]
function Reading.same (left: any, right: any): boolean
    if typeof (left) ~= typeof (right) then return false end
    if typeof (left) ~= "table" then return left == right end

    for key, value in left do
        if not Reading.same (value, right[key]) then return false end
    end
    for key in right do
        if left[key] == nil then return false end
    end
    return true
end

--[[
    The first dotted number anywhere in the text. Every pinned tool answers --version with its
    version, most of them behind their own name, and one of them alone, so one rule reads all six.
]]
function Reading.versionIn (text: string): string? return string.match (text, "%d+%.%d+[%.%d]*") end

-- The words a sentence is made of that say something about its subject.
function Reading.words (said: string): { string }
    local out = {}
    for one in string.gmatch (string.lower (said), "%a+") do
        if not EMPTY[one] then table.insert (out, one) end
    end
    return out
end

-- Every word the names in a piece of code are made of, camel humps taken apart.
function Reading.names (code: string): { [string]: boolean }
    local out: { [string]: boolean } = {}

    for one in string.gmatch (code, "[%a_][%w_]*") do
        --[[
            Underscores and digits part a name first, then the humps part what is left. A run with
            no hump in it is one word already, which is how a shouted constant reads, and the run
            itself is kept either way so a name joined back up is a name a sentence could say.
        ]]
        for part in string.gmatch (one, "%a+") do
            out[string.lower (part)] = true
            for piece in string.gmatch (part, "%u?%l+") do
                out[string.lower (piece)] = true
            end
        end
    end
    return out
end

-- How much of a sentence is already in the names beside it, from none of it to all of it.
function Reading.echoed (said: string, code: string): number
    local words = Reading.words (said)
    if #words == 0 then return 0 end

    local names = Reading.names (code)
    local held = 0
    for _, one in words do
        if names[one] then
            held += 1
        end
    end
    return held / #words
end

return table.freeze (Reading)
