# Lync v5 spec: API

The public surface of v5: what each member does, accepts and refuses. How a value is laid out on the wire
is in [wire.md](wire.md), what happens when something fails is in [failures.md](failures.md), and the
numbers are in [limits.md](limits.md). The id scheme and the claim grammar are in [README.md](README.md).

A claim that says a mistake "must be a type error" is proved by a file in `test/types/`. A claim that says it
"must throw" is proved by a test that catches the throw, and its message follows
[failures.md](failures.md) §8. A **view** is what `Lync.server` or `Lync.client` returns, an **instance** is
one runtime with its own state (A-15), and **admitted** means the namespace has been accepted for that
connection (W-84).

## 1. Namespaces and views

| ID | Claim |
|---|---|
| A-1 | `Lync.namespace(definitions)` must return the table it was given, frozen. |
| A-2 | A namespace's name must be the full name of the module that calls `Lync.namespace`, so that the server and the client derive the same name. |
| A-3 | `Lync.namespace` must throw, naming the key, when a value is not an event, request or collection declaration. |
| A-164 | `Lync.namespace` must throw for a table with no definitions. |
| A-4 | `Lync.server(namespace)` and `Lync.client(namespace)` must return that side's view, with one member for each key of the namespace. |
| A-5 | Taking the view of the side the code is not running on must throw, unless a transport is supplied (A-14), the side being decided by A-148. |
| A-148 | Without a transport, the side must be the server when `RunService:IsServer()` is true and the client otherwise. |
| A-6 | Taking the view of one namespace on one side more than once in one instance must return the same view. |
| A-7 | Lync must start on the first use of a view, with no start call. |
| A-142 | Taking a view and connecting a listener must never yield. |
| A-8 | A client's fires and invokes made before its namespace is admitted must be held, within L-27, and sent in order after the accept. |
| A-159 | A client invoke whose timeout elapses before its namespace is admitted must be discarded unsent and must resolve as `Timeout`. |
| A-9 | A block addressed to a player who is not yet admitted for the namespace must wait, within L-27, until the player is admitted, and must be discarded if the player leaves first. |
| A-160 | A connection must be the link between one client and the server, identified by its player on the server and unique on a client, and its namespace slots, pending requests, sequences, rate buckets and held blocks must belong to it alone. |
| A-161 | When a player leaves, Lync must release everything it holds for that player's connection, and a player who rejoins must start with fresh state. |
| A-162 | Blocks that the server holds for a player whose HELLO for a namespace was refused must be discarded. |

## 2. Seams

Each seam has product value (a custom transport, a controllable clock, a custom player source) and a
default that is the engine's own.

| ID | Claim |
|---|---|
| A-10 | `Lync.server` and `Lync.client` must accept a second argument, a record with the optional fields `transport`, `clock` and `roster`, and a field left out must use the engine's own. |
| A-11 | A transport must have the lanes `reliable`, `unreliable` and `handshake`, each with a plain function `send(recipient, frame, ...)` and a `received` signal that fires `(sender, frame, ...)`. |
| A-143 | A transport's `recipient` and `sender` must be a player on a server and nil on a client. |
| A-144 | A transport's `handshake` lane must carry no instances. |
| A-12 | A clock must have the plain functions `now()`, the server-time clock in seconds, `delay(seconds, callback, ...)`, which returns a handle, and `cancel(handle)`, and a `frame` signal that fires the elapsed seconds, and Lync must take every time reading, timer and flush tick from it. |
| A-147 | Lync must cancel a request's timeout timer through the clock when the request resolves. |
| A-13 | A roster must have the plain functions `players()` and `isPlayer(value)` and the signals `added` and `removing`, each firing a player, and Lync must recognise a player only through `isPlayer` and read only its `Name` and `UserId`. |
| A-191 | A signal in a seam must have the shape of a Roblox signal: `:Connect(handler)` and `:Once(handler)` must each return a connection with `:Disconnect()`, so that the engine's own signals can be passed as they are. |
| A-192 | Lync must call nothing on a seam signal but `:Connect`, `:Once` and `:Disconnect`. |
| A-193 | Every function that a seam offers must be called with a dot, as in `now()` and `send(...)`, and never as a method. |
| A-14 | With a transport supplied, `Lync.server` and `Lync.client` must not check which side the DataModel is, and the view asked for must decide the side. |
| A-15 | Each distinct seams record must make an independent instance that shares no state with another. |
| A-145 | Views taken with the same seams record must share one instance. |
| A-146 | Views taken without a seams record must share the copy's default instance. |
| A-16 | `Lync.observe`, `Lync.metrics`, `Lync.configure`, `Lync.flush` and `Lync.stop` must act on every instance of the copy, and a setting made by `Lync.configure` must also apply to instances made later. |

## 3. Leaf codecs

| ID | Claim |
|---|---|
| A-17 | Every leaf codec must work as a value without being called, and calling it must return a new refined codec and leave the original unchanged. |
| A-18 | Every name on `Lync` must be lowerCamel, and names from Roblox must keep their spelling as keys of `Lync.instance` and `Lync.enum`. |
| A-19 | `Lync.boolean` must carry `boolean`. |
| A-20 | `Lync.integer` must carry whole numbers, unbounded when bare and from `min` to `max` when called as `Lync.integer(min, max)`. |
| A-21 | `Lync.integer(min, max)` must throw unless `min` and `max` are whole numbers within L-13 with `min` not above `max`. |
| A-22 | `Lync.number` must accept no argument (exact), one argument `step` or three arguments `min, max, step`, where `step` is positive and finite, `min` and `max` are finite and `min` is not above `max`, and must throw for any other call. |
| A-23 | `Lync.string` and `Lync.buffer` must accept no argument or one `maxBytes`, a non-negative whole number, and must throw for any other call. |
| A-24 | `Lync.vector2` and `Lync.vector3` must accept no argument or three arguments `min, max, step` valid as for `Lync.number`, and must throw for any other call. |
| A-25 | `Lync.cframe` must accept no argument or `(position, rotation)`, where `position` is a `vector3` codec and `rotation` is a `rotation` codec, and must throw for any other call. |
| A-26 | `Lync.color3` must accept no argument or one `step` that is positive and at most 1, and must throw for any other call. |
| A-27 | `Lync.angle` must accept no argument or one `step`, in degrees, that is positive and at most 360, and must throw for any other call. |
| A-154 | `Lync.direction` and `Lync.rotation` must accept no argument or one `step`, in degrees, that is positive and finite, and must throw for any other call. |
| A-28 | A bare `angle`, `direction` or `rotation` must not quantize: a bare `angle` must come back as `v mod 360` exactly, a bare `direction` and a bare `rotation` that is not axis-aligned within 0.0001 degrees, and an axis-aligned `rotation` exactly. |
| A-29 | `Lync.direction` must carry a `Vector3` that is normalized when sent. |
| A-30 | `Lync.instance` must carry `Instance?`. |
| A-31 | `Lync.instance.<Class>` must carry `<Class>?` and must refuse an instance that is not `IsA` that class. |
| A-32 | `Lync.enum.<Name>` must carry `Enum.<Name>`. |
| A-33 | An instance that the receiver cannot see must arrive as nil, so every instance codec must carry an optional type. |
| A-34 | `Lync.instance` must have a key for every class, and `Lync.enum` a key for every Enum, of the Roblox API types pinned in `definitions/Roblox.pin.json`. |
| A-35 | Indexing `Lync.instance` or `Lync.enum` with a name that has no key (A-34) must throw. |
| A-36 | `Lync.enum` must carry, for each Enum, the ascending values of its items, read from a Roblox API dump that is pinned separately from the types of A-34, and an item whose value is not carried must be refused at encode (W-36, W-123). |
| A-166 | Generation of `Lync.enum` must fail when an Enum of the pinned types is absent from the pinned API dump. |

## 4. Composite codecs and modifiers

| ID | Claim |
|---|---|
| A-37 | A plain table of codecs must be a record codec carrying a table with the same keys, and a value with a missing required field or an unknown field must be refused. |
| A-38 | `Lync.array(codec, maxCount?)` must carry a sequence of the codec's type. |
| A-169 | `Lync.array` must throw at declaration when its codec is optional. |
| A-170 | `Lync.array` must refuse a table that is not a sequence. |
| A-171 | `Lync.array` must refuse a table with more than `maxCount` elements when `maxCount` is given. |
| A-39 | `Lync.map(key, value, maxCount?)` must carry a table from the key codec's type to the value codec's type. |
| A-172 | `Lync.map` must throw at declaration unless its key codec is `integer`, `string`, `enum`, `oneOf` or an unquantized `number`. |
| A-173 | `Lync.map` must throw at declaration when its value codec is optional. |
| A-174 | `Lync.map` must refuse a table with more than `maxCount` entries when `maxCount` is given. |
| A-40 | `Lync.oneOf(names)` must carry the string keys of `names`. |
| A-175 | `Lync.oneOf` must throw at declaration unless `names` is a table with at least one key whose values are all `true`. |
| A-176 | `Lync.oneOf` must refuse a string that is not a key of `names`. |
| A-41 | `Lync.flags(names)` must carry a record with a boolean for each key of `names`. |
| A-177 | `Lync.flags` must throw at declaration unless `names` is a table with at least one key whose values are all `true`. |
| A-178 | `Lync.flags` must refuse a value with a missing or an unknown flag. |
| A-42 | `Lync.union(variants)` must carry each variant as its record plus `kind` equal to the variant's name. |
| A-179 | `Lync.union` must throw at declaration when it has no variant. |
| A-180 | `Lync.union` must throw at declaration when a variant has a field named `kind`. |
| A-181 | `Lync.union` must refuse a value whose `kind` names no variant. |
| A-43 | `Lync.convert(wire, { decode, encode })` must send `encode(value)` through the wire codec, deliver `decode(wireValue)`, and carry the type that `decode` returns. |
| A-44 | `codec:optional()` must carry `T?` and accept nil. |
| A-45 | `codec:latest(rate?)` must mark a collection field as sent latest value only, and `rate`, when given, must be positive and finite. |
| A-163 | A collection `latest` field's `rate` must cap its LATEST sends to `rate` a second per recipient. |
| A-46 | `codec:partition()` must mark the field that decides who sees each record, and a collection with more than one partition field must throw at declaration. |
| A-47 | A partition field must be a `boolean`, `integer`, `string`, `oneOf` or `enum` codec, bare or refined, and any other codec for a partition field must throw at declaration. |
| A-48 | A `latest` or `partition` marker anywhere but directly on a field of a collection's schema must throw at declaration. |
| A-49 | `partition` after `optional`, any modifier after `latest` or `partition`, and `optional` after `optional` must be type errors. |
| A-50 | A value must be checked against its codec at the call that carries it, and a refused value must throw at that call (F-7, F-12). |

## 5. Events

| ID | Claim |
|---|---|
| A-51 | `Lync.event(schema?)` must declare an event that is reliable and ordered, and without a schema it must carry no payload. |
| A-52 | Reliable events must reach each recipient in the order they were fired, across all definitions and namespaces, together with requests, responses and collection changes. |
| A-53 | `:unreliable()` must make an event lossy and unordered, and every fire must be sent. |
| A-54 | `:latest(rate?)` must make an event lossy and send only the newest value per recipient, at most `rate` times a second per recipient when `rate` is given, and `rate` must be positive and finite. |
| A-55 | A latest value held back by `rate` must be replaced by a newer fire and sent when it is due. |
| A-56 | `:unreliable()` and `:latest()` used together, in either order, must be a type error. |
| A-149 | `:unreliable()` and `:latest()` used together, in either order, must throw at declaration. |
| A-57 | `:timestamped()` must add a final listener parameter `sentAt: number`, seconds on the server-time clock at 1 ms resolution. |
| A-58 | The combinations of `:unreliable()` or `:latest()` with `:timestamped()` must type exactly, `sentAt` being in a listener's type if and only if the event is timestamped. |
| A-59 | A server must fire with `event:fire(recipients, value)` and a client with `event:fire(value)`. |
| A-60 | A server listener must receive `(value, player, sentAt)` and a client listener `(value, sentAt)`, with `sentAt` only on a timestamped event. |
| A-61 | Listeners must run in the order they were connected, each in its own thread, so that a listener that yields does not delay another. |
| A-62 | `connect` must return a Connection. |
| A-182 | After a Connection's `disconnect`, its listener must not be called. |
| A-183 | A second `disconnect` of a Connection must do nothing. |
| A-63 | An event that arrives with no connected listener must be discarded without output. |
| A-64 | `validate(check)` on the server view must set the event's one validator, replacing an earlier one. |
| A-65 | A validator must receive `(value, player)` and return nil to accept or a string to refuse, and a refused value must be dropped, counted and shown to no listener. |
| A-66 | `limit(rate, burst?)` on the server view must set the one limit, replacing an earlier one, where `rate` is tokens per second, `burst` is the capacity in tokens and defaults to `rate`, and both must be positive and finite. |
| A-67 | A limit must keep one bucket per player and definition that starts full and refills continuously at `rate` tokens per second on the clock, never holding more than its capacity. |
| A-140 | Each arrival must cost its bucket one token, and an arrival that finds less than one token must be dropped, counted as `RateLimited` and cost nothing. |
| A-141 | A bucket's capacity must be the larger of `burst` and 1, so that a message can always pass. |
| A-68 | The client view must not offer `validate` or `limit`, on events and on requests, and calling either must be a type error. |
| A-69 | A collection marker in an event or request schema must be a type error with a message. |
| A-167 | A collection marker in an event or request schema must throw at declaration. |

## 6. Requests

| ID | Claim |
|---|---|
| A-70 | `Lync.request(requestSchema, replySchema)` must declare a request whose `:timeout(seconds)` sets its timeout, 10 seconds by default. |
| A-71 | `:timeout(seconds)` must throw unless `seconds` is positive and finite. |
| A-72 | `invoke` must yield until the request has a result and return it as a `Result` (F-80). |
| A-73 | A server must invoke a request with `request:invoke(player, value)` for exactly one player. |
| A-184 | A server invoke whose recipient is not a single player must throw. |
| A-185 | A client must invoke a request with `request:invoke(value)`. |
| A-74 | `handle(handler)` must set the request's one handler on that side, replacing an earlier one. |
| A-75 | A handler must receive `(value, player)` on the server or `(value)` on the client, and what it returns must be the reply. |
| A-76 | A request that arrives before its handler is set must wait for it for the request's timeout, counted from arrival, and must be discarded when that wait ends. |
| A-77 | A request with no reply when its timeout elapses on the asker's clock must resolve as `Timeout`. |
| A-78 | A request whose handler raised, ended without a reply or returned a reply that fails the reply codec must resolve as `Unanswered`. |
| A-79 | A server request whose asked player leaves before replying must resolve as `Left`. |
| A-80 | A request that is pending when Lync stops must resolve as `Shutdown`. |
| A-81 | A request must resolve exactly once, and a response that arrives after it resolved must be dropped as `Stale`. |
| A-82 | A request to a player who is not yet admitted must wait until the player is admitted, its timeout counting from the call, and must be discarded unsent, resolving as `Timeout`, if the timeout elapses first. |
| A-83 | `validate` and `limit` on a request must behave as on an event (A-64 to A-67, A-140, A-141). |

## 7. Collections

| ID | Claim |
|---|---|
| A-84 | A server must insert or replace a record with `collection[id] = record`, which must be checked against the collection's schema, with every required field present and no unknown field. |
| A-186 | Lync must copy a record that is written to a collection, so that a later change to the caller's table leaves it unchanged. |
| A-85 | `collection[id] = nil` must remove the record and must do nothing when there is none. |
| A-86 | `collection:update(id, patch)` must change only the fields in `patch`, and must throw when `id` names no record or `patch` names a field the collection lacks. |
| A-87 | `Lync.none` in a patch must clear an optional field, and must throw for a field that is not optional. |
| A-88 | `collection:clear()` must remove every record. |
| A-89 | `collection:show(key, recipients)` must set who sees the records whose partition field equals `key`, replacing an earlier audience for that key, and `key` must be a value of the partition field's codec. |
| A-90 | `collection:hide(key)` must make nobody see the records of that key. |
| A-91 | `show` and `hide` must throw on a collection with no partition field. |
| A-92 | A collection without a partition field must go to every admitted client. |
| A-93 | A collection with a partition field must send the records of a key that was never shown to nobody. |
| A-94 | An audience given as `Lync.all`, a group or `Lync.except(...)` must follow live membership, and an audience given as a player or a list must be fixed at the call. |
| A-95 | A client that gains sight of a record, by joining, by an audience change or by `show`, must receive it as `added`, and a client that loses sight must receive `removed`. |
| A-96 | `removed` must pass only `(id, previous)`, so that a client cannot tell whether a record was deleted or hidden. |
| A-97 | A write to a client view's collection must be a type error. |
| A-150 | A write to a client view's collection must throw. |
| A-98 | `collection[id]` must return the record or nil, `#collection` the number of records this side holds, and `for id, record in collection` each record this side holds. |
| A-99 | A client's collection must hold exactly the records it can see. |
| A-100 | A record that `collection[id]`, an iteration or a signal gives must be a frozen snapshot, and a later write must give a new snapshot and leave an earlier one unchanged. |
| A-153 | A record's fields must be read-only to the type checker. |
| A-101 | `added(id, record)` must fire when a record appears on this side by insertion, by joining or by becoming visible, `changed(id, record, previous)` when it changes, and `removed(id, previous)` when it is gone. |
| A-102 | `previous` must be the frozen snapshot of the record as it was before the change. |
| A-103 | Collection signals must fire on the server for the server's own writes: an insert fires `added`, a write or update that changes the encoding of a field fires `changed`, and a removal fires `removed`, once for each record that `clear` removes. |
| A-104 | A write that leaves every field with the encoding it already has, quantized values being compared by index, must fire no signal, send nothing and leave the held record unchanged. |
| A-105 | `show` and `hide` must fire no collection signal on the server. |
| A-106 | A client that sees both the old and the new partition of a record whose partition field changes must receive `removed` and then `added`, and a client that sees only one of them must receive only that one. |
| A-107 | A client's record must have its partition field equal to the key of the section that delivered it. |
| A-108 | A `latest` field's value on a client must equal the server's value within the settle delay (L-17) plus one flush after its last change, though intermediate values may be skipped (provisional M-5). |
| A-109 | Writes to a collection must coalesce only while consecutive (W-98): two writes with no other block between them must arrive as one change, and two writes with a block between them as two. |
| A-110 | A client must fire collection signals in the order the blocks were issued. |

## 8. Recipients and groups

| ID | Claim |
|---|---|
| A-111 | A recipient must be a player, a list of players, a group, `Lync.all` or `Lync.except(recipients)`, and anything else must throw. |
| A-112 | In a fire or an invoke, `Lync.all` must mean every player admitted for the namespace when the call is made, and `Lync.except(recipients)` every such player not in `recipients`. |
| A-113 | In a fire or an invoke, recipients must be resolved when the call is made, and a player named more than once must receive one copy. |
| A-114 | `Lync.group(seams?)` must return a group with `add`, `remove`, `has`, `#group` and `for player in group`. |
| A-187 | A group must use the roster of its `seams` (A-13) to recognise players. |
| A-188 | A group's `add` and `remove` must be idempotent. |
| A-189 | A group's `add` of a value that is not a player must throw. |
| A-115 | A player whom the group's roster reports as removing must be removed from the group automatically. |

## 9. Control and observation

| ID | Claim |
|---|---|
| A-116 | The Luau entry's `Lync` table must have exactly the members `boolean`, `integer`, `number`, `string`, `buffer`, `vector2`, `vector3`, `cframe`, `color3`, `angle`, `direction`, `rotation`, `instance`, `enum`, `array`, `map`, `oneOf`, `flags`, `union`, `convert`, `event`, `request`, `collection`, `namespace`, `server`, `client`, `group`, `all`, `except`, `none`, `observe`, `metrics`, `configure`, `flush`, `stop` and `check`. |
| A-117 | `Lync.configure(settings)` must accept `flush` (`Automatic` or `Manual`), `interval`, `console`, `profile` and `columns`, change only the settings given, and throw for any other key or an invalid value. |
| A-190 | With `columns = false` the encoder must emit PACKED for every column, and by default `columns` must be true. |
| A-118 | By default Lync must flush automatically on every frame of the clock, which is an `interval` of 0. |
| A-119 | With an `interval` above 0, automatic flushing must run on the first frame at which at least `interval` seconds have passed since the previous flush, and `interval` must be a finite number not below 0. |
| A-120 | With `flush = "Manual"` Lync must send nothing until `Lync.flush` is called. |
| A-121 | `Lync.flush(namespace?, budget?)` must send the queued blocks now, for `namespace` when given and for every namespace otherwise. |
| A-122 | A flush with a `budget`, a positive whole number of bytes, must send at most `budget` bytes of frame per recipient and lane, as whole blocks in queue order and at least one block when any is queued, and the rest must stay queued for the next flush (provisional M-9). |
| A-123 | `Lync.stop()` must flush the queued blocks of every existing instance once and then end each of them. |
| A-151 | Lync must call `Lync.stop()` when the server shuts down. |
| A-152 | A view taken when no instance exists, such as after `Lync.stop`, must start a fresh instance as on first use. |
| A-124 | `Lync.stop()` called when no instance exists must do nothing. |
| A-125 | `Lync.check(schema, value)` must return `{ ok = true, value = value }` when the value fits the schema and `{ ok = false, reason = text }` when it does not, and must send nothing. |
| A-158 | `Result` must take the reason type as a second parameter that defaults to `Timeout`, `Unanswered`, `Left` and `Shutdown`, and `Lync.check` must return a `Result` whose reason is a string. |
| A-126 | `definition:trace()` must start tracing the definition, and `definition:trace(false)` must stop it. |

## 10. Types users can name

| ID | Claim |
|---|---|
| A-127 | Every argument of `fire`, `invoke` and a collection write must be typed from the schema with no annotation in user code. |
| A-155 | Every listener parameter must be typed from the schema with no annotation in user code. |
| A-156 | Every handler parameter must be typed from the schema with no annotation in user code. |
| A-157 | Every result, including the value of an invoke's `Result` and the records and signals of a collection, must be typed from the schema with no annotation in user code. |
| A-128 | A value of the wrong type for a schema must be a type error in `fire`, `invoke` and collection writes. |
| A-129 | A handler that returns a value of the wrong type for the reply schema must be a type error. |
| A-130 | A key that is not a value of the partition field's codec must be a type error in `show` and `hide`. |
| A-131 | A client calling `fire` with recipients must be a type error. |
| A-132 | A flag that `flags` does not declare must be a type error. |
| A-133 | A string that `oneOf` does not declare must be a type error. |
| A-134 | A name that is not in `Lync.enum` must be a type error. |
| A-135 | The main module must export the types `Codec`, `Infer`, `ServerEvent`, `ClientEvent`, `TimedServerEvent`, `TimedClientEvent`, `ServerRequest`, `ClientRequest`, `ServerCollection`, `ClientCollection`, `Result`, `Recipients`, `Group`, `Connection`, `Signal` and `ObservedEvent`. |
| A-136 | In the Luau entry, a server event view must offer exactly `fire`, `connect`, `validate`, `limit` and `trace`, and a client event view exactly `fire`, `connect` and `trace`. |
| A-137 | In the Luau entry, a server request view must offer exactly `invoke`, `handle`, `validate`, `limit` and `trace`, and a client request view exactly `invoke`, `handle` and `trace`. |
| A-138 | In the Luau entry, a server collection view must offer exactly `update`, `clear`, `show`, `hide`, `added`, `changed`, `removed` and `trace` besides its indexer, and a client collection view exactly `added`, `changed`, `removed` and `trace`. |
| A-139 | The npm entry must add `size()` and `entries()` to collections and groups. |
| A-168 | The Luau surface must not have `size()` or `entries()` on collections and groups. |
| A-165 | Withdrawn. Seven claims replace it, A-194 to A-200, one for each mistake. |
| A-194 | In a TypeScript project, `index.d.ts` must reject a value of the wrong type for a schema in `fire`, `invoke` and collection writes as a type error. |
| A-195 | In a TypeScript project, `index.d.ts` must reject a handler that returns a value of the wrong type for the reply schema as a type error. |
| A-196 | In a TypeScript project, `index.d.ts` must reject a key that is not a value of the partition field's codec in `show` and `hide` as a type error. |
| A-197 | In a TypeScript project, `index.d.ts` must reject a client calling `fire` with recipients as a type error. |
| A-198 | In a TypeScript project, `index.d.ts` must reject a flag that `flags` does not declare as a type error. |
| A-199 | In a TypeScript project, `index.d.ts` must reject a string that `oneOf` does not declare as a type error. |
| A-200 | In a TypeScript project, `index.d.ts` must reject a name that is not in `Lync.enum` as a type error. |
| A-201 | The npm entry's `size()` on a collection or a group must return the number that `#` gives on the object it wraps. |
| A-202 | The npm entry's `entries()` on a collection must give a generic `for` the ids and records that `for in` gives on the collection it wraps, and on a group the players. |
| A-203 | The npm entry's `server` and `client` must return the same view for the same arguments for which `Lync.server` and `Lync.client` return the same view, and that view must hold the same collection and group on every read. |
| A-204 | A group made by the npm entry's `group` must be accepted wherever a group is a recipient: in a server event's `fire`, in a collection's `show` and in `except`. |
| A-205 | The npm entry's collections must delegate every member of A-138, and its server events every member of A-136, to the objects they wrap, with the same results and the same errors. |
| A-206 | The npm entry's views, collections, server events and groups must be frozen tables. |
| A-207 | The npm entry must hand out every other member of `Lync`, and every request, client event, signal and connection, as the same objects the Luau entry gives. |
