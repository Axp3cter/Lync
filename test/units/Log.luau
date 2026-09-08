--!strict
--!optimize 2
-- The record channel alone: what a record carries, what composes a line, and what the isolation
-- swallows.

local Catalog = require("@src/kernel/Catalog")
local Log = require("@src/kernel/Log")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local PATH = "roster.hp"
local WANTED = "a number from 0 to 100"
local GOT = "true"

type Record = { kind: string, message: string, data: { [string]: any } }

-- Every record the channel fans while `run` runs, with the printer held quiet meanwhile.
local function recorded(run: () -> ()): { Record }
    local held: { Record } = {}
    local link = Log.onLog(function(kind, message, data)
        table.insert(held, { kind = kind, message = message, data = data })
    end)
    local console = Log.console
    local wasConnected = console.connected
    if wasConnected then console:disconnect() end

    local ok, thrown = pcall(run)
    link:disconnect()
    if not ok then error(thrown, 0) end
    return held
end

local function filled(entry: Catalog.Entry): { [string]: unknown }
    local out: { [string]: unknown } = {}
    for _, key in entry.keys do
        out[key] = `<{key}>`
    end
    return out
end

return {
    Harness.case("log.console-is-a-connection", function()
        Expect.equal(typeof(Log.console.disconnect), "function")
        Expect.equal(typeof(Log.console.connected), "boolean")
    end),

    -- A record always carries the caller's file and line, and any facts handed over.
    Harness.case("log.warn-records", function()
        local held = recorded(function()
            Log.warn("something dropped", { definition = "beat" })
        end)
        Expect.equal(#held, 1)
        Expect.equal(held[1].kind, "warn")
        Expect.equal(held[1].message, "something dropped")
        Expect.equal(held[1].data.definition, "beat")
        Expect.equal(typeof(held[1].data.file), "string")
        Expect.equal(typeof(held[1].data.line), "number")
    end),

    -- An error is recorded and then thrown, in that order.
    Harness.case("log.error-records-then-throws", function()
        local held = recorded(function()
            Expect.throws(function()
                Log.error("a fault", nil)
            end, "a fault")
        end)
        Expect.equal(#held, 1)
        Expect.equal(held[1].kind, "error")
    end),

    -- A refusal is the caller's own mistake: raised where they asked and recorded nowhere.
    Harness.case("log.refusal-is-silent", function()
        local held = recorded(function()
            Expect.throws(function()
                Log.refuse("turned away")
            end, "turned away")
        end)
        Expect.equal(#held, 0)
    end),

    -- A rejection carries a code and facts and no line, for the boundary to compose.
    Harness.case("log.reject-carries-a-code", function()
        local ok, thrown = pcall(function()
            Log.reject(Catalog.TAG, { path = PATH })
        end)
        Expect.equal(ok, false)
        local rejection = thrown :: Log.Rejection
        Expect.equal(rejection.code, Catalog.TAG)
        Expect.equal(rejection.facts.path, PATH)
    end),

    -- A line with every fact behind it has no brace left in it and says every fact.
    Harness.case("log.format-fills-every-key", function()
        for code, entry in Catalog.entries do
            local said = Log.format(code, filled(entry))
            Expect.equal(string.match(said, Catalog.HELD), nil)
            Expect.holds(#said > 0, `{code} composed nothing at all`)
            for _, key in entry.keys do
                Expect.holds(string.find(said, `<{key}>`, 1, true) ~= nil, `{code} lost {key}`)
            end
        end
    end),

    -- A name with no fact behind it comes back in its braces rather than as a gap.
    Harness.case("log.format-keeps-a-missing-fact", function()
        local said = Log.format(Catalog.TAG, { path = PATH })
        Expect.holds(string.find(said, PATH, 1, true) ~= nil, "the fact it had was not said")
        Expect.holds(string.find(said, "{expected}", 1, true) ~= nil, "a missing one vanished")
        Expect.holds(string.find(said, "{got}", 1, true) ~= nil, "the other missing one vanished")
    end),

    -- A drop composes the rejection's line and merges its facts over the boundary's own.
    Harness.case("log.drop-composes-a-rejection", function()
        local held = recorded(function()
            local rejection = select(2, pcall(Log.reject, Catalog.TAG, { path = PATH, got = GOT }))
            Log.drop(rejection, { definition = "beat", expected = WANTED })
        end)
        Expect.equal(#held, 1)
        Expect.equal(held[1].kind, "warn")
        Expect.equal(held[1].data.code, Catalog.TAG)
        Expect.equal(held[1].data.definition, "beat")
        Expect.equal(held[1].data.path, PATH)
        Expect.equal(held[1].message, Log.format(Catalog.TAG, held[1].data))
        Expect.equal(held[1].data.file, "Lync")
    end),

    -- A raise that is no rejection reads as a bounds fault carrying what was said.
    Harness.case("log.drop-takes-a-bare-raise", function()
        local held = recorded(function()
            Log.drop("ran off the end", { definition = "beat" }, "error")
        end)
        Expect.equal(#held, 1)
        Expect.equal(held[1].kind, "error")
        Expect.equal(held[1].data.code, Catalog.BOUNDS)
        Expect.equal(held[1].data.said, "ran off the end")
    end),

    -- A call run for its answer, and a raise inside it recorded rather than propagated.
    Harness.case("log.call-records-a-raise", function()
        local held = recorded(function()
            local ok, value = Log.call(function(a: number, b: number)
                return a + b
            end, 2, 3)
            Expect.equal(ok, true)
            Expect.equal(value, 5)

            local failed, nothing = Log.call(function()
                error("a listener with a mistake in it", 0)
            end)
            Expect.equal(failed, false)
            Expect.equal(nothing, nil)
        end)
        Expect.equal(#held, 1)
        Expect.equal(held[1].kind, "error")
        Expect.holds(
            string.find(held[1].message, "a listener with a mistake in it", 1, true) ~= nil,
            "the raise is not in the record"
        )
    end),

    -- A spawned call cannot reach the caller, and its raise becomes a record.
    Harness.case("log.spawn-isolates", function()
        local held = recorded(function()
            Log.spawn(function()
                error("boom", 0)
            end)
        end)
        Expect.equal(#held, 1)
        Expect.equal(held[1].kind, "error")
    end),

    -- A listener failing on one payload is reported and still handed every later one.
    Harness.case("log.spawn-each-resumes-past-a-raise", function()
        local seen: { number } = {}
        local held = recorded(function()
            Log.spawnEach(function(value: number, extra: string)
                Expect.equal(extra, "extra")
                if value == 2 then error("two is bad", 0) end
                table.insert(seen, value)
            end, 4, { 1, 2, 3, 4 }, "extra")
        end)
        Expect.equal(seen, { 1, 3, 4 })
        Expect.equal(#held, 1)
    end),

    Harness.case("log.spawn-rows-walks-three-arrays", function()
        local seen: { string } = {}
        local held = recorded(function()
            Log.spawnRows(function(id: number, record: string, old: string?)
                if id == 2 then error("two is bad", 0) end
                table.insert(seen, `{id}:{record}:{old}`)
            end, 3, { 1, 2, 3 }, { "a", "b", "c" }, { "x", "y", "z" })
        end)
        Expect.equal(seen, { "1:a:x", "3:c:z" })
        Expect.equal(#held, 1)
    end),
}
