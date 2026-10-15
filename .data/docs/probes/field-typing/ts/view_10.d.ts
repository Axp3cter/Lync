// .d.ts of the chosen form, 10 paths: one field(path) overload per path.
declare interface Vector3 { readonly X: number; readonly Y: number; readonly Z: number }
export interface Handle<T> { derive(options: { fn: () => T | undefined; policy: "drop" | "deliver" }): void }
export interface View {
	field(path: "f1"): Handle<Vector3>;
	field(path: "f2"): Handle<string>;
	field(path: "f3"): Handle<number>;
	field(path: "f4"): Handle<Vector3>;
	field(path: "f5"): Handle<string>;
	field(path: "f6"): Handle<number>;
	field(path: "f7"): Handle<Vector3>;
	field(path: "hit"): Handle<{ part: number; at: Vector3 }>;
	field(path: "hit.part"): Handle<number>;
	field(path: "hit.at"): Handle<Vector3>;
}
