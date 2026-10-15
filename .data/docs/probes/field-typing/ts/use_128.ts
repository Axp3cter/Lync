import type { View, Handle } from "./view_128";
declare const v: View;
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
