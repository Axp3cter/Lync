# roblox-ts

The API is the same as in Luau, apart from the differences below.

## Setup

The package is scoped under `@axpecter`. Add that scope to the type roots, and to the Rojo project
next to `@rbxts`.

```json title="tsconfig.json"
"typeRoots": ["node_modules/@rbxts", "node_modules/@axpecter"]
```

## Differences

| | Luau | roblox-ts |
| --- | --- | --- |
| Calls | `set:add(id, record)` | `set.add(id, record)` |
| Count | `#set`, `#group` | `set.size()`, `group.size()` |
| Records | `for id, record in set` | `for (const [id, record] of set.entries())` |
| Members | `for _, player in group` | `for (const player of group.players())` |
| Multiple returns | `local ok, reply = q:request(v)` | `const [ok, reply] = q.request(v)` |
| Encoding | `local bytes, refs = Lync.encode(c, v)` | `const [bytes, refs] = Lync.encode(c, v)` |
| `map` values | `{ [K]: V }` | `Map<K, V>` |
| Type helpers | `Types.Infer<C>`, `Types.Schema<F>` | `Lync.Infer<C>`, `Lync.Schema<S>` |
| Update argument | `Types.Update<T, Lync.None>` | `Lync.Update<T>` |
| Instance class | `Lync.inst("Player")` | `Lync.inst<Player>("Player")`. The type argument only sets the static type, so pass the class name too to have it checked. |
| Audience key | Untyped | Typed from the `keyBy` field. `audience` on a set without `keyBy` is a compile error. |

The `keyBy` type accepts any boolean, number or string field. At run time, `start` still refuses a
key that is not `bool`, `int`, `enum`, `vlq`, `vli` or `str`.

## Example

A schema, its inferred type, and a server using it. In a game, `Net` belongs in a shared module.

```ts
import { Players, RunService } from "@rbxts/services";
import Lync from "@axpecter/lync";

const Fighter = Lync.struct({
    owner: Lync.vli(),
    name: Lync.str(1, 20),
    score: Lync.int(0, 1_000_000),
});

// { owner: number; name: string; score: number }
type Fighter = Lync.Infer<typeof Fighter>;

const Net = Lync.define("arena", {
    Fighters: Lync.replicate(Fighter).keyBy("owner"),
    Who: Lync.packet(Lync.inst<Player>("Player")),
});

Lync.start();
RunService.PostSimulation.Connect(() => Lync.flush());
game.BindToClose(() => Lync.close());

function joined(player: Player) {
    Net.Fighters.audience(player.UserId, player);
    Net.Fighters.add(player.UserId, { owner: player.UserId, name: player.Name, score: 0 });
}

Players.PlayerAdded.Connect(joined);
for (const player of Players.GetPlayers()) joined(player);

for (const [id, record] of Net.Fighters.entries()) {
    print(id, record.name);
}
```
