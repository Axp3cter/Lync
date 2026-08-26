--!strict
--!optimize 2
--[[
    What the recipient walk answers for each of the five forms, and what it leaves behind.
]]

local Group = require ("@src/channel/Group")
local Recipients = require ("@src/channel/Recipients")
local Types = require ("@src/Types")

local Doubles = require ("@fixtures/Doubles")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- Four stand-ins, which is one more than any check needs.
const LABELS = table.freeze ({ "alice", "bob", "carol", "dave" })

-- The one who is on the roster and never told they may receive, which is what `ready` is about.
const ABSENT = "dave"

-- Types ---------------------------------------------------------------

-- A cast, as the players it made and the set a fire would be allowed to reach.
type Cast = {
    by: { [string]: Player },
    ready: Recipients.Ready,
}

-- Private -------------------------------------------------------------

--[[
    A cast, made through the roster because a recipient is a set of players and there is nothing
    to resolve without them. Four of them, so an exclusion leaves more than it takes.
]]
local function cast (): Cast
    local roster = Doubles.roster ()

    local by: { [string]: Player } = {}
    local ready: Recipients.Ready = {}

    for _, label in LABELS do
        local player = roster:join (label)
        by[label] = player
        ready[player] = label ~= ABSENT
    end
    return { by = by, ready = ready }
end

-- The players a recipient comes to, as the set of their names, which is what a check compares.
local function reached (of: Cast, who: Types.Recipient): { [string]: boolean }
    local into: { Player } = {}
    Recipients.resolve (into, who, of.ready)

    local out: { [string]: boolean } = {}
    for _, player in into do
        out[player.Name] = true
    end
    return out
end

-- Held against the names it should have come to, in both directions, so neither half stands alone.
local function same (got: { [string]: boolean }, wanted: { string })
    local held: { [string]: boolean } = {}
    for _, name in wanted do
        held[name] = true
        Expect.holds (got[name] == true, `{name} was not reached`)
    end

    for name in got do
        Expect.holds (held[name] == true, `{name} was reached and should not have been`)
    end
end

-- A group holding the named players, which is one of the five forms and the only built one.
local function grouped (of: Cast, names: { string }): Types.Group
    local held = Group.new ()
    for _, name in names do
        (held :: any):add (of.by[name])
    end
    return held
end

-- Public --------------------------------------------------------------

return {
    --[[
        Everybody, which is everybody a fire is allowed to reach rather than everybody there is.
        A player on the roster and not in the ready set is left out, which is the one thing
        readiness decides here.
    ]]
    Harness.case ("recipients.all", function ()
        local of = cast ()
        same (reached (of, Recipients.ALL), { "alice", "bob", "carol" })
    end),

    --[[
        One player, and the same player before they are listening. The second half is the one worth
        asking: a walk that took the instance it was handed without reading the ready set would send
        to somebody who throws the frame away, and would do it for the whole of a handshake.
    ]]
    Harness.case ("recipients.player", function ()
        local of = cast ()

        same (reached (of, of.by.alice), { "alice" })
        same (reached (of, of.by[ABSENT]), {})
    end),

    --[[
        A list, which is the form a caller writes out and the one that has to be read back as a
        set. What comes back is asked as a set for that reason, and the count is asked beside it so
        a list that named nobody twice would still have to come back one.
    ]]
    Harness.case ("recipients.list", function ()
        local of = cast ()

        same (reached (of, { of.by.alice, of.by.carol }), { "alice", "carol" })
        same (reached (of, { of.by.bob, of.by[ABSENT] }), { "bob" })
        same (reached (of, {}), {})
    end),

    --[[
        A list naming one player three times, and two of them naming each other's. Each player
        reaches the answer once, and the repeats are arranged so a scan that stopped early or
        started late would leave one behind.
    ]]
    Harness.case ("recipients.list-repeats", function ()
        local of = cast ()
        local twice = { of.by.alice, of.by.bob, of.by.alice, of.by.alice, of.by.bob }

        local into: { Player } = {}
        Recipients.resolve (into, twice, of.ready)

        Expect.equal (#into, 2)
        same (reached (of, twice), { "alice", "bob" })
    end),

    --[[
        A group, which is a set already and is walked in the order it holds. A member who is not
        listening is skipped the way one named directly is, since which form named them is the
        caller's business and whether a frame would land is not.
    ]]
    Harness.case ("recipients.group", function ()
        local of = cast ()

        same (reached (of, grouped (of, { "alice", "carol" })), { "alice", "carol" })
        same (reached (of, grouped (of, { "bob", ABSENT })), { "bob" })
        same (reached (of, grouped (of, {})), {})
    end),

    --[[
        Everyone but one, in each of the forms an exclusion can hold. Each is resolved through a
        ready set the exclusion never saw, which is what says the members are read at the flush.
    ]]
    Harness.case ("recipients.except", function ()
        local of = cast ()

        same (reached (of, Recipients.except (of.by.alice)), { "bob", "carol" })
        same (reached (of, Recipients.except ({ of.by.alice, of.by.bob })), { "carol" })
        same (reached (of, Recipients.except (grouped (of, { "carol" }))), { "alice", "bob" })
    end),

    --[[
        The two ends of an exclusion. Excluding everybody is nobody, and excluding somebody who is
        not listening is everybody who is, which is the reading that says the ready set is applied
        to the answer rather than to what was excluded.
    ]]
    Harness.case ("recipients.except-ends", function ()
        local of = cast ()

        same (reached (of, Recipients.except (Recipients.ALL)), {})
        same (reached (of, Recipients.except (of.by[ABSENT])), { "alice", "bob", "carol" })
        same (reached (of, Recipients.except ({})), { "alice", "bob", "carol" })
    end),

    --[[
        An exclusion of an exclusion, which is everyone the inner one named. Not a thing a caller
        has reason to write, and it falls out of asking the question recursively rather than being
        allowed for: refusing it would cost a test on a path where answering it costs nothing.
    ]]
    Harness.case ("recipients.except-except", function ()
        local of = cast ()
        local held = Recipients.except (Recipients.except (of.by.alice))

        same (reached (of, held), { "alice" })
        Expect.equal (Recipients.holds (held, of.by.alice), true)
        Expect.equal (Recipients.holds (held, of.by.bob), false)
    end),

    --[[
        Whether a recipient names one player, asked of every form. It is a test rather than a set,
        so that an exclusion asked once per listening client builds nothing, and it answers about
        the recipient alone: whether that player is listening is a separate question the walk asks.
    ]]
    Harness.case ("recipients.holds", function ()
        local of = cast ()
        local alice, bob = of.by.alice, of.by.bob

        Expect.equal (Recipients.holds (Recipients.ALL, alice), true)
        Expect.equal (Recipients.holds (alice, alice), true)
        Expect.equal (Recipients.holds (alice, bob), false)
        Expect.equal (Recipients.holds ({ alice, bob }, bob), true)
        Expect.equal (Recipients.holds ({ alice }, bob), false)
        Expect.equal (Recipients.holds (grouped (of, { "bob" }), bob), true)
        Expect.equal (Recipients.holds (grouped (of, { "bob" }), alice), false)
        Expect.equal (Recipients.holds (Recipients.except (alice), alice), false)
        Expect.equal (Recipients.holds (Recipients.except (alice), bob), true)

        -- Asked of somebody who is not listening, which the test has no opinion about.
        Expect.equal (Recipients.holds (Recipients.ALL, of.by[ABSENT]), true)
    end),

    --[[
        The array a fire hands back, and what is left in it. The tail is cut rather than left
        behind, so the count is the array's own length and there is one answer to how many there
        are. Cutting leaves the capacity, so the next fire fills the same slots without growing.
    ]]
    Harness.case ("recipients.resolve-cuts", function ()
        local of = cast ()
        local into: { Player } = {}

        Recipients.resolve (into, Recipients.ALL, of.ready)
        Expect.equal (#into, 3)

        Recipients.resolve (into, of.by.alice, of.ready)
        Expect.equal (#into, 1)
        Expect.equal (into[1], of.by.alice)
        Expect.equal (into[2], nil)

        Recipients.resolve (into, {}, of.ready)
        Expect.equal (#into, 0)
        Expect.equal (next (into), nil)
    end),

    --[[
        A departed player is not left held by a slot nobody reads. The cut is what does it: an array
        read to a count and never shortened would keep whoever the widest fire named for as long as
        the definition lives, which is a player the place cannot let go of.
    ]]
    Harness.case ("recipients.resolve-releases", function ()
        local of = cast ()
        local into: { Player } = {}

        Recipients.resolve (into, Recipients.ALL, of.ready)

        local held = {}
        for _, player in into do
            held[player.Name] = true
        end
        Expect.equal (#into, 3)

        of.ready[of.by.carol] = false
        Recipients.resolve (into, Recipients.ALL, of.ready)

        Expect.holds (held.carol == true, "the wide resolve never named carol")
        for _, player in into do
            Expect.holds (player.Name ~= "carol", "a departed player is still in the array")
        end
    end),

    -- A list naming somebody the array behind the count is still holding.
    Harness.case ("recipients.list-past-the-count", function ()
        local of = cast ()
        local into: { Player } = {}

        Recipients.resolve (into, { of.by.alice, of.by.bob, of.by.carol }, of.ready)
        Expect.equal (#into, 3)

        -- One name, so the count is one and the two slots behind it are the fire before this one's.
        Recipients.resolve (into, { of.by.carol }, of.ready)
        Expect.equal (#into, 1)
        Expect.equal (into[1], of.by.carol)
    end),

    --[[
        Nobody listening, asked of all five forms. A namespace whose clients have all left is the
        ordinary end of a round rather than a fault, so every form answers an empty array and none
        of them raises on the way.
    ]]
    Harness.case ("recipients.nobody-ready", function ()
        local of = cast ()
        for _, player in of.by do
            of.ready[player] = false
        end

        local held = grouped (of, { "alice", "bob" })
        for _, who in { Recipients.ALL, of.by.alice, { of.by.alice }, held } do
            same (reached (of, who :: Types.Recipient), {})
        end
        same (reached (of, Recipients.except (of.by.alice)), {})
    end),

    --[[
        Frozen and tagged, asked outright. Those are the two ways a shared sentinel stops being
        one: a value somebody could write to, or one the resolve walk no longer recognises.
    ]]
    Harness.case ("recipients.all-is-one-value", function ()
        Expect.equal (table.isfrozen (Recipients.ALL :: any), true)
        Expect.equal ((Recipients.ALL :: any)._all, true)
        Expect.equal (table.isfrozen (Recipients.except (Recipients.ALL) :: any), true)
    end),
}
