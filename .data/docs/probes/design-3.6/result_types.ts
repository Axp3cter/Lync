type ServerResult<R, E extends string> =
	| { readonly ok: true; readonly value: R; readonly roundTrip: number; readonly pingAtSend: number; readonly pingAtAnswer: number; readonly minPing: number }
	| { readonly ok: false; readonly error: E; readonly roundTrip?: number; readonly pingAtSend?: number; readonly pingAtAnswer?: number; readonly minPing?: number };
declare const r: ServerResult<number, "timeout" | "left">;
if (r.ok) {
	const v: number = r.value;
	const t: number = r.roundTrip;
} else {
	const e: "timeout" | "left" = r.error;
	if (r.roundTrip !== undefined) { const t: number = r.roundTrip + 1; }
	const bad: number = r.roundTrip; // expected error: possibly undefined
	r.value; // expected error
}
