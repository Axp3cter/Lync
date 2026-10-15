-- Design draft 2: does iterating a record literal follow declaration order? Decides how the
-- planner orders record fields when it reads an evaluated schema value (it cannot see source).
local record = { team = 1, name = 2, health = 3, position = 4, look = 5, title = 6 }
local order = {}
for key in record do
	table.insert(order, key)
end
print("declared: team name health position look title")
print("iterated: " .. table.concat(order, " "))
