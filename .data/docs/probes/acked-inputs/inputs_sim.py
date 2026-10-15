"""`inputs`: since-ack input redundancy and a server playout buffer, on Lync's rates and network model.

Client: one input per state tick (index k = the client's state tick, v5.md §4.1's extension estimate);
the stream's chunk rides the first upstream unreliable frame of the flush in which the client's tick
advanced (one send per tick), carrying indices [start, k]:
  - "ack":   start = max(a + 1, k - C + 1), a = the newest index the server stated received (u12 in the
             downstream state-frame header, one per state tick, lost with the frame);
  - "fixed": start = k - C + 1 (no downstream field);
  - "flush": as "ack" but resent at every 1/60 s client flush (state.rate 20 only).
Chunk bits: id u3, count-1 EG0, first u12, ref u1; first copy absolute (42 bits, the busy model's
`move6`) or, when ref = 1, delta against index start - 1; later copies delta against the previous copy:
same:u1, else a 6-bit field mask and the changed fields. Frame overhead is not counted (the frame exists
for the game's other unreliable traffic or the ack); the downstream ack field is counted separately.
Input changes: each tick with probability 0.3, 1-3 of the 6 fields take new values.
Server playout (depth J ticks): o = min over the last 5 s of (first arrival of index i - i / rate);
index i is played at i / rate + o + J / rate; an index not received by then is MISSING (delivered as a
gap); a copy arriving later is LATE (discarded, counted). Latency = playout - sample time.
Network: v5.md §9's model: one-way 0.05 s + U(0, jitter) s, jitter 0.02 s (and 0.05 s), loss each way
5% Bernoulli or Gilbert-Elliott mean burst 3 at 5% / 15%.

Usage: python3 -I inputs_sim.py [seconds]
"""
import random
import sys

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 300.0
FIELDS = [10, 10, 1, 11, 2, 8]
ABS = sum(FIELDS)


def eg0(v):
    return 2 * (v + 1).bit_length() - 1


class Loss:
    def __init__(self, kind, p, rng):
        self.kind, self.p, self.rng, self.bad = kind, p, rng, False
        self.r_exit = 1 / 3
        self.r_enter = p * self.r_exit / (1 - p)

    def lost(self):
        if self.kind == "bern":
            return self.rng.random() < self.p
        self.bad = (self.rng.random() >= self.r_exit) if self.bad else (self.rng.random() < self.r_enter)
        return self.bad


def delta_bits(a, b):
    if a == b:
        return 1
    return 1 + 6 + sum(FIELDS[i] for i in range(6) if a[i] != b[i])


def run(rate, J, C, mode, net, jitter=0.02, seed=3):
    rng = random.Random(seed)
    down, up = Loss(net[0], net[1], rng), Loss(net[0], net[1], rng)
    N = int(SECONDS * rate)
    vals, cur = [], [0] * 6
    for _ in range(N):
        if rng.random() < 0.3:
            for i in rng.sample(range(6), rng.randint(1, 3)):
                cur[i] = rng.randrange(1 << FIELDS[i])
        vals.append(tuple(cur))
    arrive = {}                 # index -> first arrival time
    acks = []                   # (arrival at client, newest index received)
    a_cl = -1
    up_bits = 0
    copies = 0
    sends = 0
    newest_srv = -1
    down_frames = 0
    pending_up = []             # (arrival, first, last)
    flush = 1 / 60
    steps = int(SECONDS * 60)
    tick_sent = -1
    for s in range(steps):
        t = s * flush
        k = int(t * rate + 1e-9)
        if k >= N:
            break
        # server: frames arrived by t
        pending_up.sort()
        while pending_up and pending_up[0][0] <= t:
            at, lo, hi = pending_up.pop(0)
            for i in range(lo, hi + 1):
                if i not in arrive:
                    arrive[i] = at
            newest_srv = max(newest_srv, hi)
        # server: one state frame per state tick carrying the newest received index
        if mode != "fixed" and int((t - flush) * rate + 1e-9) != k and newest_srv >= 0:
            down_frames += 1
            if not down.lost():
                acks.append((t + 0.05 + rng.uniform(0, jitter), newest_srv))
        acks.sort()
        while acks and acks[0][0] <= t:
            a_cl = max(a_cl, acks.pop(0)[1])
        send = (k != tick_sent) or mode == "flush"
        if not send:
            continue
        tick_sent = k
        if mode == "fixed":
            start = max(0, k - C + 1)
        else:
            start = max(0, a_cl + 1, k - C + 1)
        ref = mode != "fixed" and start == a_cl + 1 and a_cl >= 0
        b = 3 + eg0(k - start) + 12 + 1
        b += delta_bits(vals[start - 1], vals[start]) if ref else ABS
        for i in range(start + 1, k + 1):
            b += delta_bits(vals[i - 1], vals[i])
        up_bits += b
        copies += k - start + 1
        sends += 1
        if not up.lost():
            pending_up.append((t + 0.05 + rng.uniform(0, jitter), start, k))
    # playout: o = sliding minimum over the last 5 s of first-arrival offsets (indices i - win .. i - 1)
    from collections import deque
    win = int(5 * rate)
    missing = late = 0
    lat = 0.0
    played = 0
    dq = deque()
    for i in range(N - 2 * rate):
        if i >= win:
            while dq and dq[0][0] < i - win:
                dq.popleft()
            if dq:
                o = dq[0][1]
                due = i / rate + o + J / rate
                a = arrive.get(i)
                played += 1
                lat += due - i / rate
                if a is None:
                    missing += 1
                elif a > due:
                    late += 1
        a = arrive.get(i)
        if a is not None:
            off = a - i / rate
            while dq and dq[-1][1] >= off:
                dq.pop()
            dq.append((i, off))
    return dict(miss=(missing + late) / played, lost=missing / played, late=late / played,
                Bps=up_bits / 8 / SECONDS, copies=copies / SECONDS, sends=sends / SECONDS,
                down=down_frames * 12 / 8 / SECONDS, lat=lat / played)


if __name__ == "__main__":
    print(f"inputs_sim: {SECONDS:.0f} s per run, seed 3, input {ABS} bits; see docstring")
    print("not delivered = missing + late (% of played indices); up B/s = stream chunk bits only;"
          " copies/s = elements decoded; latency = mean playout - sample (ms)")
    for net in (("bern", 0.05), ("ge", 0.05), ("ge", 0.15)):
        for rate in (20, 60):
            for J in (0, 1, 2, 3, 5):
                row = []
                for label, C, mode in (("R1", 1, "fixed"), ("R2", 2, "fixed"), (f"fixJ+1", J + 1, "fixed"),
                                       ("ack,C=J+1", J + 1, "ack"), ("ack,C=32", 32, "ack")) + \
                        ((("flush,C=J+1", J + 1, "flush"),) if rate == 20 else ()):
                    r = run(rate, J, C, mode, net)
                    row.append(f"{label} {r['miss'] * 100:6.3f}% {r['Bps']:5.0f}B/s {r['copies']:4.0f}c/s")
                lat = run(rate, J, J + 1, "ack", net)
                print(f"{net[0]}{int(net[1] * 100):<3d} rate {rate:2d} J={J} lat {lat['lat'] * 1000:5.1f}ms "
                      f"ackdown {lat['down']:3.0f}B/s | " + " | ".join(row))
    print("jitter 0.05 s, bern 5%:")
    for rate in (20, 60):
        for J in (1, 2, 3, 5):
            r = run(rate, J, J + 1, "ack", ("bern", 0.05), jitter=0.05)
            f = run(rate, J, J + 1, "fixed", ("bern", 0.05), jitter=0.05)
            print(f"  rate {rate} J={J}: ack {r['miss'] * 100:6.3f}% (late {r['late'] * 100:.3f}%) "
                  f"{r['Bps']:4.0f}B/s; fixed {f['miss'] * 100:6.3f}% {f['Bps']:4.0f}B/s; lat {r['lat'] * 1000:.1f}ms")
