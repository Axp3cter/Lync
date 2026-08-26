--!strict
--!optimize 2
-- The five ways to name an audience, and the one walk that turns any of them into players.

local Group = require ("@src/channel/Group")
local Types = require ("@src/Types")

local Recipients = {}

-- Types ---------------------------------------------------------------

--[[
    The clients a namespace may send to, which is the ones that have been told they may receive. A
    player who has joined and not finished the handshake discards a data frame on arrival, so naming
    one costs the bytes and buys nothing, and a player who has left is not in here at all.
]]
export type Ready = { [Player]: boolean }

-- Private -------------------------------------------------------------

--[[
    The members of one recipient, written from the front, and how many there are. The tail is left
    for the caller above to cut, because a resolve that is one form deep and one that recursed have
    different ideas about where the end is and only one of them is right.
]]
local function filled (into: { Player }, of: Types.Recipient, ready: Ready): number
    if typeof (of) == "Instance" then
        local player = of :: Player
        if not ready[player] then return 0 end

        into[1] = player
        return 1
    end

    local tagged = of :: any
    local count = 0

    if tagged._all == true then
        for player, allowed in ready do
            if not allowed then continue end

            count += 1
            into[count] = player
        end
        return count
    end

    if tagged._except == true then
        for player, allowed in ready do
            if not allowed or Recipients.holds (tagged.from, player) then continue end

            count += 1
            into[count] = player
        end
        return count
    end

    if Group.is (of) then
        for _, player in of :: Types.Group do
            if not ready[player] then continue end

            count += 1
            into[count] = player
        end
        return count
    end

    --[[
        A caller's own list, which is the one form that can name somebody twice. Two of a player is
        two frames to them, so the ones already written are read back before each is taken. Nothing
        else pays for that: the other four forms are sets already, and the scan here is over what a
        caller wrote rather than over everybody connected.
    ]]
    for _, player in of :: { Player } do
        if not ready[player] then continue end

        -- Past the count is whatever the last resolve left, which is nobody this one named.
        local seen = table.find (into, player)
        if seen ~= nil and seen <= count then continue end

        count += 1
        into[count] = player
    end
    return count
end

-- Public --------------------------------------------------------------

--[[
    Tagged with the phantom field its type declares, because the router tells the five recipient
    forms apart at run time and an untagged table would read as a list of players. Frozen, since one
    value is shared by every caller of the surface.
]]
Recipients.ALL = table.freeze ({ _all = true }) :: Types.All

--[[
    Everyone but this one, whatever form it takes. What it excludes is held rather than resolved,
    because a group's members and the connected set are both read when the flush goes out.
]]
function Recipients.except (from: Types.Recipient): Types.Except
    return table.freeze ({ _except = true, from = from }) :: any
end

--[[
    Whether a recipient names this player, which is the question an exclusion asks of everyone. A
    test, so nothing has to be built to answer it: an exclusion is asked once per ready client, and
    what it excludes is usually one player.
]]
function Recipients.holds (of: Types.Recipient, player: Player): boolean
    if typeof (of) == "Instance" then return of == player end

    local tagged = of :: any
    if tagged._all == true then return true end
    if tagged._except == true then return not Recipients.holds (tagged.from, player) end
    if Group.is (of) then return (of :: Types.Group):has (player) end

    return table.find (of :: { Player }, player) ~= nil
end

-- A recipient as the players it comes to, in an array the caller keeps and hands back next time.
function Recipients.resolve (into: { Player }, of: Types.Recipient, ready: Ready)
    local count = filled (into, of, ready)

    for index = #into, count + 1, -1 do
        into[index] = nil
    end
end

return table.freeze (Recipients)
