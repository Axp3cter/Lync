// .d.ts of the chosen form, 32 paths: one field(path) overload per path.
declare global { interface Vector3 { readonly X: number; readonly Y: number; readonly Z: number } }
export interface Handle<T> { derive(options: { fn: () => T | undefined; policy: "drop" | "deliver" }): void }
export interface View {
	field(path: "f1"): Handle<Vector3>;
	field(path: "f2"): Handle<string>;
	field(path: "f3"): Handle<number>;
	field(path: "f4"): Handle<Vector3>;
	field(path: "f5"): Handle<string>;
	field(path: "f6"): Handle<number>;
	field(path: "f7"): Handle<Vector3>;
	field(path: "f8"): Handle<string>;
	field(path: "f9"): Handle<number>;
	field(path: "f10"): Handle<Vector3>;
	field(path: "f11"): Handle<string>;
	field(path: "f12"): Handle<number>;
	field(path: "f13"): Handle<Vector3>;
	field(path: "f14"): Handle<string>;
	field(path: "f15"): Handle<number>;
	field(path: "f16"): Handle<Vector3>;
	field(path: "f17"): Handle<string>;
	field(path: "f18"): Handle<number>;
	field(path: "f19"): Handle<Vector3>;
	field(path: "f20"): Handle<string>;
	field(path: "f21"): Handle<number>;
	field(path: "f22"): Handle<Vector3>;
	field(path: "f23"): Handle<string>;
	field(path: "f24"): Handle<number>;
	field(path: "f25"): Handle<Vector3>;
	field(path: "f26"): Handle<string>;
	field(path: "f27"): Handle<number>;
	field(path: "f28"): Handle<Vector3>;
	field(path: "f29"): Handle<string>;
	field(path: "hit"): Handle<{ part: number; at: Vector3 }>;
	field(path: "hit.part"): Handle<number>;
	field(path: "hit.at"): Handle<Vector3>;
}
