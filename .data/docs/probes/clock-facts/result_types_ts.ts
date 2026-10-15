// U4: the roblox-ts declaration a generated .d.ts would carry for a server-side ask result, and game-code reads.
// Checked with: tsc --noEmit --strict result_types_ts.ts
interface ServerTiming {
	/** s: os.clock() at the answer's decode minus os.clock() at the flush that sent the ask; -1 if none */
	readonly roundTrip: number;
	/** s: Player.GetNetworkPing() at that flush; -1 if the ask was never sent */
	readonly pingAtSend: number;
	/** s: Player.GetNetworkPing() at the answer's decode; -1 if no answer arrived */
	readonly pingAtAnswer: number;
	/** s: min(GetNetworkPing samples, ack round trips) over the last 10 s at the answer's decode; -1 if no answer */
	readonly minPing: number;
}
type ServerResult<R, E extends string> =
	| (ServerTiming & { readonly ok: true; readonly value: R })
	| (ServerTiming & { readonly ok: false; readonly error: E });
type AskError = "timeout" | "rejected" | "unanswered" | "left" | "shutdown";

declare const r: ServerResult<number, AskError>;
const slack: number = r.roundTrip - r.minPing;
if (r.ok) {
	const v: number = r.value;
	print(v, slack);
} else {
	const e: AskError = r.error;
	if (r.error === "timeout") {
		const none: number = r.pingAtAnswer;
		print(none);
	}
	print(e);
}
function processing(t: ServerTiming): number {
	return t.roundTrip - t.minPing;
}
print(processing(r));
declare function print(...args: unknown[]): void;
