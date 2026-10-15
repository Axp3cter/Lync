import Lync from "@axpecter/lync";

// Each line must fail to compile. @ts-expect-error fails the build if one starts passing. This
// file is read by tsc alone, since the roblox-ts compiler refuses a comment directive anywhere.

const Codec = Lync.struct({
    name: Lync.str(1, 20),
    score: Lync.int(0, 1_000_000),
    team: Lync.enum(["red", "blue"] as const),
});

const Net = Lync.define("rejections", {
    Fighters: Lync.replicate(Codec).keyBy("team"),
    Strike: Lync.packet(Lync.vec3()).unreliable(),
});

const Squad = Lync.group();
const Plain = Lync.replicate(Codec);
const Keyed = Lync.replicate(Codec).keyBy("team");

// @ts-expect-error audience on an unkeyed set
Plain.audience("red", Lync.all);
// @ts-expect-error a key outside the field's type
Keyed.audience(1, Lync.all);
// @ts-expect-error the clear sentinel on a required field
Keyed.update(1, { score: Lync.none });
// @ts-expect-error a field the record does not declare that type for
Keyed.update(1, { score: "high" });
// @ts-expect-error keyBy an absent field
Lync.replicate(Codec).keyBy("nope");
// @ts-expect-error a payload the packet codec rejects
Net.Strike.fireServer(1);
// @ts-expect-error a flush budget that is not a number
Lync.flush("arena", "big");
// @ts-expect-error a set walks through entries(), not on its own
for (const [id] of Net.Fighters) { print(id); }
// @ts-expect-error a group walks through players(), not on its own
for (const player of Squad) { print(player); }
