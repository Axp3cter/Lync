// roblox-ts runtime path, 128 paths: View<S> derives field(path) from the schema type S.
declare interface Vector3 { readonly X: number; readonly Y: number; readonly Z: number }
export interface Handle<T> { derive(options: { fn: () => T | undefined; policy: "drop" | "deliver" }): void }
type Leaf = Vector3 | number | string | boolean;
// every path through records and optionals, dotted
export type Paths<S, Pre extends string = ""> = {
	[K in keyof S & string]-?: `${Pre}${K}` | (NonNullable<S[K]> extends Leaf ? never : Paths<NonNullable<S[K]>, `${Pre}${K}.`>);
}[keyof S & string];
export type At<S, P extends string> = P extends `${infer H}.${infer R}`
	? H extends keyof S ? At<NonNullable<S[H]>, R> : never
	: P extends keyof S ? NonNullable<S[P]> : never;
export interface View<S> { field<P extends Paths<S>>(path: P): Handle<At<S, P>> }

type Shot = { f1: Vector3; f2: string; f3: number; f4: Vector3; f5: string; f6: number; f7: Vector3; f8: string; f9: number; f10: Vector3; f11: string; f12: number; f13: Vector3; f14: string; f15: number; f16: Vector3; f17: string; f18: number; f19: Vector3; f20: string; f21: number; f22: Vector3; f23: string; f24: number; f25: Vector3; f26: string; f27: number; f28: Vector3; f29: string; f30: number; f31: Vector3; f32: string; f33: number; f34: Vector3; f35: string; f36: number; f37: Vector3; f38: string; f39: number; f40: Vector3; f41: string; f42: number; f43: Vector3; f44: string; f45: number; f46: Vector3; f47: string; f48: number; f49: Vector3; f50: string; f51: number; f52: Vector3; f53: string; f54: number; f55: Vector3; f56: string; f57: number; f58: Vector3; f59: string; f60: number; f61: Vector3; f62: string; f63: number; f64: Vector3; f65: string; f66: number; f67: Vector3; f68: string; f69: number; f70: Vector3; f71: string; f72: number; f73: Vector3; f74: string; f75: number; f76: Vector3; f77: string; f78: number; f79: Vector3; f80: string; f81: number; f82: Vector3; f83: string; f84: number; f85: Vector3; f86: string; f87: number; f88: Vector3; f89: string; f90: number; f91: Vector3; f92: string; f93: number; f94: Vector3; f95: string; f96: number; f97: Vector3; f98: string; f99: number; f100: Vector3; f101: string; f102: number; f103: Vector3; f104: string; f105: number; f106: Vector3; f107: string; f108: number; f109: Vector3; f110: string; f111: number; f112: Vector3; f113: string; f114: number; f115: Vector3; f116: string; f117: number; f118: Vector3; f119: string; f120: number; f121: Vector3; f122: string; f123: number; f124: Vector3; f125: string; hit?: { part: number; at: Vector3 } };
declare const v: View<Shot>;
declare const p: Vector3;
const h2 = v.field("f2"); // Handle<string>
v.field("f3").derive({ fn: () => 1, policy: "drop" });
v.field("hit.at").derive({ fn: () => p, policy: "deliver" });
v.field("f125").derive({ fn: () => undefined, policy: "drop" });
const exact: Handle<string> = v.field("f2");
// EXPECT an error on each line below
const wrongType: Handle<number> = v.field("f2");
v.field("hit.part").derive({ fn: () => p, policy: "drop" });
const wrongPath = v.field("nope");
v.field("f3").derive({ fn: () => 1, policy: "dorp" });
export { h2, exact, wrongType, wrongPath };
