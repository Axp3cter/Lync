type ServerResult2<R> =
	| { readonly ok: true; readonly value: R; readonly roundTripSeconds: number; readonly sendPingSeconds: number; readonly answerPingSeconds: number; readonly minPingSeconds: number }
	| { readonly ok: false; readonly error: "rejected" | "unanswered"; readonly roundTripSeconds: number; readonly sendPingSeconds: number; readonly answerPingSeconds: number; readonly minPingSeconds: number }
	| { readonly ok: false; readonly error: "timedOut" | "playerLeft" | "serverClosing"; readonly roundTripSeconds?: undefined; readonly sendPingSeconds?: number; readonly answerPingSeconds?: undefined; readonly minPingSeconds?: undefined };
declare const q: ServerResult2<number>;
if (q.ok) {
	const v: number = q.value;
} else if (q.error === "rejected" || q.error === "unanswered") {
	const t: number = q.roundTripSeconds;
} else {
	if (q.sendPingSeconds !== undefined) { const p: number = q.sendPingSeconds + 1; }
	const bad: number = q.roundTripSeconds; // expected error
}
