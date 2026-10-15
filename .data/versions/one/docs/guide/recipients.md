# Recipients and groups

A recipient says which clients something goes to. `fireClient` takes one, and so does a set's
[`audience`](sets.md#audiences).

## Recipients

| Recipient | Reaches |
| --- | --- |
| `Lync.all` | Every client. |
| `player` | One client. |
| `{ alice, bob }` | The listed clients. |
| `group` | The members of a [group](#groups). |
| `Lync.except(t)` | Every client but `t`, where `t` is a player, a list or a group. |

A recipient is resolved when the flush goes out, not when you name it. So `Lync.except(group)`
follows the group's membership at every flush.

## Joining

A client is reachable once it has called `Lync.start()` and its handshake has been accepted.

| Sent to a client still joining | Result |
| --- | --- |
| A packet | Dropped. |
| A server request | Ends with `"unanswered"`. |
| Set records | Sent once it joins, as the current state. |

To message a client as soon as it can hear you, have it fire a packet after `start` and answer from
that packet's listener.

## Groups

A group is a set of players you maintain, such as a team or a lobby.

```lua
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Lync)

local red = Lync.group()

local function joined(player: Player)
    red:add(player)
end

Players.PlayerAdded:Connect(joined)
for _, player in Players:GetPlayers() do
    joined(player)
end

for _, member in red do
    print(member.Name)
end
```

| Call | Does |
| --- | --- |
| `add(player)`, `remove(player)` | Adding a member twice or removing a non-member does nothing. |
| `has(player)` | Whether the player is a member. |
| `#group` | The number of members. |
| `for _, player in group` | Each member, in no fixed order. |
| `destroy()` | Empties the group. Any later use throws. |

Players who leave the game are removed from every group automatically.
