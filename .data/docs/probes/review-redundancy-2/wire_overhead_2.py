"""Draft-2 framing bytes per player, from the layout in design draft 2 §4.1, §4.4 and §6.2.

Checks the change log's "886 -> 353 B/s up, 353 -> 130 B/s down" against draft 2's actual layout
(per-list EG0 counts, ack-only frames, tags on both upstream lanes), and adds the idle case, where
draft 2 replaced the 10 Hz heartbeat with an ack-only frame whenever an ack is owed.
Payload bits (ids, rows, values) are excluded; framing only, plus the byte padding of the bit
section (mean 3.5 bits per frame). Engine per-call overhead is unknown and excluded; calls/s are
listed so it can be added once measured (design §11).
Run: python3 -I wire_overhead_2.py
"""


def eg0(n):
    """Exp-Golomb order 0 length in bits for n >= 0."""
    return 2 * (n + 1).bit_length() - 1


ACK_NEW = 1 + 12 + 16
ACK_NONE = 1
TAG = 16
SEQ = 12
PAD = 3.5


def up(profile):
    r, u, dn_u = profile["up_r"], profile["up_u"], profile["dn_u"]
    frames = r + u
    # acks owed: one per new downstream unreliable frame batch; at most one per flush
    flushes_with_send = min(60, frames)
    acks_on_data = min(dn_u, flushes_with_send)
    ack_only = max(0, dn_u - acks_on_data) if profile["ack_only"] else 0
    runs = lambda n: eg0(n) + n * eg0(0)  # list count + per-run count-1 = 0
    bits = (
        r * (runs(1) + TAG + PAD)
        + u * (SEQ + runs(1) + TAG + PAD)
        + acks_on_data * ACK_NEW
        + (frames - acks_on_data) * ACK_NONE
        + ack_only * (SEQ + ACK_NEW + eg0(0) + TAG + PAD)
    )
    return bits / 8, frames + ack_only


def down(profile):
    r, u = profile["dn_r"], profile["dn_u"]
    tick_same = (r - 20) / r if r > 20 else 0
    tick = tick_same * 1 + (1 - tick_same) * 2
    rel = r * (tick + eg0(0) + eg0(1) + eg0(0) + PAD)  # states 0, runs 1, removes 0 typical
    unrel = u * (SEQ + 16 + eg0(1) + PAD)
    return (rel + unrel) / 8


PROFILES = {
    "busy (inputs 60/s, actions 10/s; down 60 rel + 20 unrel)": dict(up_r=10, up_u=60, dn_r=60, dn_u=20, ack_only=True),
    "idle, down unreliable 20/s (state ticks only)": dict(up_r=0, up_u=0, dn_r=20, dn_u=20, ack_only=True),
    "idle, down unreliable 60/s (unreliable server events every frame)": dict(up_r=0, up_u=0, dn_r=60, dn_u=60, ack_only=True),
}

print("profile | up B/s | up calls/s | down B/s")
for name, p in PROFILES.items():
    b, calls = up(p)
    print(f"{name} | {b:6.1f} | {calls:3d} | {down(p):6.1f}")

print()
print("draft 1 idle reference (10 Hz heartbeat on unreliable: tick16 + ack48 + seq12 + tag16 + section 11):",
      f"{10 * (16 + 48 + 12 + 16 + 11) / 8:.1f} B/s, 10 calls/s")
print("ack-only frame:", f"{(SEQ + ACK_NEW + eg0(0) + TAG + PAD) / 8:.2f} B")

print()
print("== Batched ack-only frames: owe an ack only once K new downstream unreliable frames are unacked")
for dn_u in (20, 60):
    for K in (1, 2, 4, 8):
        rate = dn_u / K
        cover_repeats = 17 / K  # ack-carrying frames that cover each downstream frame
        extra_delay_ms = (K - 1) / dn_u * 1000
        print(f"dn_u {dn_u:2d}/s K={K}: {rate:5.1f} ack frames/s, {rate * 8:5.0f} B/s, "
              f"each frame acked {cover_repeats:4.1f}x, repair delay +{extra_delay_ms:4.0f} ms worst")

print()
print("== Definition ids: one space for both directions and both request roles (§4.1) vs per direction")
def width(n):
    return (n).bit_length()  # ceil(log2(n + 1)) for ids 1..n with 0 = control

cases = {
    "arena (§3.4)": dict(cev=2, sev=1, creq=1, sreq=0, col=2),
    "60 definitions": dict(cev=10, sev=30, creq=6, sreq=2, col=4),
}
for name, c in cases.items():
    shared = c["cev"] + c["sev"] + 2 * (c["creq"] + c["sreq"]) + c["col"]
    upn = c["cev"] + c["creq"] + c["sreq"]          # client events, client asks, answers to server asks
    dnn = c["sev"] + c["sreq"] + c["creq"]          # server events, server asks, answers to client asks
    print(f"{name}: shared {shared} ids -> {width(shared)} bits on every run and collection section; "
          f"per direction: up {width(upn)} bits, down runs {width(dnn)} bits, collection index {max(1, (c['col'] - 1).bit_length())} bits")
