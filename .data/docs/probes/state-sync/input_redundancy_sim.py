"""Input-stream redundancy on the unreliable lane: how many past inputs to repeat per packet.

Client sends one packet per tick carrying the newest input plus the previous R-1 inputs (R = 1 means no
redundancy). Optionally (ack mode) it repeats every input since the newest one the server has acked,
capped at CAP, like GGPO's pending-output queue and Overwatch / Q3 (cl_packetdup).
The server consumes input for tick t at t + J (jitter buffer J ticks); an input is MISSED if no packet
carrying it arrived by then. One-way delay 1 tick plus jitter: each packet independently 0..JIT extra ticks.
Bytes: inputs are INPUT_B bytes absolute; repeats are delta-coded against the previous input in the
packet (GGPO style): an unchanged input costs 1 bit, a changed one INPUT_B bytes + 1 bit.
Input changes with probability CHANGE per tick (held buttons and sticks repeat).
"""
import random, statistics

T, INPUT_B, CHANGE, CAP = 20000, 4, 0.3, 32

def loss_proc(kind, p, rng):
    if kind == "bern":
        while True:
            yield rng.random() < p
    bad, r_exit = False, 1 / 3
    r_enter = p * r_exit / (1 - p)
    while True:
        bad = (rng.random() >= r_exit) if bad else (rng.random() < r_enter)
        yield bad

def run(kind, p, R, J, JIT, ack, seed):
    rng = random.Random(seed)
    loss, uploss = loss_proc(kind, p, rng), loss_proc(kind, p, rng)
    changed = [rng.random() < CHANGE for _ in range(T)]
    arrive = [None] * T          # earliest arrival tick per input
    acked = -1                   # newest input index acked to client (ack rides downstream frames)
    ack_q = {}
    bits = 0
    for t in range(T):
        for (at, a) in ack_q.pop(t, []):
            acked = max(acked, a)
        lo = max(0, t - R + 1) if not ack else max(0, acked + 1, t - CAP + 1)
        carried = range(lo, t + 1)
        bits += INPUT_B * 8 + 1 + sum(1 + (INPUT_B * 8 if changed[i] else 0) for i in carried if i != t) + 8
        if not next(loss):
            at = t + 1 + rng.randint(0, JIT)
            for i in carried:
                if arrive[i] is None or at < arrive[i]:
                    arrive[i] = at
            # server acks the newest contiguous input it holds, on its next downstream frame (+1 tick)
            if ack and not next(uploss):
                ack_q.setdefault(at + 1, []).append((at + 1, t))
    missed = sum(1 for t in range(T - 10) if arrive[t] is None or arrive[t] > t + J)
    return missed / (T - 10), bits / 8 / T

if __name__ == "__main__":
    print(__doc__.split("\n")[0])
    print(f"T={T}, input {INPUT_B} B, change {CHANGE}/tick, ack-mode cap {CAP}; miss% / bytes per packet; 4 seeds")
    for kind, p in (("bern", 0.01), ("bern", 0.05), ("ge", 0.05), ("ge", 0.15)):
        for JIT, J in ((0, 1), (1, 2), (2, 3), (0, 3), (0, 5)):
            row = [f"{kind:4s} p={p:<4} jit={JIT} J={J}:"]
            for R, ack in ((1, False), (2, False), (3, False), (4, False), (6, False), (0, True)):
                res = [run(kind, p, R, J, JIT, ack, s) for s in range(4)]
                m = statistics.mean(r[0] for r in res) * 100
                b = statistics.mean(r[1] for r in res)
                row.append(f"{'ack' if ack else 'R'+str(R)} {m:6.3f}% {b:4.1f}B")
            print("  ".join(row))
