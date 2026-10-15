"""Frame layouts for entity-state traffic (Q2 of the compression study).

Every layout encodes the same information: the recipient's visible entity set and
the quantised fields in traffic.py's schemas. Delta layouts encode against a
baseline frame `age` ticks back (age 1 = previous frame, i.e. the reliable lane;
age k = last acknowledged frame on the unreliable lane).

Common structure of delta layouts:
  [entered count][entered ids + absolute rows][left count][left ids][updates]
The entered/left section is identical inside a layout family (aligned or bits).
"""
import struct

from wire import (BitWriter, leb128, zz, class_code, exp_golomb)


EVENT_IDS = {"shot": 0, "kill": 1, "purchase": 2, "money": 3}


def fbytes(bits):
    return (bits + 7) // 8


def wrap(d, bits):
    """Signed wrapped difference in [-2^(bits-1), 2^(bits-1))."""
    m = 1 << bits
    d %= m
    return d - m if d >= m // 2 else d


class Layout:
    """Bound to one model schema. `encode(frames, i, age)` -> bytes for frame i."""

    def __init__(self, model_cls):
        self.schema = model_cls.schema
        self.id_bits = model_cls.id_bits
        self.id_bytes = fbytes(model_cls.id_bits)
        self.nf = len(self.schema)
        self.bits = [f[2] for f in self.schema]
        self.kinds = [f[1] for f in self.schema]
        self.bool_idx = [k for k, f in enumerate(self.schema) if f[1] == "b"]
        self.byte_idx = [k for k, f in enumerate(self.schema) if f[1] != "b"]
        self.float_fields = model_cls.float_fields
        self.name_to_idx = {f[0]: k for k, f in enumerate(self.schema)}

    # ----- shared pieces -------------------------------------------------
    def aligned_row(self, row, out):
        for k in self.byte_idx:
            out += row[k].to_bytes(fbytes(self.bits[k]), "little")
        if self.bool_idx:
            v = 0
            for j, k in enumerate(self.bool_idx):
                v |= row[k] << j
            out += v.to_bytes(fbytes(len(self.bool_idx)), "little")

    def bits_row(self, row, bw):
        for k in range(self.nf):
            bw.w(row[k], self.bits[k])

    def aligned_events(self, f, out):
        leb128(len(f.events), out)
        for kind, fields in f.events:
            out.append(EVENT_IDS[kind])
            for v, b in fields:
                out += v.to_bytes(fbytes(b), "little")

    def bits_events(self, f, bw):
        n = len(f.events)
        exp_golomb(bw, n, 0)
        for kind, fields in f.events:
            bw.w(EVENT_IDS[kind], 3)
            for v, b in fields:
                bw.w(v, b)

    def set_changes_aligned(self, f, base, out):
        ent = [i for i in sorted(f.rows) if i not in base.rows]
        left = [i for i in sorted(base.rows) if i not in f.rows]
        leb128(len(ent), out)
        for i in ent:
            out += i.to_bytes(self.id_bytes, "little")
            self.aligned_row(f.rows[i], out)
        leb128(len(left), out)
        for i in left:
            out += i.to_bytes(self.id_bytes, "little")
        return [i for i in sorted(f.rows) if i in base.rows]

    def set_changes_bits(self, f, base, bw):
        ent = [i for i in sorted(f.rows) if i not in base.rows]
        left = [i for i in sorted(base.rows) if i not in f.rows]
        exp_golomb(bw, len(ent), 0)
        for i in ent:
            bw.w(i, self.id_bits)
            self.bits_row(f.rows[i], bw)
        exp_golomb(bw, len(left), 0)
        for i in left:
            bw.w(i, self.id_bits)
        return [i for i in sorted(f.rows) if i in base.rows]

    def deltas(self, f, base, ids, pred=None):
        """Per id: list of signed field deltas vs base (or vs prediction)."""
        out = []
        for i in ids:
            cur, b = f.rows[i], (pred[i] if pred is not None else base.rows[i])
            out.append([wrap(cur[k] - b[k], self.bits[k]) for k in range(self.nf)])
        return out

    def predict(self, frames, idx, age):
        """Guarded linear extrapolation (Unity Netcode GhostDeltaPredictor), per field.

        Uses baselines b0 = idx-age, b1 = idx-2age, b2 = idx-3age. Only for q/a fields;
        other fields predict 'unchanged'. Falls back to b0 where history is missing.
        """
        if idx - 3 * age < 0:
            return None
        b0, b1, b2 = frames[idx - age], frames[idx - 2 * age], frames[idx - 3 * age]
        pred = {}
        for i, r0 in b0.rows.items():
            r1, r2 = b1.rows.get(i), b2.rows.get(i)
            if r1 is None or r2 is None:
                pred[i] = r0
                continue
            p = list(r0)
            for k in range(self.nf):
                if self.kinds[k] not in ("q", "a"):
                    continue
                bits = self.bits[k]
                d01 = wrap(r0[k] - r1[k], bits)
                d12 = wrap(r1[k] - r2[k], bits)
                predicted_b0 = r1[k] + d12
                if abs(wrap(r0[k] - predicted_b0, bits)) >= abs(d01):
                    continue  # predictor failed last time: use b0
                p[k] = (r0[k] + d01) % (1 << bits)
            pred[i] = tuple(p)
        return pred

    # ----- absolute layouts ---------------------------------------------
    def abs_row_f32(self, frames, idx, age):
        f = frames[idx]
        out = bytearray()
        leb128(len(f.rows), out)
        ff = set(self.float_fields)
        for i in sorted(f.rows):
            out += i.to_bytes(self.id_bytes, "little")
            for v in f.floats[i]:
                out += struct.pack("<f", v)
            row = f.rows[i]
            for k in self.byte_idx:
                if self.schema[k][0] in ff or self.schema[k][0] in ("qi", "qa", "qb", "qc"):
                    continue
                out += row[k].to_bytes(fbytes(self.bits[k]), "little")
            if self.bool_idx:
                v = 0
                for j, k in enumerate(self.bool_idx):
                    v |= row[k] << j
                out += v.to_bytes(fbytes(len(self.bool_idx)), "little")
        self.aligned_events(f, out)
        return bytes(out)

    def abs_row_aligned(self, frames, idx, age):
        f = frames[idx]
        out = bytearray()
        leb128(len(f.rows), out)
        for i in sorted(f.rows):
            out += i.to_bytes(self.id_bytes, "little")
            self.aligned_row(f.rows[i], out)
        self.aligned_events(f, out)
        return bytes(out)

    def abs_row_bits(self, frames, idx, age):
        f = frames[idx]
        bw = BitWriter()
        exp_golomb(bw, len(f.rows), 0)
        for i in sorted(f.rows):
            bw.w(i, self.id_bits)
            self.bits_row(f.rows[i], bw)
        self.bits_events(f, bw)
        return bw.done()

    def _cols(self, f, ids):
        return [[f.rows[i][k] for i in ids] for k in range(self.nf)]

    def abs_col_aligned(self, frames, idx, age, split=False):
        f = frames[idx]
        ids = sorted(f.rows)
        out = bytearray()
        leb128(len(ids), out)
        for i in ids:
            out += i.to_bytes(self.id_bytes, "little")
        cols = self._cols(f, ids)
        for k in self.byte_idx:
            w = fbytes(self.bits[k])
            if split and w > 1:
                for plane in range(w - 1, -1, -1):
                    out += bytes((v >> (8 * plane)) & 255 for v in cols[k])
            else:
                for v in cols[k]:
                    out += v.to_bytes(w, "little")
        if self.bool_idx:
            bw = BitWriter()
            for j in range(len(ids)):
                for k in self.bool_idx:
                    bw.w(cols[k][j], 1)
            out += bw.done()
        self.aligned_events(f, out)
        return bytes(out)

    def abs_col_split(self, frames, idx, age):
        return self.abs_col_aligned(frames, idx, age, split=True)

    # ----- XOR vs previous buffer (Warp) --------------------------------
    def _xor(self, frames, idx, age, inner):
        cur = inner(frames, idx, age)
        if idx - age < 0:
            return b"\x00" + cur
        prev = inner(frames, idx - age, age)
        x = bytes(c ^ (prev[j] if j < len(prev) else 0) for j, c in enumerate(cur))
        return b"\x01" + x

    def xor_row_aligned(self, frames, idx, age):
        return self._xor(frames, idx, age, self.abs_row_aligned)

    def xor_col_split(self, frames, idx, age):
        return self._xor(frames, idx, age, self.abs_col_split)

    # ----- byte-aligned deltas -----------------------------------------
    def _delta_common(self, frames, idx, age):
        f = frames[idx]
        if idx - age < 0:
            return f, None, None, None
        base = frames[idx - age]
        out = bytearray()
        ids = self.set_changes_aligned(f, base, out)
        return f, base, ids, out

    def dlt_row_fixed(self, frames, idx, age):
        f, base, ids, out = self._delta_common(frames, idx, age)
        if base is None:
            return self.abs_row_aligned(frames, idx, age)
        for d in self.deltas(f, base, ids):
            for k in self.byte_idx:
                w = fbytes(self.bits[k])
                out += (d[k] % (1 << (8 * w))).to_bytes(w, "little")
            if self.bool_idx:
                v = 0
                for j, k in enumerate(self.bool_idx):
                    v |= (d[k] & 1) << j
                out += v.to_bytes(fbytes(len(self.bool_idx)), "little")
        self.aligned_events(f, out)
        return bytes(out)

    def dlt_col_fixed(self, frames, idx, age, split=False):
        f, base, ids, out = self._delta_common(frames, idx, age)
        if base is None:
            return self.abs_col_aligned(frames, idx, age, split)
        ds = self.deltas(f, base, ids)
        for k in self.byte_idx:
            w = fbytes(self.bits[k])
            col = [d[k] % (1 << (8 * w)) for d in ds]
            if split and w > 1:
                for plane in range(w - 1, -1, -1):
                    out += bytes((v >> (8 * plane)) & 255 for v in col)
            else:
                for v in col:
                    out += v.to_bytes(w, "little")
        if self.bool_idx:
            bw = BitWriter()
            for d in ds:
                for k in self.bool_idx:
                    bw.w(d[k] & 1, 1)
            out += bw.done()
        self.aligned_events(f, out)
        return bytes(out)

    def dlt_col_split(self, frames, idx, age):
        return self.dlt_col_fixed(frames, idx, age, split=True)

    def dlt_row_varint(self, frames, idx, age):
        f, base, ids, out = self._delta_common(frames, idx, age)
        if base is None:
            return self.abs_row_aligned(frames, idx, age)
        for d in self.deltas(f, base, ids):
            for k in self.byte_idx:
                leb128(zz(d[k]), out)
            if self.bool_idx:
                v = 0
                for j, k in enumerate(self.bool_idx):
                    v |= (d[k] & 1) << j
                out.append(v)
        self.aligned_events(f, out)
        return bytes(out)

    def dlt_col_varint(self, frames, idx, age):
        f, base, ids, out = self._delta_common(frames, idx, age)
        if base is None:
            return self.abs_col_aligned(frames, idx, age)
        ds = self.deltas(f, base, ids)
        for k in self.byte_idx:
            for d in ds:
                leb128(zz(d[k]), out)
        if self.bool_idx:
            bw = BitWriter()
            for d in ds:
                for k in self.bool_idx:
                    bw.w(d[k] & 1, 1)
            out += bw.done()
        self.aligned_events(f, out)
        return bytes(out)

    # ----- hybrid: bit-packed masks + byte-aligned changed values -------
    def _hybrid(self, frames, idx, age, mode, pred=False):
        f, base, ids, out = self._delta_common(frames, idx, age)
        if base is None:
            return self.abs_col_aligned(frames, idx, age)
        p = self.predict(frames, idx, age) if pred else None
        ds_base = self.deltas(f, base, ids)
        ds = self.deltas(f, base, ids, p) if p is not None else ds_base
        # masks: one bit per entity "changed vs baseline", then per changed entity a
        # per-field bit for non-bool fields (bools travel as a raw bit row instead).
        bw = BitWriter()
        changed = []
        for j, d in enumerate(ds_base):
            ch = any(d)
            bw.w(int(ch), 1)
            if ch:
                changed.append(j)
        fm = {}
        for j in changed:
            for k in self.byte_idx:
                c = ds_base[j][k] != 0 or (p is not None and ds[j][k] != 0)
                fm[(j, k)] = c
                bw.w(int(c), 1)
            for k in self.bool_idx:
                bw.w(f.rows[ids[j]][k], 1)
        out += bw.done()
        for k in self.byte_idx:
            col = [ds[j][k] for j in changed if fm[(j, k)]]
            if mode == "varint":
                for v in col:
                    leb128(zz(v), out)
            else:  # fixed width zigzag + byte planes
                w = fbytes(self.bits[k] + 1)
                vals = [zz(v) for v in col]
                if w > 1:
                    for plane in range(w - 1, -1, -1):
                        out += bytes((v >> (8 * plane)) & 255 for v in vals)
                else:
                    out += bytes(vals)
        self.aligned_events(f, out)
        return bytes(out)

    def hyb_mask_varint(self, frames, idx, age):
        return self._hybrid(frames, idx, age, "varint")

    def hyb_mask_split(self, frames, idx, age):
        return self._hybrid(frames, idx, age, "split")

    def hyb_pred_varint(self, frames, idx, age):
        return self._hybrid(frames, idx, age, "varint", pred=True)

    # ----- fully bit-packed deltas --------------------------------------
    def _bits_common(self, frames, idx, age):
        f = frames[idx]
        if idx - age < 0:
            return f, None, None, None
        base = frames[idx - age]
        bw = BitWriter()
        ids = self.set_changes_bits(f, base, bw)
        return f, base, ids, bw

    def dlt_bits_mask(self, frames, idx, age):
        """Gaffer-style: entity changed bit, per-field changed bit, small/large/absolute value."""
        f, base, ids, bw = self._bits_common(frames, idx, age)
        if base is None:
            return self.abs_row_bits(frames, idx, age)
        for i, d in zip(ids, self.deltas(f, base, ids)):
            if not any(d):
                bw.w(0, 1)
                continue
            bw.w(1, 1)
            for k in range(self.nf):
                b = self.bits[k]
                if b <= 4:
                    bw.w(f.rows[i][k], b)  # tiny fields: just resend
                    continue
                if d[k] == 0:
                    bw.w(0, 1)
                    continue
                bw.w(1, 1)
                v = d[k]
                if -16 <= v < 16:
                    bw.w(0, 1)
                    bw.w(v + 16, 5)
                elif -256 <= v < 256 and b > 9:
                    bw.w(2, 2)
                    bw.w(v + 256, 9)
                else:
                    bw.w(3, 2)
                    bw.w(f.rows[i][k], b)
        self.bits_events(f, bw)
        return bw.done()

    def dlt_bits_class(self, frames, idx, age):
        """The v5 attempt: changed bit, field mask, 4-bit class code of zigzag delta."""
        f, base, ids, bw = self._bits_common(frames, idx, age)
        if base is None:
            return self.abs_row_bits(frames, idx, age)
        for i, d in zip(ids, self.deltas(f, base, ids)):
            if not any(d):
                bw.w(0, 1)
                continue
            bw.w(1, 1)
            for k in range(self.nf):
                if self.kinds[k] == "b":
                    bw.w(f.rows[i][k], 1)
                    continue
                bw.w(int(d[k] != 0), 1)
                if d[k]:
                    class_code(bw, zz(d[k]) - 1)
        self.bits_events(f, bw)
        return bw.done()

    def dlt_bits_eg(self, frames, idx, age, ks=None):
        """Changed bit + field mask + Exp-Golomb order k per field (k trained offline)."""
        f, base, ids, bw = self._bits_common(frames, idx, age)
        if base is None:
            return self.abs_row_bits(frames, idx, age)
        ks = ks or self.eg_k
        for i, d in zip(ids, self.deltas(f, base, ids)):
            if not any(d):
                bw.w(0, 1)
                continue
            bw.w(1, 1)
            for k in range(self.nf):
                if self.kinds[k] == "b":
                    bw.w(f.rows[i][k], 1)
                    continue
                bw.w(int(d[k] != 0), 1)
                if d[k]:
                    exp_golomb(bw, zz(d[k]) - 1, ks[k])
        self.bits_events(f, bw)
        return bw.done()

    def train_eg(self, frames, age):
        """Choose the Exp-Golomb k per field that minimises bits on a training run."""
        best = []
        samples = [[] for _ in range(self.nf)]
        for idx in range(age, len(frames)):
            f, base = frames[idx], frames[idx - age]
            ids = [i for i in sorted(f.rows) if i in base.rows]
            for d in self.deltas(f, base, ids):
                for k in range(self.nf):
                    if d[k]:
                        samples[k].append(zz(d[k]) - 1)
        for k in range(self.nf):
            s = samples[k]
            if not s:
                best.append(0)
                continue
            costs = []
            for kk in range(0, 20):
                c = 0
                for v in s:
                    c += 2 * ((v + (1 << kk)).bit_length()) - 1 - kk
                costs.append(c)
            best.append(min(range(20), key=lambda kk: costs[kk]))
        self.eg_k = best

    def col_bits_adapt(self, frames, idx, age, pred=False):
        """Column coder with per-column mode (the v5 attempt's idea, simplified).

        Per non-bool field, over all persisting entities in id order, the encoder
        picks the cheapest of: 0 all-zero; 1 EG-k of zigzag delta for every entity
        (k in 4 bits); 2 sparse: EG-0 gap to next non-zero + EG-k value; 3 absolute
        raw bits. Bools travel as a raw bit row. No per-entity or per-field masks.
        """
        f, base, ids, bw = self._bits_common(frames, idx, age)
        if base is None:
            return self.abs_row_bits(frames, idx, age)
        p = self.predict(frames, idx, age) if pred else None
        ds = self.deltas(f, base, ids, p) if p is not None else self.deltas(f, base, ids)
        for k in range(self.nf):
            if self.kinds[k] == "b":
                for i in ids:
                    bw.w(f.rows[i][k], 1)
                continue
            col = [zz(d[k]) for d in ds]
            if not any(col):
                bw.w(0, 2)
                continue
            def eg_bits(v, kk):
                return 2 * ((v + (1 << kk)).bit_length()) - 1 - kk
            best = None
            for kk in range(16):
                c = sum(eg_bits(v, kk) for v in col)
                if best is None or c < best[0]:
                    best = (c, 1, kk)
                nz = [(j, v) for j, v in enumerate(col) if v]
                c2, last = 0, -1
                for j, v in nz:
                    c2 += eg_bits(j - last - 1, 0) + eg_bits(v - 1, kk)
                    last = j
                c2 += eg_bits(len(nz), 0)
                if c2 < best[0]:
                    best = (c2, 2, kk)
            if len(col) * self.bits[k] < best[0]:
                best = (len(col) * self.bits[k], 3, 0)
            _, mode, kk = best
            bw.w(mode, 2)
            if mode == 1:
                bw.w(kk, 4)
                for v in col:
                    exp_golomb(bw, v, kk)
            elif mode == 2:
                bw.w(kk, 4)
                nz = [(j, v) for j, v in enumerate(col) if v]
                exp_golomb(bw, len(nz), 0)
                last = -1
                for j, v in nz:
                    exp_golomb(bw, j - last - 1, 0)
                    exp_golomb(bw, v - 1, kk)
                    last = j
            else:
                for i in ids:
                    bw.w(f.rows[i][k], self.bits[k])
        self.bits_events(f, bw)
        return bw.done()

    def col_bits_pred(self, frames, idx, age):
        return self.col_bits_adapt(frames, idx, age, pred=True)


    def col_bytes_adapt(self, frames, idx, age, pred=True, split=False):
        """Byte-aligned analogue of the column coder: per column a width byte
        (0 = all zero, else 1..5 bytes of zigzag residual for every entity).
        Bools travel as a bit row. Cheap to decode: one fixed-width read per value."""
        f, base, ids, out = self._delta_common(frames, idx, age)
        if base is None:
            return self.abs_col_aligned(frames, idx, age)
        p = self.predict(frames, idx, age) if pred else None
        ds = self.deltas(f, base, ids, p) if p is not None else self.deltas(f, base, ids)
        for k in self.byte_idx:
            col = [zz(d[k]) for d in ds]
            m = max(col) if col else 0
            w = 0 if m == 0 else (m.bit_length() + 7) // 8
            out.append(w)
            if split and w > 1:
                for plane in range(w - 1, -1, -1):
                    out += bytes((v >> (8 * plane)) & 255 for v in col)
            else:
                for v in col:
                    out += v.to_bytes(w, "little") if w else b""
        if self.bool_idx:
            bw = BitWriter()
            for i in ids:
                for k in self.bool_idx:
                    bw.w(f.rows[i][k], 1)
            out += bw.done()
        self.aligned_events(f, out)
        return bytes(out)

    def col_bytes_split(self, frames, idx, age):
        return self.col_bytes_adapt(frames, idx, age, split=True)


ABSOLUTE = ["abs_row_f32", "abs_row_aligned", "abs_row_bits", "abs_col_aligned", "abs_col_split"]
DELTA = ["xor_row_aligned", "xor_col_split", "dlt_row_fixed", "dlt_col_fixed", "dlt_col_split",
         "dlt_row_varint", "dlt_col_varint", "hyb_mask_varint", "hyb_mask_split", "hyb_pred_varint",
         "dlt_bits_mask", "dlt_bits_class", "dlt_bits_eg", "col_bits_adapt", "col_bits_pred", "col_bytes_adapt", "col_bytes_split"]
