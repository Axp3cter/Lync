"""Byte arithmetic for the redundancy/inefficiency review of design v5 (draft 1).

Every number printed here follows from the frame layout in design §4.1, §5.2, §6.2 and the stated
traffic assumptions below. No simulation, no randomness except the ack-coverage model.
Run: python3 -I wire_overhead.py
"""

from math import ceil, log2

# ---------------------------------------------------------------- traffic profiles (assumptions)
# frames per second per player, per direction and lane
PROFILES = {
    # shooter player: 60 Hz unreliable inputs up, a reliable action 10/s up,
    # reliable frames down every frame (events), unreliable state at the 20 Hz state tick
    "busy": dict(up_r=10, up_u=60, dn_r=60, dn_u=20, sec_up_r=1, sec_up_u=1, sec_dn_r=2, sec_dn_u=1),
    # player standing still: heartbeat only up; down reliable at state tick, unreliable at state tick
    "idle": dict(up_r=0, up_u=10, dn_r=20, dn_u=20, sec_up_r=0, sec_up_u=0, sec_dn_r=1, sec_dn_u=1),
}

# ---------------------------------------------------------------- design as written (bits)
TICK = 16
ACK = 16 + 32
TAG = 16
SEQ_U = 12
SECTION = 3 + 8  # kind:u3 + prefix varint length for a body < 128 B (1 byte)


def design(p):
    up_r = p["up_r"] * (TICK + ACK + TAG + p["sec_up_r"] * SECTION)
    up_u = p["up_u"] * (TICK + ACK + SEQ_U + TAG + p["sec_up_u"] * SECTION)
    dn_r = p["dn_r"] * (TICK + p["sec_dn_r"] * SECTION)
    dn_u = p["dn_u"] * (TICK + p["sec_dn_u"] * SECTION)
    return dict(up=(up_r + up_u) / 8, dn=(dn_r + dn_u) / 8)


# ---------------------------------------------------------------- proposed (bits)
# upstream: no tick (it equals the ack); ack sent once per client frame on one lane, and only when a
# new downstream unreliable frame arrived since the last ack (1 presence bit otherwise);
# ack = 12-bit downstream sequence + 16-bit bitfield.
# downstream reliable: tick as a delta from the previous reliable frame: '0' same, '10' +1, '11'+u16.
# downstream unreliable: 12-bit sequence + u16 tick.
# sections: one presence bit per section kind in fixed order (5 kinds), no per-section length;
# byte tail written from the end of the buffer so no tail offset is needed.
KINDS = 5
ACK_NEW = 12 + 16


def tick_delta_bits(frames_per_tick):
    same = (frames_per_tick - 1) / frames_per_tick
    return same * 1 + (1 - same) * 2


def proposed(p):
    ack_frames = min(p["dn_u"], p["up_r"] + p["up_u"])  # acks needed at most once per new downstream frame
    up_frames = p["up_r"] + p["up_u"]
    ack_bits = ack_frames * ACK_NEW + up_frames * 1
    up_r = p["up_r"] * (TAG + (KINDS if p["sec_up_r"] else 0))
    up_u = p["up_u"] * (SEQ_U + TAG + (KINDS if p["sec_up_u"] else 0))
    dn_r = p["dn_r"] * (tick_delta_bits(p["dn_r"] / 20) + KINDS)
    dn_u = p["dn_u"] * (12 + TICK + KINDS)
    return dict(up=(up_r + up_u + ack_bits) / 8, dn=(dn_r + dn_u) / 8)


print("== Header + section framing, bytes per second per player (design §4.1, §5.2, §6.2)")
print("profile  dir   design   proposed  saved")
for name, p in PROFILES.items():
    d, q = design(p), proposed(p)
    for k in ("up", "dn"):
        print(f"{name:7s}  {k:4s} {d[k]:7.1f}  {q[k]:8.1f}  {d[k]-q[k]:6.1f} ({(1-q[k]/d[k])*100:4.1f}%)")

print()
print("== Upstream unreliable input frame, bytes (design: tick+ack+bits+seq+tag+section)")
d_hdr = (TICK + ACK + SEQ_U + TAG + SECTION) / 8
print(f"design header {d_hdr:.2f} B vs input payload 6.5-9.0 B/packet [state-sync §4.1]")
q_hdr_ack = (SEQ_U + TAG + KINDS + 1 + ACK_NEW) / 8
q_hdr = (SEQ_U + TAG + KINDS + 1) / 8
print(f"proposed header {q_hdr:.2f} B (no new ack) / {q_hdr_ack:.2f} B (with ack)")

print()
print("== Ack repetition: how many upstream acks cover each downstream unreliable frame")
print("bitfield L  dn_u Hz  ack frames/s  repeats  P(never acked | 5% iid loss)")
for L in (8, 16, 32):
    for dn_u, up in ((20, 60), (20, 10), (60, 10), (60, 60)):
        ack_rate = min(dn_u, up)  # ack only when new
        covered = L + 1  # newest + L bits
        repeats = covered * ack_rate / dn_u
        print(f"{L:9d}  {dn_u:7d}  {ack_rate:12d}  {repeats:7.1f}  {0.05**repeats:.1e}")
print("design (ack on every upstream frame, both lanes, L=32) at busy profile: "
      f"each dn_u frame covered by {33*(60+10)/20:.0f} acks")

print()
print("== Ack bytes alone, busy profile")
d_ack = (60 + 10) * ACK / 8
q_ack = (20 * ACK_NEW + 70) / 8
print(f"design {d_ack:.0f} B/s, proposed {q_ack:.0f} B/s")

print()
print("== Section length prefixes downstream, as share of the 16,000 B/s state budget (busy)")
p = PROFILES["busy"]
sec = (p["dn_r"] * p["sec_dn_r"] + p["dn_u"] * p["sec_dn_u"]) * SECTION / 8
print(f"{sec:.0f} B/s of kind+length = {sec/16000*100:.1f}% of stateBudget")

print()
print("== Intern table (design §4.4: per connection, append-only, cap 4096, no transient marker)")
for unique_per_s in (1, 5, 20):
    print(f"{unique_per_s:3d} new strings/s server-wide broadcast -> table full after {4096/unique_per_s/60:5.1f} min")
for max_bytes, players in ((20, 100), (200, 100)):
    mb = 4096 * (max_bytes + 24) * players / 1e6  # +24 B Luau string header (approx.)
    print(f"cap 4096 x t.string({max_bytes}) x {players} connections, one direction: up to {mb:.1f} MB server memory")

print()
print("== Handshake HELLO size (design §4.5) by definition count, hash widths 32/64 bit")
for n in (20, 100, 300):
    for w in (4, 8):
        hello = 2 + 1 + w + n * w + 4  # version, format, schema hash, per-def hashes, seed
        print(f"n={n:3d} hash={w*8}b  HELLO {hello:5d} B   (needed when hashes match: {2+w} B)")

print()
print("== Request ids (design §5.5: u16 per request and per reply)")
cap = 16
print(f"implicit request id (both sides count reliable requests): saves 16 bits per request")
print(f"reply id as offset into the in-flight window (cap {cap}): {ceil(log2(cap))} bits instead of 16")

print()
print("== timestamped (design §5.6: 1 B sub-tick offset per event)")
for hz_tick, hz_frame in ((20, 60), (30, 60), (60, 60)):
    fpt = hz_frame / hz_tick
    print(f"state {hz_tick} Hz, frames {hz_frame} Hz: frame index within tick = {ceil(log2(fpt)) if fpt>1 else 0} bits per frame; "
          f"per-event offset = 8 bits per event")

print()
print("== Notify in-flight ring per viewer (design §5.2; research says 64 entries, ack covers 33)")
for recs in (50, 200):
    for entries in (64, 33):
        buf = entries * recs * 2
        tbl = entries * recs * 16
        print(f"{recs:3d} records/frame, {entries} entries: buffer u16 {buf/1024:5.1f} KB, Luau array {tbl/1024:6.1f} KB per viewer")
