#!/usr/bin/env python3
"""Compare every code-shaped name in the five files with the registry of v5.md §7.1 and v5-tooling.md §3.4.

Usage: python3 -I check_codes.py <design-dir> <index.tsv>
Prints: registry counts per family, code-shaped names used but not registered, registered names never
used elsewhere, names failing the C8 grammar that look like codes, and retired names still present.
"""
import os
import re
import sys

CONDITIONS = ("Missing|Unknown|Duplicate|Mismatch|OutOfRange|OutOfOrder|WrongType|Unsupported|Misplaced|"
              "Exceeded|Malformed|Refused|Unresolved|Unmatched|Unverified|Raised|Yielded|Below[A-Z][a-z]+|"
              "Before[A-Z][a-z]+|Received|Reported|Found|Failed|Shadowed|Indivisible|Empty|Disabled")
CODE_RE = re.compile(r"^[a-z][A-Za-z0-9]*(" + CONDITIONS + r")$")
TICK = re.compile(r"`([A-Za-z][A-Za-z0-9]*)`")


def lines(path):
    with open(path, encoding="utf-8") as f:
        return f.read().split("\n")


def registry(ddir):
    core = lines(os.path.join(ddir, "v5.md"))
    # §7.1 registry block: from "Codes of milestones 1–2" to "Option tables, one set of codes"
    start = next(i for i, l in enumerate(core) if "**Codes of milestones 1–2**" in l)
    end = next(i for i, l in enumerate(core) if "**Option tables, one set of codes.**" in l)
    fam = None
    reg = {}
    for l in core[start:end]:
        s = l.strip()
        m = re.match(r"- (declaration|caller|fact|outcome|fault|internal|facts|outcomes|declarations|callers|faults|build)[ :(]", s)
        if m:
            fam = m.group(1).rstrip("s") if m.group(1) not in ("callers",) else "caller"
            fam = {"fact": "fact", "outcome": "outcome", "declaration": "declaration", "caller": "caller",
                   "fault": "fault", "internal": "internal", "build": "build"}.get(fam, fam)
        for t in TICK.findall(l):
            if fam and (CODE_RE.match(t) or t in ("internal", "timedOut", "limited", "rejected", "unanswered",
                                                   "playerLeft", "serverClosing", "answered", "cancelled",
                                                   "attemptsExceeded", "tickOutOfRange", "ackMissing",
                                                   "recordMissing", "keyUnknown")):
                reg.setdefault(t, fam)
    # §7.3 fact rows (first column)
    s73 = next(i for i, l in enumerate(core) if l.startswith("### 7.3 "))
    e73 = next(i for i, l in enumerate(core) if l.startswith("### 7.4 "))
    for l in core[s73:e73]:
        if l.startswith("| `"):
            first = l.split("|")[1]
            for t in TICK.findall(first):
                reg.setdefault(t, "fact")
    tool = lines(os.path.join(ddir, "v5-tooling.md"))
    s34 = next(i for i, l in enumerate(tool) if l.startswith("### 3.4 "))
    e34 = next(i for i, l in enumerate(tool) if l.startswith("### 3.5 "))
    for l in tool[s34:e34]:
        if l.startswith("| `"):
            t = TICK.findall(l.split("|")[1])
            for x in t:
                reg.setdefault(x, "build")
    return reg


def main():
    ddir, idxp = sys.argv[1], sys.argv[2]
    reg = registry(ddir)
    fams = {}
    for k, v in reg.items():
        fams.setdefault(v, []).append(k)
    for f in sorted(fams):
        print(f"registry {f}: {len(fams[f])}")
    used = {}
    with open(idxp) as f:
        for row in f:
            name, kind, cnt, locs = row.rstrip("\n").split("\t")
            used[name] = locs
    print("\n== code-shaped names used but not in the registry")
    for n in sorted(used):
        if CODE_RE.match(n) and n not in reg:
            print(f"{n}\t{used[n]}")
    print("\n== registered names that fail C8 (outcomes and internal excepted)")
    for n, fam in sorted(reg.items()):
        if fam not in ("outcome", "internal") and not CODE_RE.match(n):
            print(f"{n}\t{fam}")
    print("\n== registered names used only in the registry block")
    for n in sorted(reg):
        locs = used.get(n, "")
        if locs in ("core§7.1", ""):
            print(f"{n}\t{reg[n]}\t{locs or 'not found'}")


if __name__ == "__main__":
    main()
