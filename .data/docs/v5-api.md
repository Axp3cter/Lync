# Lync v5: API and syntax

The public surface of v5, with every decision made. It builds on [v5-goals.md](v5-goals.md),
[v5-failures.md](v5-failures.md) and [v5-research.md](v5-research.md).

**Verified.** [`.data/probes/ApiTypes.luau`](../probes/ApiTypes.luau) prototypes this whole surface as
types and checks on luau-lsp 1.70.1 (Luau 0.740, new solver). Its only diagnostics are the eleven
deliberate mistakes it contains, each caught (§9).

## 1. A whole game's networking

```luau
-- ReplicatedStorage/Net.luau: the schema, shared by both sides
local Lync = require("@packages/Lync")

return Lync.namespace({
	chat = Lync.event(Lync.string(200)),

	strike = Lync.event({
		target   = Lync.integer(0, 255),
		position = Lync.vector3(-512, 512, 0.1),
	}):unreliable():timestamped(),

	outcome = Lync.event(Lync.union({
		hit  = { target = Lync.integer(0, 255) },
		miss = { distance = Lync.number(0, 100, 0.1) },
	})),

	sell = Lync.request(Lync.oneOf({ sword = true, shield = true }), Lync.integer(0, 100_000)),

	fighters = Lync.collection({
		team      = Lync.oneOf({ red = true, blue = true }):partition(),
		health    = Lync.integer(0, 100),
		position  = Lync.vector3(-512, 512, 0.1):latest(20),
		title     = Lync.string(16):optional(),
		inventory = Lync.array(Lync.string(16), 32),
	}),
})
```

```luau
-- A server script
local Net = Lync.server(require(ReplicatedStorage.Net))

Net.chat:limit(5)
Net.chat:validate(function(text, player)
	return if string.find(text, "%S") then nil else "chat text must not be blank"
end)

Net.chat:connect(function(text, player)
	Net.chat:fire(Lync.all, `{player.Name}: {text}`)
end)

Net.sell:handle(function(item, player)
	return PRICES[item]
end)

Net.fighters[player.UserId] = { team = "red", health = 100, position = Vector3.zero, inventory = {} }
Net.fighters:update(player.UserId, { health = 90 })
Net.fighters:show("red", redTeam)
```

```luau
-- A client script
local Net = Lync.client(require(ReplicatedStorage.Net))

Net.chat:fire("hello")

Net.strike:connect(function(strike, sentAt)
	print(`strike on {strike.target}, sent at {sentAt}`)
end)

local sold = Net.sell:invoke("sword")
if sold.ok then
	print(`sold for {sold.value}`)
end

Net.fighters.added:connect(function(id, fighter)
	print(`{id} joined {fighter.team}`)
end)
```

There is no start call, no flush wiring and no shutdown binding. Every argument, callback parameter and
result is typed from the schema with no annotations.

## 2. Predictability rules

Each holds without exception.

1. **One schema, two views.**
   - A namespace is declared once and shared.
   - Each script takes its side's view with `Lync.server(namespace)` or `Lync.client(namespace)`.
   - A view offers exactly what that side can do, so there is one name per action and calling the
     other side's API is a type error.
2. **One name per action, on both sides.** The signatures differ only where the sides differ: the
   server names recipients and receives the sender.

   | Action | Server | Client |
   |---|---|---|
   | Send an event | `fire(recipients, value)` | `fire(value)` |
   | Listen to an event | `connect(function(value, player) end)` | `connect(function(value) end)` |
   | Ask a request | `invoke(player, value)` | `invoke(value)` |
   | Answer a request | `handle(function(value, player) return reply end)` | `handle(function(value) return reply end)` |

3. **The verb tells the behaviour.** `connect` adds a listener and returns a Connection, as on any
   Roblox signal. `handle` sets the one handler a request has, replacing any earlier one.
4. **Roblox's vocabulary.** `fire`, `connect` and `invoke` mean what they mean on Roblox's Bindables.
   A collection's `added`, `changed` and `removed` are signals connected like `PlayerAdded`.
5. **Casing.** Everything on `Lync` is lowerCamel, like any Luau value. Names from Roblox keep their
   spelling as data keys: `Lync.instance.Player`, `Lync.enum.Material`.
6. **Codec naming.** A leaf codec is named after the type it carries (`boolean`, `number`, `string`,
   `buffer`, `vector2`, `vector3`, `cframe`, `color3`, `instance`, `enum`). A constraint is named for
   the constraint (`integer`, `direction`, `rotation`, `angle`, `oneOf`, `flags`).
7. **Values and calls.** Every leaf codec is a value that works as is, and calling it refines it.
8. **Parameters.** There are two kinds:
   - **limits:** `maxBytes`, `maxCount`, optional and last;
   - **accuracy:** `min, max, step`, or `step` alone, with `step` last and in the value's own unit.
9. **Illegal combinations are type errors.**
   - An unreliable event has no `:latest()`.
   - A collection marker in an event schema is rejected with a message.
   - A client view's collections are read-only.
10. **Payload first.** Listeners receive the payload, then the sender (server), then the send time
    (timestamped events), in the same order on both sides.
11. **The schema is the wire; policy is the server's.**
    - The shared schema holds only what encoding and decoding need: shapes, bounds, delivery modes and
      conversions.
    - Validation and rate limits are set on the server view, so their code never reaches a client
      (§7.1).

## 3. Codecs

### 3.1 Leaf codecs

| Value | Refined by | Carries | Wire |
|---|---|---|---|
| `Lync.boolean` | | `boolean` | 1 bit |
| `Lync.integer` | `(min, max)` | `number` | Unbounded: signed, variable length. Bounded: bits to count the range. |
| `Lync.number` | `(min, max, step)` | `number` | Exact double, or quantized |
| `Lync.string` | `(maxBytes)` | `string` | Length, then bytes |
| `Lync.buffer` | `(maxBytes)` | `buffer` | Length, then bytes |
| `Lync.vector2`, `Lync.vector3` | `(min, max, step)` | `Vector2`, `Vector3` | Roblox's own single precision, or quantized per component |
| `Lync.cframe` | `(position, rotation)` | `CFrame` | Exact, or two codecs |
| `Lync.color3` | `(step)` | `Color3` | Exact, or quantized per channel (`1 / 255` is 8 bits) |
| `Lync.angle` | `(step)` | `number` | Degrees, wrapping at a turn |
| `Lync.direction` | `(step)` | `Vector3` | A unit vector, normalized when sent |
| `Lync.rotation` | `(step)` | `CFrame` | Rotation only |
| `Lync.instance` | | `Instance?` | A reference beside the buffer |
| `Lync.instance.Player`, `.Part`, … | | `Player?`, `Part?`, … | The same, refused unless `:IsA` the class |
| `Lync.enum.Material`, `.KeyCode`, … | | `Enum.Material`, `Enum.KeyCode`, … | Bits to count the items |

- **Optional instances.** An instance the receiver cannot see arrives as `nil`, so instance codecs
  carry an optional type.
- **Generated tables.** `Lync.instance` and `Lync.enum` list every creatable class and every Enum, so
  autocomplete offers them and typos are type errors. Their types are generated from the pinned API
  dump by a Lute script; at runtime both resolve names lazily.

### 3.2 Composite codecs

| Constructor | Carries | Notes |
|---|---|---|
| `{ name = codec, … }` | `{ name: T, … }` | A record is a plain table of codecs |
| `Lync.array(codec, maxCount?)` | `{ T }` | Without a limit, the count is still checked against the bytes that arrived |
| `Lync.map(key, value, maxCount?)` | `{ [K]: V }` | The same |
| `Lync.oneOf({ red = true, blue = true })` | `"red" \| "blue"` | Written as Luau's set literal, the only form Luau types exactly |
| `Lync.flags({ jump = true, crouch = true })` | `{ jump: boolean, crouch: boolean }` | One bit per name |
| `Lync.union({ hit = {…}, miss = {…} })` | `{ kind: "hit", … } \| { kind: "miss", … }` | The discriminant is always `kind` |
| `Lync.convert(wire, { decode = …, encode = … })` | your type | Carries any type over a wire codec |

### 3.3 Modifiers

| Method | Gives |
|---|---|
| `codec:optional()` | The same codec carrying `T?` |
| `codec:latest(rate?)` | A collection field sent as latest value only, unreliably, at most `rate` times a second |
| `codec:partition()` | Marks the collection field that decides who sees each record |

## 4. Events

Declared in the schema:

| Declaration | Effect |
|---|---|
| `Lync.event(schema?)` | Reliable and ordered; no schema means no payload |
| `:unreliable()` | Lossy and unordered; every fire is sent |
| `:latest(rate?)` | Lossy; only the newest value per recipient is sent, at most `rate` per second |
| `:timestamped()` | Listeners also receive `sentAt: number` |

`:unreliable()` and `:latest()` exclude each other, and `:timestamped()` adds `sentAt` to listener
types. So all four combinations type exactly.

Used through a view:

| Server | Client |
|---|---|
| `event:fire(recipients, value)` | `event:fire(value)` |
| `event:connect(function(value, player, sentAt) end)` | `event:connect(function(value, sentAt) end)` |
| `event:validate(function(value, player) return reason? end)` | |
| `event:limit(perSecond)` | |

- **`validate`** refuses an arriving value when the check returns a reason. The value is dropped and
  counted, and no listener sees it.
- **`limit`** caps each player's fires per second; the excess is dropped and counted.

## 5. Requests

Declared in the schema:

```luau
sell = Lync.request(requestSchema, replySchema):timeout(5)
```

Used through a view:

| Server | Client |
|---|---|
| `request:invoke(player, value)` yields, returns `Result<Reply>` | `request:invoke(value)` yields, returns `Result<Reply>` |
| `request:handle(function(value, player) return reply end)` | `request:handle(function(value) return reply end)` |
| `request:validate(function(value, player) return reason? end)` | |
| `request:limit(perSecond)` | |

- **Results:** `{ ok: true, value: Reply } | { ok: false, reason: "Timeout" | "Unanswered" | "Left" | "Shutdown" }`.
- **Handlers:** one per side. A request that arrives before its handler is set waits for it, up to
  the timeout.
- **Default timeout:** 10 seconds.

## 6. Collections

Records the server owns, replicated to the clients allowed to see them.

**Server view: writes.**

| Write | Does |
|---|---|
| `collection[id] = record` | Inserts or replaces a record |
| `collection[id] = nil` | Removes it |
| `collection:update(id, patch)` | Changes only the given fields; `Lync.none` clears an optional field |
| `collection:clear()` | Removes everything |
| `collection:show(key, recipients)` | Who sees the records whose partition field equals `key` |
| `collection:hide(key)` | Nobody sees them |

**Both views: reads and signals.** The client view is read-only.

| Form | Gives |
|---|---|
| `collection[id]` | The record or nil; its fields are read-only to the checker |
| `#collection` | How many records this side holds |
| `for id, record in collection` | Each record this side holds |
| `collection.added:connect(function(id, record) end)` | A record appears here: inserted, joined, or newly shown |
| `collection.changed:connect(function(id, record, previous) end)` | A record changed |
| `collection.removed:connect(function(id, previous) end)` | A record is gone from here, with its last value |

**Visibility.**
- A collection without a partition field goes to every client.
- With one, a key that was never shown goes to nobody, so a forgotten `show` hides data instead of
  leaking it.

**Privacy and the server.**
- `removed` does not say whether a record was deleted or hidden, so a client cannot learn that a
  hidden record still exists.
- Signals fire on the server for the server's own writes, so server systems can react to state.

## 7. Everything else

| Member | Is |
|---|---|
| `Lync.namespace(definitions)` | Returns the definitions, frozen. The namespace is named after the module that declares it, so server and client match without a string. One namespace per module. |
| `Lync.server(namespace)`, `Lync.client(namespace)` | That side's view. Taking the other side's view throws. |
| `Lync.group()` | A player set: `add`, `remove`, `has`, `#group`, `for player in group`. Leavers are removed automatically. |
| `Lync.all`, `Lync.except(recipients)` | Recipients, beside a player, a list of players and a group |
| `Lync.none` | Clears an optional field in `update` |
| `Lync.observe(observer)` | The typed event stream ([v5-failures.md](v5-failures.md) §6) |
| `Lync.metrics()` | Counters per definition and namespace |
| `definition:trace()` | Opt-in printing of each send and arrival |
| `Lync.configure({ flush = "Manual" })`, `Lync.flush(namespace?, budget?)` | Manual flushing |
| `Lync.stop()` | Ends everything; automatic on server shutdown |

**Starting.**
- Lync starts the first time a view is used, in its own thread, so connecting a listener never
  yields.
- Sends made while a client is still joining wait until it is ready.

### 7.1 What clients can see

**Why the schema is shared.** A client must hold a working encoder for everything it sends and a
decoder for everything it receives, so the wire schema necessarily reaches it. Keeping the schema on
the server and transferring it at join time would not hide it:
- whatever is transferred sits in client memory;
- an exploiter does not need to read the format at all: they can call the client's own
  `fire(...)` and produce perfectly valid packets;
- detection that relies on the format being secret falls to trial and error.

So security never depends on the format being secret. The server treats every arrival as hostile:
the decoder refuses anything that does not fit the schema, and `validate` and `limit` judge the rest.

**What stays secret is policy.**
- Validation rules and rate limits are set on the server view, in server scripts, so they never
  replicate.
- The shared schema carries only shapes, bounds, delivery modes and conversions. Conversions must be
  shared, because both sides run them.

**Rejected alternative:** a server-only schema transferred at join time. It hides nothing that
matters and costs:
- typed client code;
- shared conversion functions, which cannot cross the network;
- schema bytes on every join.

## 8. Types users can name

All exported from the main module:
- **Codecs and inference:** `Codec<T>`, `Infer<Schema>`.
- **Views:** `ServerEvent<T>`, `ClientEvent<T>` and their timed forms, `ServerRequest<Q, R>`,
  `ClientRequest<Q, R>`, `ServerCollection<R, K>`, `ClientCollection<R>`.
- **Values:** `Result<T>`, `Recipients`, `Group`, `Connection`, `Signal<…>`.
- **Observability:** the observed event union.

## 9. How the types work

| Fact (luau-lsp 1.70.1, Luau 0.740) | Design consequence |
|---|---|
| A type function turns a plain table of codecs into a record type, nested tables included | Records need no wrapper |
| A type function can map each definition in a namespace to a per-side type | Server and client views, with the other side's calls as type errors |
| Literal arguments widen (`oneOf("a", "b")` is `string`); table keys keep their literal names | Closed sets use Luau's set literal |
| A generic method on codec types makes type functions fail on every codec | Codec methods are non-generic; `Lync.convert` is a function |
| An alias cannot refer to itself with different parameters | Each modifier and each event state returns its own type |
| A type function can raise an error that appears at the call site | Collection markers in an event or request schema are rejected with a message |
| A function passed as an argument has its parameters inferred; a function assigned to a property does not (they become generics) | Handlers are set with `handle(function …)`, not by assignment |
| 629 Enum overloads exceed Luau's complexity limit; a generated table of 629 Enum codecs checks in about a second | `Lync.enum` and `Lync.instance` are generated tables |
| A callable value intersected with a table hides missing-key errors | The generated tables are plain tables |
| Writes through a `setmetatable<…>` indexer are not checked; a plain table type with an indexer is, and a `read` indexer rejects writes | Collections are typed as plain tables; the client's has a `read` indexer |
| One type function can call another | Records, messages and unions share one inference |

**Deliberate mistakes in the prototype**, each caught:
1. a wrong payload type;
2. a reply of the wrong type;
3. a key that is not a partition key;
4. a client firing with recipients;
5. an unknown flag;
6. an undeclared name;
7. a client writing a collection;
8. an Enum typo;
9. `latest` in an event schema;
10. `latest` after `unreliable`;
11. a client calling `limit`, which only the server view offers.

## 10. roblox-ts

- **Missing syntax.** TypeScript has no `#`, `for … in` or custom iteration before roblox-ts 3.1. The
  npm entry adds `size()` and `entries()` to collections and groups. Luau users never load it.
- **Mappings:**
  - views map to TypeScript generics over the namespace;
  - set literals map to `keyof` object literals;
  - records and partition markers map to mapped types;
  - `Lync.instance.Player` maps to roblox-ts's `Instances` map;
  - results map to discriminated unions.
- **To check before writing the declarations:** how roblox-ts compiles numeric indexing on a
  non-array object (`collection[id] = record`).

## 11. Changes from v4

| v4 | v5 |
|---|---|
| `struct({ … })` | A plain table |
| `int`, `quant`, `f64`, `vlq`, `vli`, `str`, `vec3`, `cframe`, `color3`, `inst` | `integer`, `number`, `string`, `vector3`, `cframe`, `color3`, `instance`: each a value, refined by a call |
| `inst("Player")`, typed `Instance?` | `Lync.instance.Player`, typed `Player?` |
| No whole-Enum codec | `Lync.enum.Material` |
| `enum({ "a", "b" })` | `oneOf({ a = true, b = true })`, exactly typed |
| `tagged("kind", { … })` | `union({ … })` with plain-table variants |
| `optional(c)` | `c:optional()` |
| `:as(lift, lower)` | `Lync.convert(wire, { decode, encode })` |
| `packet`, `query`, `replicate` | `event`, `request`, `collection` |
| `fireServer`, `fireClient`, `onServer`, `onClient` | `fire` and `connect`, one name each, from the side's view |
| `request` in two forms, a responder registered with `onServer` before start | `invoke` returning `Result`, `handle` at any time |
| Wrong-side calls refused at runtime | Absent from the other side's view: a type error |
| `:validate(fn)` in the shared schema, its code replicated to every client | `validate` and `limit` on the server view; policy never leaves the server |
| `:unreliable()` with `:newest()`, refused at start | Impossible to combine |
| `sent: number?` | `sentAt: number`, only on timestamped events |
| `set:add`, `set:remove`, `set:get` | `collection[id] = record`, `= nil`, `collection[id]`; read-only on clients |
| `onAdded(fn)`, `onRemoved(id, cause)` | `added:connect(fn)`, `removed:connect(function(id, previous) end)` |
| `:keyBy("team")`, `audience(key, to)` | `:partition()`, `show(key, recipients)`, `hide(key)` |
| `define("name", { … })` | `namespace({ … })` |
| `start`, `flush` every frame, `close` | Nothing |
| `onLog(kind, message, data)` | `observe(event)` |
