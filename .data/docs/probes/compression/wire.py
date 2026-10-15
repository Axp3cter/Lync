"""Shared wire primitives for the compression simulations.

Everything here is a reference implementation in plain Python. It is not
meant to be fast; it is meant to produce exactly the bytes a Luau codec would.

Run any probe from this directory with:  PYTHONPATH=<dir with zstandard> python3 <probe>.py
"""
import math
import struct

import zstandard as zs

# ---------------------------------------------------------------------------
# zstd as the engine might apply it
# ---------------------------------------------------------------------------

_CCTX = {}


def zstd_len(data: bytes, level: int = 3, magicless: bool = False) -> int:
    """Length of one independent zstd frame of `data` (no checksum, content size on)."""
    key = (level, magicless)
    c = _CCTX.get(key)
    if c is None:
        params = zs.ZstdCompressionParameters.from_level(
            level, write_checksum=False, write_content_size=True,
            format=zs.FORMAT_ZSTD1_MAGICLESS if magicless else zs.FORMAT_ZSTD1)
        c = zs.ZstdCompressor(compression_params=params)
        _CCTX[key] = c
    return len(c.compress(data))


def engine_len(data: bytes, level: int = 3, threshold: int = 100, fallback: bool = True) -> int:
    """Modelled on-wire size of one buffer argument (payload only, no call overhead).

    threshold: buffers shorter than this are sent raw (PacketProfiler's model).
    fallback:  if True, the engine keeps the raw bytes when zstd does not shrink them.
    The +varint length prefix that Roblox writes is ignored here (same for all layouts).
    """
    n = len(data)
    if n < threshold:
        return n
    z = zstd_len(data, level)
    return min(n, z) if fallback else z


# ---------------------------------------------------------------------------
# bit writer (LSB-first, like buffer.writebits)
# ---------------------------------------------------------------------------

class BitWriter:
    __slots__ = ("acc", "n", "out")

    def __init__(self):
        self.acc = 0
        self.n = 0
        self.out = bytearray()

    def w(self, v: int, bits: int):
        if bits == 0:
            return
        self.acc |= (v & ((1 << bits) - 1)) << self.n
        self.n += bits
        while self.n >= 8:
            self.out.append(self.acc & 255)
            self.acc >>= 8
            self.n -= 8

    def bitlen(self) -> int:
        return len(self.out) * 8 + self.n

    def done(self) -> bytes:
        if self.n:
            self.out.append(self.acc & 255)
            self.acc = 0
            self.n = 0
        return bytes(self.out)


# ---------------------------------------------------------------------------
# integer transforms and codes
# ---------------------------------------------------------------------------

def zz(v: int) -> int:
    return (v << 1) if v >= 0 else ((-v << 1) - 1)


def unzz(u: int) -> int:
    return (u >> 1) if not (u & 1) else -((u + 1) >> 1)


def leb128(v: int, out: bytearray):
    while v >= 0x80:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)


def prefix_varint(v: int, out: bytearray):
    """PrefixVarint (unary length in the low bits of byte 0, little-endian payload).

    1 byte: 7 bits, 2: 14, 3: 21, 4: 28, 5: 35, ... 9 bytes: 64 bits.
    Decoding needs one table lookup (count trailing ones/zeros of byte 0).
    """
    for nbytes in range(1, 9):
        if v < (1 << (7 * nbytes)):
            word = (v << nbytes) | ((1 << (nbytes - 1)) - 1)
            out += word.to_bytes(nbytes, "little")
            return
    out.append(0xFF)
    out += v.to_bytes(8, "little")


def sqlite4_varint(v: int, out: bytearray):
    """SQLite4 varint: 0-240 in 1 byte, 241-2287 in 2, 2288-67823 in 3, then 249..255 + n bytes BE."""
    if v <= 240:
        out.append(v)
    elif v <= 2287:
        v -= 240
        out.append((v >> 8) + 241)
        out.append(v & 255)
    elif v <= 67823:
        v -= 2288
        out.append(249)
        out.append(v >> 8)
        out.append(v & 255)
    else:
        for n in range(3, 9):
            if v < (1 << (8 * n)):
                out.append(250 + n - 3)
                out += v.to_bytes(n, "big")
                return
        raise ValueError(v)


def vu128(v: int, out: bytearray):
    """vu128: values < 0xF0 in one byte; else 0xF0|(n-1) then n LE bytes."""
    if v < 0xF0:
        out.append(v)
        return
    n = max(1, (v.bit_length() + 7) // 8)
    out.append(0xF0 | (n - 1))
    out += v.to_bytes(n, "little")


def _nbytes(v: int) -> int:
    return 1 if v < 256 else 2 if v < 65536 else 3 if v < (1 << 24) else 4


def group_varint(vals, out: bytearray):
    """Google group varint: per 4 values one tag byte (2 bits each = byte length-1)."""
    for i in range(0, len(vals), 4):
        g = vals[i:i + 4]
        tag = 0
        body = bytearray()
        for j, v in enumerate(g):
            n = _nbytes(v)
            tag |= (n - 1) << (2 * j)
            body += v.to_bytes(n, "little")
        out.append(tag)
        out += body


def stream_vbyte(vals, out: bytearray):
    """Stream VByte: all control bytes first, then all data bytes (Lemire et al. 2017)."""
    ctrl = bytearray()
    data = bytearray()
    for i in range(0, len(vals), 4):
        g = vals[i:i + 4]
        tag = 0
        for j, v in enumerate(g):
            n = _nbytes(v)
            tag |= (n - 1) << (2 * j)
            data += v.to_bytes(n, "little")
        ctrl.append(tag)
    out += ctrl
    out += data


def exp_golomb(bw: BitWriter, v: int, k: int = 0):
    """Exp-Golomb order k for v >= 0 (bit order: unary prefix of zeros then the value)."""
    v += (1 << k)
    nb = v.bit_length()
    bw.w(0, nb - 1 - k)
    # write value MSB-first, as the classic code does, but emitted LSB-first by bits
    for i in range(nb - 1, -1, -1):
        bw.w((v >> i) & 1, 1)


def elias_gamma(bw: BitWriter, v: int):
    exp_golomb(bw, v, 0)


def elias_delta(bw: BitWriter, v: int):
    n = v + 1
    L = n.bit_length()
    elias_gamma(bw, L - 1)
    for i in range(L - 2, -1, -1):
        bw.w((n >> i) & 1, 1)


def rice(bw: BitWriter, v: int, k: int):
    q = v >> k
    if q > 32:  # escape: 33 ones then 32-bit raw (keeps pathological cases bounded)
        bw.w((1 << 33) - 1, 33)
        bw.w(v, 32)
        return
    bw.w((1 << q) - 1, q)
    bw.w(0, 1)
    bw.w(v & ((1 << k) - 1), k)


def rice_best_k(vals) -> int:
    best, bk = None, 0
    for k in range(0, 24):
        bits = sum((v >> k) + 1 + k if (v >> k) <= 32 else 33 + 32 for v in vals)
        if best is None or bits < best:
            best, bk = bits, k
    return bk


# The v5 attempt's 4-bit class code: 16 width classes for an unbounded integer.
CLASS_WIDTHS = [0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32, 40, 53]


def class_code(bw: BitWriter, v: int):
    for c, w in enumerate(CLASS_WIDTHS):
        if v < (1 << w):
            bw.w(c, 4)
            bw.w(v, w)
            return
    raise ValueError(v)


# Unity Collections StreamCompressionModel (2.7.1) default model: 16 power-of-two buckets,
# Huffman-coded bucket index (code lengths below), then raw offset bits.
UNITY_BUCKET_SIZES = [0, 0, 1, 2, 3, 4, 6, 8, 10, 12, 15, 18, 21, 24, 27, 32]
UNITY_BUCKET_OFFSETS = [0, 1, 2, 4, 8, 16, 32, 96, 352, 1376, 5472, 38240, 300384,
                        2397536, 19174752, 153392480]
UNITY_CODE_LENGTHS = [2, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6, 6, 6, 6, 6]


def unity_bucket_bits(v: int) -> int:
    b = 15
    while UNITY_BUCKET_OFFSETS[b] > v:
        b -= 1
    return UNITY_CODE_LENGTHS[b] + UNITY_BUCKET_SIZES[b]


def unity_bucket(bw: BitWriter, v: int):
    b = 15
    while UNITY_BUCKET_OFFSETS[b] > v:
        b -= 1
    # canonical code value is irrelevant for size; write length-many bits of the bucket id
    bw.w(b, UNITY_CODE_LENGTHS[b])
    bw.w(v - UNITY_BUCKET_OFFSETS[b], UNITY_BUCKET_SIZES[b])


def for_bitpack(vals, out: bytearray, block: int = 128):
    """Frame of reference + bit packing per block: [min varint][width u8][packed]."""
    for i in range(0, len(vals), block):
        g = vals[i:i + block]
        lo = min(g)
        w = max(v - lo for v in g).bit_length()
        leb128(lo, out)
        out.append(w)
        bw = BitWriter()
        for v in g:
            bw.w(v - lo, w)
        out += bw.done()


def pfor_bitpack(vals, out: bytearray, block: int = 128):
    """Patched FOR: width chosen to cover ~90% of values, exceptions listed as (pos, value) varints."""
    for i in range(0, len(vals), block):
        g = vals[i:i + block]
        lo = min(g)
        rel = sorted(v - lo for v in g)
        best = None
        for w in range(0, rel[-1].bit_length() + 1):
            exc = [v for v in rel if v >= (1 << w)]
            cost = len(g) * w + sum(8 + 8 * max(1, (v.bit_length() + 6) // 7) for v in exc)
            if best is None or cost < best[0]:
                best = (cost, w)
        w = best[1]
        leb128(lo, out)
        out.append(w)
        excs = [(j, v - lo) for j, v in enumerate(g) if v - lo >= (1 << w)]
        leb128(len(excs), out)
        bw = BitWriter()
        for v in g:
            bw.w(v - lo if v - lo < (1 << w) else 0, w)
        out += bw.done()
        for j, v in excs:
            out.append(j)
            leb128(v, out)


SIMPLE8B = [(240, 0), (120, 0), (60, 1), (30, 2), (20, 3), (15, 4), (12, 5), (10, 6),
            (8, 7), (7, 8), (6, 10), (5, 12), (4, 15), (3, 20), (2, 30), (1, 60)]


def simple8b(vals, out: bytearray):
    """Simple-8b: 64-bit words, 4-bit selector + 60 payload bits (selectors 0/1 = runs of 0)."""
    i = 0
    n = len(vals)
    while i < n:
        for sel, (cnt, w) in enumerate(SIMPLE8B):
            if w == 0:
                if i + cnt <= n and all(v == 0 for v in vals[i:i + cnt]):
                    out += (sel).to_bytes(8, "little")
                    i += cnt
                    break
                continue
            take = min(cnt, n - i)
            if take < cnt and sel < 15:
                # partial words only allowed if all remaining fit; pad
                pass
            if all(v < (1 << w) for v in vals[i:i + take]):
                word = sel
                for j, v in enumerate(vals[i:i + take]):
                    word |= v << (4 + j * w)
                out += word.to_bytes(8, "little")
                i += take
                break
        else:
            raise ValueError("value too large for simple8b")


# ---------------------------------------------------------------------------
# quantisation helpers
# ---------------------------------------------------------------------------

def quant(v: float, lo: float, step: float, bits: int) -> int:
    q = int(round((v - lo) / step))
    return max(0, min((1 << bits) - 1, q))


def f16_bytes(v: float) -> bytes:
    return struct.pack("<e", max(-65504.0, min(65504.0, v)))


def bf16_bytes(v: float) -> bytes:
    b = struct.pack("<f", v)
    # round-to-nearest-even truncation of float32 to its top 16 bits
    u = int.from_bytes(b, "little")
    u = (u + 0x7FFF + ((u >> 16) & 1)) >> 16
    return (u & 0xFFFF).to_bytes(2, "little")


def entropy_bits(counts) -> float:
    tot = sum(counts)
    return -sum(c * math.log2(c / tot) for c in counts if c)
