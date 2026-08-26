--!strict
--!optimize 2
-- Who sees a partition, and what has changed about that since the last flush.

local Recipients = require ("@src/channel/Recipients")
local Types = require ("@src/Types")

local Audience = {}

-- Constants -----------------------------------------------------------

-- What a player seeded into a key is marked with, which is a flush no diff ever runs under.
const BEFORE = 0

-- Types ---------------------------------------------------------------

-- Who held a key at its last diff, under the number of the diff that put them there.
export type Seen = { [Player]: number }

-- One set's audiences: who each key is for, and who was holding it last time anyone asked.
export type Audience = {
    read of: { [any]: Types.Recipient },
    read held: { [any]: Seen },
    read wide: { [any]: boolean },
    read moved: { [any]: boolean },
    read now: { [any]: { Player } },
    read gained: { Player },
    read lost: { Player },
    at: number,
}

-- Public --------------------------------------------------------------

function Audience.new (): Audience
    return {
        of = {},
        held = {},
        wide = {},
        moved = {},
        now = {},
        gained = {},
        lost = {},
        at = BEFORE,
    }
end

-- A key's viewers, replacing whoever it had.
function Audience.assign (of: Audience, key: any, to: Types.Recipient)
    of.of[key] = to
    of.moved[key] = true
end

-- Whether a key goes to everybody, which is what puts its sections on the shared list.
function Audience.everyone (of: Audience, key: any): boolean
    local to = of.of[key]
    return to == nil or to == Recipients.ALL
end

-- Who holds a key, as the diff that ran this flush worked it out.
function Audience.members (of: Audience, key: any): { Player }
    local now = of.now[key]
    if now ~= nil then return now end

    now = {}
    of.now[key] = now
    return now
end

-- Who holds a key now, and who gained or lost it since the last time this asked.
function Audience.diff (of: Audience, key: any, ready: Recipients.Ready)
    table.clear (of.gained)
    table.clear (of.lost)

    local now = of.now[key]
    if now == nil then
        now = {}
        of.now[key] = now
    end

    local to = of.of[key]
    local open = to == nil or to == Recipients.ALL

    if open and of.moved[key] ~= true then
        table.clear (now)
        return
    end

    local held = of.held[key]
    if held == nil then
        held = {}
        of.held[key] = held
    end

    if of.wide[key] ~= false then
        for player in ready do
            held[player] = BEFORE
        end
    end

    of.moved[key] = nil
    of.wide[key] = open

    local at = of.at + 1
    of.at = at

    Recipients.resolve (now, if open then Recipients.ALL else to :: Types.Recipient, ready)

    for _, player in now do
        if held[player] == nil then table.insert (of.gained, player) end
        held[player] = at
    end

    -- Who stopped holding this key, which is who is owed a removal for everything under it.
    for player, when in held do
        if when == at then continue end

        held[player] = nil
        if ready[player] == nil then continue end

        table.insert (of.lost, player)
    end

    if open then table.clear (held) end
end

return table.freeze (Audience)
