---
family: declaration
since: 5.0.0
---

# nameLength

A name is not a string of the allowed length: a namespace name is 1 to 64 bytes (v5.md §4.6);
definition, record field, union variant and `t.custom` names are 1 to 65,535 bytes (§4.7). A record
written as a list, such as `{ t.bool() }`, has fields named by numbers.

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

return Lync.schema("", {})
```

raises:

```example
ReplicatedStorage.Net.schema:5: [Lync] nameLength: Lync.schema name must be a string of 1 to 64 bytes, got ""
```

## Fix

Name it with a string of the allowed length.
