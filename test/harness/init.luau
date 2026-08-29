--!strict
--!optimize 2
-- The runner: what a suite declares, how a case is driven, and what a run prints.

local Workspace = game:GetService ("Workspace")

local Lync = require ("@src")
local Types = require ("@src/Types")

local Corpus = require ("@self/Corpus")
local Expect = require ("@self/Expect")
local Rng = require ("@self/Rng")
local Shrink = require ("@self/Shrink")

local Harness = {}

-- Constants -----------------------------------------------------------

--[[
    Cases each generated source runs, the one home of the budget table. The same numbers everywhere,
    with no focused mode and no skip: a run that can be narrowed is one that can differ on the day
    it matters.
]]
const BUDGETS = table.freeze ({
    -- The leaf algorithms, asked directly.
    leaves = 5000,
    --[[
        The kind matrix, which every property drawn over the vocabulary shares: what each kind
        offers, what it reads as, what its values do on the wire, and what a wrapper does to them.
    ]]
    kinds = 10000,
    -- The schema corpus, on whole namespaces compiled rather than one codec at a time.
    schemas = 4000,
    -- A value drawn for one codec and carried through it.
    encode = 10000,
    -- Bytes no encoder produced.
    decode = 15000,
    -- Runs of one set's life, against the reference model.
    model = 1000,
})

-- Where the two runs find each other, and how long each waits there.
const MEETING = "rendezvous"
const PATIENCE = 300

--[[
    Where declarations live and which machines run them. Units and rules are plain Luau, so no
    answer of theirs turns on the machine and running them twice buys nothing. Wire crosses the
    emitted closures, which compile natively on one side and are interpreted on the other, and
    live is one half per machine by its nature.
]]
const TREES = table.freeze ({
    table.freeze ({ name = "units", onClient = false }),
    table.freeze ({ name = "rules", onClient = false }),
    table.freeze ({ name = "wire", onClient = true }),
    table.freeze ({ name = "live", onClient = true }),
})

-- Types ---------------------------------------------------------------

export type Side = "server" | "client"

-- Read off the budget table, so a source and the number it runs cannot drift apart.
export type Source = keyof<typeof(BUDGETS)>

-- What a namespace holds, read from the library rather than restated here.
export type Definitions = Types.Definitions

--[[
    Everything a run can check. `sealed` is a case with a place in the schedule rather than a kind
    of its own question: it runs while the library is defined and not yet started, which is the one
    window two of the lifecycle's behaviours are about and no other declaration can see.
]]
export type Check =
    { read kind: "case", read name: string, read run: () -> () }
    | { read kind: "sealed", read name: string, read run: () -> () }
    | {
        read kind: "property",
        read name: string,
        read source: Source,
        read run: (Rng.Rng) -> (),
    }
    | { read kind: "pair", read name: string, read server: () -> (), read client: () -> () }

--[[
    A check, or a namespace a suite needs opened before any check runs. A suite returns both in one
    list because both are things it declares, and keeping them in one list is what lets the runner
    see every namespace before it opens the first of them.
]]
export type Declaration = Check | { read kind: "opens", read name: string, read defs: Definitions }

-- A declaration and the tree it came out of, which is how a run reports it.
type Held = { tree: string, declaration: Declaration }

-- What driving one declaration came to, with the count so a failure says how far it got.
type Outcome = {
    ok: boolean,
    note: string?,
    detail: string?,
    cases: number,
}

-- Private -------------------------------------------------------------

--[[
    An expectation that did not hold reads as itself. Anything else crashed and says so, because the
    two are different reports and a crash hiding inside a tidy failure line is how a real defect
    gets triaged as a wrong assertion.
]]
local function reason (thrown: unknown): string
    local failure = Expect.failed (thrown)
    if failure ~= nil then return failure.message end
    return `crashed: {tostring (thrown)}`
end

local function crashed (thrown: unknown): boolean return Expect.failed (thrown) == nil end

--[[
    Whether a shrink candidate reproduces the same class of fault. A tape that trips a different
    error is not a smaller version of this one, and following it would minimize toward a bug the run
    was not reporting. A generator that never settles is the sharpest case of that: only a shortened
    tape can pad far enough to raise it, so it is never the fault being minimized.
]]
local function repeats (run: (Rng.Rng) -> (), tape: Shrink.Tape, wasCrash: boolean): boolean
    local ok, thrown = pcall (run, Rng.replay (tape))
    if ok then return false end
    if string.find (tostring (thrown), Rng.UNSETTLED, 1, true) ~= nil then return false end
    return crashed (thrown) == wasCrash
end

--[[
    Where a declaration's seeds start. Two properties handed one schedule walk one stream of draws,
    which would hand the encode and decode fuzzers the same schemas in the same order. Folding the
    name in costs a run nothing and keeps a schedule stable as the declarations around it come and
    go.
]]
local function schedule (base: number, name: string): number
    local folded = 0
    for index = 1, #name do
        folded = bit32.band (folded * 31 + string.byte (name, index), 0xFFFFFFFF)
    end
    return bit32.bxor (base, folded)
end

local function seconds (from: number): string
    return string.format ("%.0f ms", (os.clock () - from) * 1000)
end

-- A yield often enough that the engine does not take a property for a hang.
const BREATH = 250

local function breathe (index: number)
    if index % BREATH == 0 then task.wait () end
end

-- A written case and one half of a live pair are the same thing to run: once.
local function once (run: () -> ()): Outcome
    local ok, thrown = pcall (run)
    if ok then return { ok = true, cases = 1 } end
    return { ok = false, note = reason (thrown), cases = 1 }
end

local function drive (declaration: Check, side: Side, store: Corpus.Corpus, base: number): Outcome
    if declaration.kind == "case" or declaration.kind == "sealed" then
        return once (declaration.run)
    end
    if declaration.kind == "pair" then
        return once (if side == "server" then declaration.server else declaration.client)
    end

    local name = declaration.name
    local run = declaration.run

    -- The corpus first, always in full: it is every fault an earlier run found.
    local held = Corpus.cases (store, name)
    for index, tape in held do
        breathe (index)

        local ok, thrown = pcall (run, Rng.replay (tape))
        if ok then continue end

        local detail = `corpus case {index}: {Corpus.line (tape)}`
        return { ok = false, note = reason (thrown), detail = detail, cases = index }
    end

    local from = schedule (base, name)

    -- Widened once: Luau will not index a sealed table by a union of its own keys.
    local budget = (BUDGETS :: { read [Source]: number })[declaration.source]
    for index = 1, budget do
        breathe (index)

        local generator = Rng.new (from + index)

        local ok, thrown = pcall (run, generator)
        if ok then continue end

        local wasCrash = crashed (thrown)
        local minimal = Shrink.run (
            Rng.tape (generator),
            function (tape: Shrink.Tape): boolean return repeats (run, tape, wasCrash) end
        )
        Corpus.record (store, name, minimal)

        return {
            ok = false,
            note = reason (thrown),
            detail = `case {Corpus.line (minimal)}`,
            cases = #held + index,
        }
    end

    return { ok = true, cases = #held + budget }
end

-- Every declaration a tree holds, its modules walked in name order.
local function collect (tree: Instance): { Declaration }
    local found: { Declaration } = {}

    local children = tree:GetChildren ()
    table.sort (children, function (a: Instance, b: Instance): boolean return a.Name < b.Name end)

    for _, child in children do
        if not child:IsA ("ModuleScript") then continue end

        local list = require (child) :: { Declaration }
        assert (
            typeof (list) == "table" and #list > 0,
            `{tree.Name}/{child.Name} returns no declarations`
        )
        table.move (list, 1, #list, #found + 1, found)
    end
    return found
end

-- The text of every corpus file, keyed by the name its declaration carries.
local function stored (root: Instance): { [string]: string }
    local sources = {}

    local data = root:FindFirstChild (Corpus.UNDER)
    local folder = if data ~= nil then data:FindFirstChild (Corpus.FOLDER) else nil
    if folder == nil then return sources end

    for _, child in folder:GetChildren () do
        if child:IsA ("StringValue") then sources[child.Name] = child.Value end
    end
    return sources
end

--[[
    Whether this side runs this declaration. A pair is one check written as the half each machine
    performs, so both run it. A namespace is opened on both machines whatever tree it came from,
    because requiring the same schema on both is what sharing it means. Everything else follows its
    tree.
]]
local function runs (declaration: Declaration, side: Side, onClient: boolean): boolean
    if declaration.kind == "pair" or declaration.kind == "opens" then return true end
    return side == "server" or onClient
end

-- Every declaration this side runs, in tree order, each carrying the tree it came from.
local function gathered (root: Instance, side: Side): { Held }
    local found: { Held } = {}

    for _, tree in TREES do
        local folder = assert (root:FindFirstChild (tree.name), `the test tree has no {tree.name}`)
        for _, declaration in collect (folder) do
            if not runs (declaration, side, tree.onClient) then continue end
            table.insert (found, { tree = tree.name, declaration = declaration })
        end
    end
    return found
end

--[[
    Every namespace the run declared, opened in the order the trees were walked. A name two suites
    both open throws out of `define`, which is the right failure and needs nothing here: two suites
    naming one namespace disagree about who owns it, and the traceback says which two.
]]
local function opened (held: { Held }): { string }
    local names = {}

    for _, entry in held do
        local declaration = entry.declaration
        if declaration.kind ~= "opens" then continue end

        Lync.define (declaration.name, declaration.defs :: any)
        table.insert (names, declaration.name)
    end
    return names
end

--[[
    The meeting, as the two halves of it. Answers what to call when this side reaches the live tree,
    so the remote and its handler are in place before the first check runs.
]]
local function rendezvous (root: Instance, side: Side): () -> ()
    if side == "server" then
        local remote = Instance.new ("RemoteEvent")
        remote.Name = MEETING
        remote.Parent = root

        local here, open = 0, false
        remote.OnServerEvent:Connect (function (who: Player)
            here += 1
            if open then remote:FireClient (who) end
        end)

        return function ()
            local deadline = os.clock () + PATIENCE
            while here == 0 and os.clock () < deadline do
                task.wait ()
            end

            open = true
            remote:FireAllClients ()
            if here == 0 then warn (`  no client reached the meeting in {PATIENCE} s`) end
        end
    end

    local found = root:WaitForChild (MEETING, PATIENCE)
    if found == nil then
        return function () warn (`  no meeting appeared in {PATIENCE} s`) end
    end

    local remote = found :: RemoteEvent
    local go = false
    remote.OnClientEvent:Connect (function () go = true end)

    return function ()
        local deadline = os.clock () + PATIENCE
        while not go and os.clock () < deadline do
            remote:FireServer ()
            task.wait (1)
        end
        if not go then warn (`  the server did not reach the meeting in {PATIENCE} s`) end
    end
end

-- Public --------------------------------------------------------------

--[[
    Waits for something the other machine has to do. Every live check needs one: a half asserting
    the moment it ran would be asserting about traffic still in flight. The patience a caller passes
    is short, because the two runs have already met and what is left to wait for is a round trip
    rather than a suite.
]]
function Harness.awaits (what: string, holds: () -> boolean, patience: number)
    local deadline = os.clock () + patience
    while not holds () do
        Expect.holds (os.clock () < deadline, `{what} did not arrive in {patience} s`)
        task.wait ()
    end
end

--[[
    A run with connections held open for it and dropped however it ends. A raise leaves through the
    pcall, so a caller disconnecting on its last line would keep its listeners on the one occasion
    it mattered, and the next check on that definition would hear traffic it never sent.
]]
function Harness.attached (links: { Types.Connection }, run: () -> ())
    local ok, thrown = pcall (run)
    for _, link in links do
        link:disconnect ()
    end

    if not ok then error (thrown, 0) end
end

--[[
    A span of the shared clock, taken by both halves at once, with one namespace draining
    throughout. The two have to overlap or the traffic between them lands on nobody, so each takes
    the next boundary: rounding to the nearest names one already past for half of every span, and
    neither half waits at all. A failure still waits the span out, keeping the two in step.
]]
function Harness.together (seconds: number, name: string, run: () -> ())
    local opens = math.floor (Workspace:GetServerTimeNow () / seconds) * seconds + seconds
    while Workspace:GetServerTimeNow () < opens do
        task.wait ()
    end

    local going = true
    task.spawn (function ()
        while going do
            Lync.flush (name)
            task.wait ()
        end
    end)

    local ok, thrown = pcall (run)

    while Workspace:GetServerTimeNow () < opens + seconds do
        task.wait ()
    end
    going = false

    if not ok then error (thrown, 0) end
end

-- One check written out, run wherever its tree says it runs and asked once.
function Harness.case (name: string, run: () -> ()): Declaration
    return table.freeze ({ kind = "case" :: "case", name = name, run = run })
end

--[[
    A case that runs while the library is defined and not yet started. What lives in that window
    is a namespace that may still be handed something, and a call refused for being early.
]]
function Harness.sealed (name: string, run: () -> ()): Declaration
    return table.freeze ({ kind = "sealed" :: "sealed", name = name, run = run })
end

--[[
    A namespace this suite needs, opened before any check runs. `start` runs once per machine and
    nothing reopens it, so every suite that needs a started library shares one start, and the only
    way that can work is for the runner to learn every namespace before it opens the first one.
]]
function Harness.opens (name: string, defs: Definitions): Declaration
    return table.freeze ({ kind = "opens" :: "opens", name = name, defs = defs })
end

--[[
    One check asked of drawn values rather than written ones. The source names both where the draws
    come from and how many are made, so a suite chooses a corpus and never a count: the budgets are
    weighed against each other in one table and a declaration picking its own would be outside that.
]]
function Harness.property (name: string, source: Source, run: (Rng.Rng) -> ()): Declaration
    return table.freeze ({
        kind = "property" :: "property",
        name = name,
        source = source,
        run = run,
    })
end

-- One live check, written as the half each machine performs.
function Harness.pair (name: string, server: () -> (), client: () -> ()): Declaration
    return table.freeze ({ kind = "pair" :: "pair", name = name, server = server, client = client })
end

--[[
    Runs every tree this side owns, in passes over one gathered list: every namespace opens, every
    sealed case runs against a library defined and not started, then the library starts and
    everything but the live tree runs, and the two machines meet before the live tree does. The
    order is this list's, and no filename decides it.
]]
function Harness.run (side: Side, seed: number?)
    local root = assert (script.Parent, "the harness expects to sit under the test tree")
    local base = if seed ~= nil then seed else Rng.BASE

    local store = Corpus.new (stored (root))
    local held = gathered (root, side)
    local started = os.clock ()
    local passed, failed = 0, 0

    --[[
        The meeting is arranged before anything runs and held before the live tree, so a hello sent
        while the other side is still on its units is heard rather than lost. A run with nothing
        live arranges none: there is nobody to meet and nothing to meet about.
    ]]
    local meets: (() -> ())? = nil
    for _, entry in held do
        if entry.tree ~= "live" then continue end
        meets = rendezvous (root, side)
        break
    end

    print (`Lync test: {side}, seed {base}`)

    local namespaces = opened (held)
    if #namespaces > 0 then print (`  namespaces: {table.concat (namespaces, ", ")}`) end

    local announced: string? = nil
    local function sweep (under: string, wanted: (Held) -> boolean)
        for _, entry in held do
            local declaration = entry.declaration
            if declaration.kind == "opens" then continue end
            if not wanted (entry) then continue end

            local heading = if under ~= "" then under else entry.tree
            if announced ~= heading then
                announced = heading
                print (`  {heading}`)
            end

            local began = os.clock ()
            local outcome = drive (declaration, side, store, base)

            if outcome.ok then
                passed += 1
                print (`    ok   {declaration.name}  {outcome.cases} cases  {seconds (began)}`)
                continue
            end

            failed += 1
            warn (`    FAIL {declaration.name}  after {outcome.cases} cases`)
            warn (`         {outcome.note}`)
            if outcome.detail ~= nil then warn (`         {outcome.detail}`) end
        end
    end

    local function sealed (entry: Held): boolean return entry.declaration.kind == "sealed" end

    local function alone (entry: Held): boolean
        return entry.declaration.kind ~= "sealed" and entry.tree ~= "live"
    end

    local function paired (entry: Held): boolean return entry.tree == "live" end

    sweep ("before the seal", sealed)

    Lync.start ()

    sweep ("", alone)

    if meets ~= nil then meets () end
    sweep ("", paired)

    local summary = `\n  {passed} passed, {failed} failed in {seconds (started)}`
    if failed == 0 then
        print (summary)
    else
        warn (summary)
    end

    local pending = Corpus.pending (store)
    if pending ~= nil then warn (`\n{pending}`) end
end

return table.freeze (Harness)
