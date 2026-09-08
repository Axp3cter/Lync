# roblox-ts

```json title="tsconfig.json"
"typeRoots": ["node_modules/@rbxts", "node_modules/@axpecter"]
```

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

Net.Fighters.audience("red", Lync.all);     // typed: "red" | "blue"
for (const [id, record] of Net.Fighters.entries()) print(id, record.name);
for (const player of Lync.group().players()) print(player.UserId);
```

| | Luau | roblox-ts |
| --- | --- | --- |
| calls | `set:add(id, r)` | `set.add(id, r)` |
| count | `#set` | `set.size()` |
| records | `for id, r in set` | `for (const [id, r] of set.entries())` |
| members | `for _, p in group` | `for (const p of group.players())` |
| helpers | `Types.Infer<C>` | `Lync.Infer<C>` |
| instance class | `Lync.inst("Player")` | `Lync.inst<Player>()` |
| audience key | untyped | typed, so `audience` before `keyBy` is a compile error |

Add both folders to your Rojo project file as well as both type roots, since the package is scoped.
