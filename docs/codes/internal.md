---
family: internal
since: 5.0.0
---

# internal

An invariant inside Lync was broken: a Lync bug, never the result of a mistake in game code. The
message names the invariant. For example, the `t.rotation` encoder repeats q = encode(decode(q))
until it reaches a fixed point or a 2-cycle, and raises `internal` if that takes more than 4 steps
(v5.md §3.3). From milestone 2 an internal fault is a native report (§7.2).

## Example

Honest code cannot raise it, so the trigger below calls `Fail.caller` with the code directly, which
is the seam every `internal` raise goes through. The registry test runs it as the module named here
and compares its message with the example.

The module `ReplicatedStorage.Net.rotationCheck`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fail = require(ReplicatedStorage.Packages.Lync.diag.fail)

Fail.caller(
	"internal",
	"t.rotation encode",
	"reach a fixed point or a 2-cycle of encode(decode(q)) within 4 steps",
	nil,
	"report this as a Lync bug"
)
```

raises:

```example
ReplicatedStorage.Net.rotationCheck:4: [Lync] internal: t.rotation encode must reach a fixed point or a 2-cycle of encode(decode(q)) within 4 steps; report this as a Lync bug
```

## Fix

Report the message and the code that raised it as a Lync bug.
