"""Replicated-state schemes over Lync's two lanes under loss: bytes vs staleness.

Model (all numbers are assumptions, stated so they can be changed):
- 20 Hz send tick, 64 records, 60 s (1200 ticks) per run, 8 seeds.
- Records alternate between moving and idle (Markov: moving->idle 5 %/tick, idle->moving 2 %/tick, so about
  29 % of records move at a time); a moving record's newest value changes every tick.
- Absolute record state = ABS bytes; a delta against a baseline k ticks old costs
  delta_bytes(k) (small for recent baselines, absolute when old); every record reference adds ID bytes.
- One-way latency 1 tick (50 ms), RTT 2 ticks. Upstream acks see the same loss.
- Reliable lane: delivered in order; a lost packet is retransmitted after RTO ticks and blocks every
  later reliable packet until then (head-of-line). RTO = 3 ticks is an ASSUMPTION about Roblox's
  reliable layer, not a measured value.
- Unreliable lane: independent drops (Bernoulli) or bursty drops (Gilbert-Elliott), no reorder modelled
  (reorder only matters to schemes that already carry a sequence and drop stale packets).

Schemes:
  full_unrel   every tick, absolute state of every record on unreliable.
  changed_unrel  absolute state of records changed this tick on unreliable (no repair: lossy "newest").
  changed_settle as changed_unrel, plus a reliable absolute resend of a record 10 ticks after it stops changing.
  chain_unrel  delta vs last SENT on unreliable, keyframe every 20 ticks (Warp-style); a gap corrupts until keyframe.
  acked_unrel  delta vs last ACKED snapshot (Quake 3 / Gaffer); records equal to baseline cost nothing.
  relbase_unrel  reliable absolute baseline every 20 ticks + unreliable "changed since baseline" deltas (Mirror SyncMethod.Unreliable).
  dirty_ack_unrel  Tribes/TNL notify: send absolute latest of dirty records; on packet loss, re-dirty only records
                 not re-sent since (no retransmission of stale values).
  rel_delta    delta vs last sent on the reliable lane (v4 / v5-attempt); never wrong, stalls under loss.

  changed_x2   changed_unrel with every update repeated in the next packet (Quake/Mirror "send twice").

Metrics: bytes/tick (payload only), and staleness of what the receiver shows: 0 when it shows the sender's
current value, else ticks since the sender's value first moved past the value shown (so the minimum for a
moving record is 1 tick of latency). Mean, p99, and share of record-ticks more than 4 ticks (200 ms) stale.
"""
import random, statistics, sys

T, N, ABS, ID = 1200, 64, 8, 1
P_STOP, P_START = 0.05, 0.02
import bisect
RTO = 3
def delta_bytes(age):
    return 3 if age <= 3 else 5 if age <= 10 else ABS

def staleness(ch, shown, current, tick):
    if shown == current:
        return 0
    return tick - ch[bisect.bisect_right(ch, shown)] + 1

def loss_process(kind, p, rng):
    if kind == "bern":
        while True:
            yield rng.random() < p
    # Gilbert-Elliott: mean burst 3 packets; stationary loss p
    bad = False
    r_exit = 1 / 3
    r_enter = p * r_exit / (1 - p)
    while True:
        bad = (rng.random() >= r_exit) if bad else (rng.random() < r_enter)
        yield bad

def run(scheme, kind, p, seed):
    rng = random.Random(seed)
    down = loss_process(kind, p, rng)
    up = loss_process(kind, p, rng)
    ver = [0] * N               # sender version (tick of last change)
    moving = [rng.random() < 0.29 for _ in range(N)]
    changes = [[0] for _ in range(N)]
    shown = [0] * N             # sender version the receiver currently shows
    bytes_total = 0
    stale = []
    # pending deliveries: tick -> list of (kind, payload)
    inbox = {}
    def deliver(at, item):
        inbox.setdefault(at, []).append(item)
    # reliable lane state: next free delivery tick (HOL)
    rel_free = 0
    def send_rel(tick, item, nbytes):
        nonlocal rel_free, bytes_total
        bytes_total += nbytes
        t = max(tick + 1, rel_free)
        while next(down):         # each loss costs an RTO and blocks the lane
            t += RTO
        rel_free = t
        deliver(t, item)
    def send_unrel(tick, item, nbytes):
        nonlocal bytes_total
        bytes_total += nbytes
        if not next(down):
            deliver(tick + 1, item)
    # scheme state
    history = {}                # tick -> versions snapshot sent (for acked / notify)
    acked_tick = None           # latest snapshot tick acked by receiver (as known by sender)
    ack_inbox = {}
    last_change = [0] * N
    settled = [True] * N
    dirty = set(range(N))
    inflight = {}               # packet tick -> records carried (notify)
    last_sent_in = [-1] * N     # last packet tick carrying record (notify)
    base_tick, base_ver = None, None
    prev_ch = []
    recv_base = None
    recv_base_ver = None
    for tick in range(1, T + 1):
        # world changes
        for i in range(N):
            moving[i] = (rng.random() >= P_STOP) if moving[i] else (rng.random() < P_START)
            if moving[i]:
                ver[i] = tick
                changes[i].append(tick)
                last_change[i] = tick
                settled[i] = False
                dirty.add(i)
        # acks reaching sender this tick (notify / acked schemes)
        for (ptick, ok) in ack_inbox.pop(tick, []):
            if scheme == "acked_unrel" and ok:
                if acked_tick is None or ptick > acked_tick:
                    acked_tick = ptick
            if scheme == "dirty_ack_unrel":
                carried = inflight.pop(ptick, [])
                if not ok:
                    for i in carried:
                        if last_sent_in[i] == ptick:   # not superseded by a later send
                            dirty.add(i)
        # send
        if scheme == "full_unrel":
            send_unrel(tick, ("abs", list(range(N)), list(ver)), N * ABS)
        elif scheme in ("changed_unrel", "changed_settle", "changed_x2"):
            ch = [i for i in range(N) if ver[i] == tick]
            if scheme == "changed_x2":
                ch = sorted(set(ch) | set(prev_ch))
                prev_ch = [i for i in range(N) if ver[i] == tick]
            send_unrel(tick, ("abs", ch, list(ver)), len(ch) * (ABS + ID))
            if scheme == "changed_settle":
                st = [i for i in range(N) if not settled[i] and tick - last_change[i] >= 10]
                for i in st:
                    settled[i] = True
                if st:
                    send_rel(tick, ("abs", st, list(ver)), len(st) * (ABS + ID))
        elif scheme == "acked_unrel":
            snap = list(ver)
            history[tick] = snap
            if acked_tick is None or tick - acked_tick > 30:
                send_unrel(tick, ("abs", list(range(N)), snap), N * ABS)
            else:
                base = history[acked_tick]
                ch = [i for i in range(N) if snap[i] != base[i]]
                send_unrel(tick, ("abs", ch, snap),
                           sum(delta_bytes(tick - base[i]) + ID for i in ch) + 2)
        elif scheme == "relbase_unrel":
            if tick % 20 == 1:
                base_tick, base_ver = tick, list(ver)
                send_rel(tick, ("base", tick, list(ver)), N * ABS)
            else:
                ch = [i for i in range(N) if ver[i] != base_ver[i]]
                send_unrel(tick, ("since", base_tick, ch, list(ver)),
                           sum(delta_bytes(tick - base_ver[i]) + ID for i in ch) + 1)
        elif scheme == "dirty_ack_unrel":
            ch = sorted(dirty)
            dirty.clear()
            for i in ch:
                last_sent_in[i] = tick
            inflight[tick] = ch
            send_unrel(tick, ("abs", ch, list(ver)), len(ch) * (ABS + ID) + 2)
        elif scheme == "rel_delta":
            ch = [i for i in range(N) if ver[i] == tick]
            send_rel(tick, ("abs", ch, list(ver)), len(ch) * (delta_bytes(1) + ID))
        # receive this tick's arrivals (and schedule acks)
        arrivals = inbox.pop(tick, [])
        if scheme in ("acked_unrel", "dirty_ack_unrel"):
            # the receiver reports whether the packet sent last tick arrived; acks ride a redundant
            # bitfield (Gaffer), so a lost upstream packet only delays the report by one tick
            got = len(arrivals) > 0
            delay = 2 if next(up) else 1
            ack_inbox.setdefault(tick + delay, []).append((tick - 1, got))
        for it in arrivals:
            k = it[0]
            if k in ("abs", "key"):
                ids, v = it[1], it[2]
                for i in ids:
                    if v[i] > shown[i]:
                        shown[i] = v[i]
            elif k == "base":
                recv_base, recv_base_ver = it[1], it[2]
                for i in range(N):
                    if recv_base_ver[i] > shown[i]:
                        shown[i] = recv_base_ver[i]
            elif k == "since":
                bt, ids, v = it[1], it[2], it[3]
                if bt == recv_base:
                    for i in ids:
                        if v[i] > shown[i]:
                            shown[i] = v[i]
        for i in range(N):
            stale.append(staleness(changes[i], shown[i], ver[i], tick))
    return bytes_total / T, stale

def run_chain(kind, p, seed):
    """Delta-vs-last-sent on unreliable, keyframe every 20 ticks: separate, since state is path-dependent."""
    rng = random.Random(seed)
    down = loss_process(kind, p, rng)
    ver = [0] * N
    shown = [0] * N
    moving = [rng.random() < 0.29 for _ in range(N)]
    changes = [[0] for _ in range(N)]
    good = True
    total = 0
    stale = []
    pending = []
    for tick in range(1, T + 1):
        for i in range(N):
            moving[i] = (rng.random() >= P_STOP) if moving[i] else (rng.random() < P_START)
            if moving[i]:
                ver[i] = tick
                changes[i].append(tick)
        if tick % 20 == 1:
            total += N * ABS
            pkt = ("key", list(ver))
        else:
            ch = [i for i in range(N) if ver[i] == tick]
            total += len(ch) * (delta_bytes(1) + ID)
            pkt = ("chain", list(ver))
        lost = next(down)
        # arrives next tick
        if pending:
            k, v, ok = pending.pop()
            if k == "key" and ok:
                shown, good = list(v), True
            elif k == "chain":
                if ok and good:
                    shown = list(v)
                elif not ok:
                    good = False      # a lost delta breaks the chain until the next keyframe
            elif k == "key" and not ok:
                good = False
        pending.append((pkt[0], pkt[1], not lost))
        for i in range(N):
            stale.append(staleness(changes[i], shown[i], ver[i], tick))
    return total / T, stale

def summarise(name, rows):
    b = statistics.mean(r[0] for r in rows)
    st = [s for r in rows for s in r[1]]
    st.sort()
    mean = statistics.mean(st)
    p99 = st[int(len(st) * 0.99)]
    over4 = sum(1 for s in st if s > 4) / len(st)
    worst = st[-1]
    return f"{name:16s} {b:8.1f} {mean:7.2f} {p99:5d} {worst:6d} {100*over4:7.2f}%"

if __name__ == "__main__":
    print(__doc__.split("\n")[0])
    print(f"T={T} ticks @20 Hz, N={N}, stop/start={P_STOP}/{P_START}, ABS={ABS} B, RTO={RTO} ticks (assumed); 8 seeds")
    for kind, p in (("bern", 0.0), ("bern", 0.01), ("bern", 0.05), ("ge", 0.05), ("ge", 0.15)):
        print(f"\n-- loss {kind} p={p}")
        print(f"{'scheme':16s} {'B/tick':>8s} {'meanStl':>7s} {'p99':>5s} {'max':>6s} {'>4ticks':>8s}")
        for s in ("full_unrel", "changed_unrel", "changed_x2", "changed_settle", "acked_unrel",
                  "relbase_unrel", "dirty_ack_unrel", "rel_delta"):
            rows = [run(s, kind, p, seed) for seed in range(8)]
            print(summarise(s, rows))
        print(summarise("chain_unrel", [run_chain(kind, p, seed) for seed in range(8)]))
