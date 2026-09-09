# roblox-ts

The API is the same as in Luau, apart from the differences below.

| | Luau | roblox-ts |
| --- | --- | --- |
| Calls | `set:add(id, record)` | `set.add(id, record)` |
| Count | `#set` | `set.size()` |
| Records | `for id, record in set` | `for (const [id, record] of set.entries())` |
| Members | `for _, player in group` | `for (const player of group.players())` |
| Type helpers | `Types.Infer<C>` | `Lync.Infer<C>` |
| Instance class | `Lync.inst("Player")` | `Lync.inst<Player>()` |
| Audience key | Untyped | Typed from the `keyBy` field, so calling `audience` on a set without `keyBy` is a compile error. |

The package is scoped under `@axpecter`, so add that scope to the type roots and to the Rojo
project alongside `@rbxts`.

```json title="tsconfig.json"
"typeRoots": ["node_modules/@rbxts", "node_modules/@axpecter"]
```

A schema, its inferred type, and iteration over a set and a group.

```ts
import Lync from "@axpecter/lync";

const Fighter = Lync.struct({
    name: Lync.str(1, 20),
    team: Lync.enum(["red", "blue"] as const),
    score: Lync.int(0, 1_000_000),
});

// { name: string; team: "red" | "blue"; score: number }
type Fighter = Lync.Infer<typeof Fighter>;

const Net = Lync.define("arena", {
    Fighters: Lync.replicate(Fighter).keyBy("team"),
    Strike: Lync.packet(Lync.vec3()).unreliable(),
    Who: Lync.packet(Lync.inst<Player>()),
});

Net.Fighters.audience("red", Lync.all);

for (const [id, record] of Net.Fighters.entries()) {
    print(id, record.name);
}

for (const player of Lync.group().players()) {
    print(player.UserId);
}
```
