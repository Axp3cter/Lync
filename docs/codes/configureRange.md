---
family: caller
since: 5.0.0
---

# configureRange

A `Lync.configure` option is outside its range (v5.md §7.5). Nothing is applied. Unit F raises it; until
`Lync.configure` lands, the registry does not run this trigger.

## Example

The module `ServerScriptService.Main`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)

Lync.configure({ observe = { window = 2 } })
```

raises:

```example
ServerScriptService.Main:4: [Lync] configureRange: Lync.configure observe.window must be from 5 to 600, got 2
```

## Fix

Pass a value inside the range the option's row in v5.md §7.5 gives.
