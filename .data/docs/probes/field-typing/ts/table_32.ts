// roblox-ts runtime path for form (b), 32 paths: View<S>.fields is a mapped type over the schema's paths.
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
export interface View<S> { readonly fields: { readonly [P in Paths<S>]: Handle<At<S, P>> } }

type Shot = { f1: Vector3; f2: string; f3: number; f4: Vector3; f5: string; f6: number; f7: Vector3; f8: string; f9: number; f10: Vector3; f11: string; f12: number; f13: Vector3; f14: string; f15: number; f16: Vector3; f17: string; f18: number; f19: Vector3; f20: string; f21: number; f22: Vector3; f23: string; f24: number; f25: Vector3; f26: string; f27: number; f28: Vector3; f29: string; hit?: { part: number; at: Vector3 } };
declare const v: View<Shot>;
declare const p: Vector3;
const h2 = v.fields.f2; // Handle<string>
v.fields.f3.derive({ fn: () => 1, policy: "drop" });
v.fields["hit.at"].derive({ fn: () => p, policy: "deliver" });
v.fields.f29.derive({ fn: () => undefined, policy: "drop" });
const exact: Handle<string> = v.fields.f2;
// EXPECT an error on each line below
const wrongType: Handle<number> = v.fields.f2;
v.fields["hit.part"].derive({ fn: () => p, policy: "drop" });
const wrongPath = v.fields.nope;
v.fields.f3.derive({ fn: () => 1, policy: "dorp" });
export { h2, exact, wrongType, wrongPath };
