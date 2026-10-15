type ServerResult2<R> =
	| { readonly ok: true; readonly value: R; readonly roundTrip: number; readonly pingAtSend: number; readonly pingAtAnswer: number; readonly minPing: number }
	| { readonly ok: false; readonly error: "rejected" | "unanswered"; readonly roundTrip: number; readonly pingAtSend: number; readonly pingAtAnswer: number; readonly minPing: number }
	| { readonly ok: false; readonly error: "timeout" | "left" | "shutdown"; readonly roundTrip?: undefined; readonly pingAtSend?: number; readonly pingAtAnswer?: undefined; readonly minPing?: undefined };
declare const q: ServerResult2<number>;
if (q.ok) {
	const v: number = q.value;
} else if (q.error === "rejected" || q.error === "unanswered") {
	const t: number = q.roundTrip;
} else {
	if (q.pingAtSend !== undefined) { const p: number = q.pingAtSend + 1; }
	const bad: number = q.roundTrip; // expected error
}
