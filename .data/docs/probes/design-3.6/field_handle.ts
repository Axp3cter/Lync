type Vector3 = { readonly X: number; readonly Y: number; readonly Z: number };
type Player = { readonly UserId: number };
interface Shot { landing: Vector3; flight: number; target: number }
interface Collection<K> { get(this: void, key: K): object | undefined }
interface Field<D, T> {
	derive(this: void, options: { fn: (player: Player, data: D) => T | undefined; tolerance: number; policy: "drop" | "deliver" }): void;
	refers(this: void, collection: Collection<T>): void;
}
interface View {
	field(this: void, path: "landing"): Field<Shot, Vector3>;
	field(this: void, path: "flight"): Field<Shot, number>;
	field(this: void, path: "target"): Field<Shot, number>;
}
declare const v: View;
declare const fighters: Collection<number>;
declare const names: Collection<string>;
v.field("landing").derive({ fn: (p, s) => s.landing, tolerance: 0.25, policy: "deliver" });
v.field("flight").derive({ fn: (p, s) => s.flight, tolerance: 0, policy: "drop" });
v.field("target").refers(fighters);
// expected errors
v.field("flight").derive({ fn: (p, s) => s.landing, tolerance: 0, policy: "drop" });
v.field("flight").derive({ fn: (p, s) => s.flight, tolerance: 0, policy: "dorp" });
v.field("target").refers(names);
v.field("nope");
