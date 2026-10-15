// Typing probe for the roblox-ts declarations of the U11/U14 server API (stand-in Player; no @rbxts/types).
// Lines marked EXPECT must each produce one error under tsc --strict; nothing else may.
// Run: tsc --ignoreConfig --noEmit --strict --target es2020 types.ts
interface Player { readonly UserId: number }
declare const player: Player;

interface ChallengeOptions { within: number; values?: number; attempts?: number }
type ChallengeClosed =
	| { readonly outcome: "answered" | "mismatched"; readonly after: number; readonly attempts: number; readonly minPing: number; readonly definition: string }
	| { readonly outcome: "timeout" | "cancelled" | "left" | "shutdown"; readonly after: undefined; readonly attempts: number; readonly minPing: number; readonly definition: undefined };
interface Challenge {
	readonly token: number;
	readonly deadline: number;
	wait(): ChallengeClosed; // a method: roblox-ts emits c:wait()
	extend(seconds: number): void;
	cancel(): void;
}
declare const Lync: { challenge(this: void, player: Player, options: ChallengeOptions): Challenge };
interface UseServerView { answers(field: "code"): void }
declare const use: UseServerView;

use.answers("code");
use.answers("cdoe"); // EXPECT
const c = Lync.challenge(player, { within: 120, values: 10_000, attempts: 3 });
const closed = c.wait();
if (closed.outcome === "answered") {
	const after: number = closed.after;
	print(after);
} else if (closed.outcome === "timeout") {
	const after: number = closed.after; // EXPECT
	print(after);
}
Lync.challenge(player, { within: 120, attemps: 3 }); // EXPECT (excess property check)

interface Fighter { position: { X: number }; health: number }
interface Perceived { readonly tick: number; readonly exact: boolean }
type Rewound = { ok: true; value: Fighter } | { ok: false; error: "expired" | "notHeld" | "unknownKey" };
interface FightersServerView {
	held(seen: Perceived): ReadonlyArray<number>;
	rewound(seen: Perceived, key: number): Rewound;
	reportInteraction(player: Player, key: number, kind: number): void;
}
declare const fighters: FightersServerView;
declare const seen: Perceived;
for (const key of fighters.held(seen)) {
	const r = fighters.rewound(seen, key);
	if (r.ok) {
		fighters.reportInteraction(player, key, 1);
	} else {
		const e: "expired" | "notHeld" | "unknownKey" = r.error;
		print(e);
	}
}
fighters.reportInteraction(player, "k", 1); // EXPECT
declare function print(...args: unknown[]): void;
