#!/usr/bin/env python3
"""Extract every backticked identifier from the five v5 design files, with file and section.

Usage: python3 -I extract_names.py <design-dir> <out-dir>
Writes:
  names.tsv      every occurrence: name, file, section, line
  index.tsv      one row per distinct name: name, kind guess, count, file§ list
"""
import os
import re
import sys
from collections import defaultdict

FILES = ["v5.md", "v5-integrity.md", "v5-collections.md", "v5-checks.md", "v5-tooling.md"]
SHORT = {"v5.md": "core", "v5-integrity.md": "integ", "v5-collections.md": "coll",
         "v5-checks.md": "checks", "v5-tooling.md": "tool"}

HEAD = re.compile(r"^(#{2,4})\s+(\d+(?:\.\d+)*)\.?\s")
TICK = re.compile(r"`([^`]+)`")
# an identifier, optionally dotted / with a call or a method prefix
IDENT = re.compile(r"^[:.]?[A-Za-z_][A-Za-z0-9_]*(?:[.:][A-Za-z_][A-Za-z0-9_]*)*(?:\(.*\))?$")

CONDITIONS = ("Missing|Unknown|Duplicate|Mismatch|OutOfRange|OutOfOrder|WrongType|Unsupported|Misplaced|"
              "Exceeded|Malformed|Refused|Unresolved|Unmatched|Unverified|Raised|Yielded|Below[A-Z][a-z]+|"
              "Before[A-Z][a-z]+|Received|Reported|Found|Failed|Shadowed|Indivisible|Empty|Disabled")
CODE_RE = re.compile(r"^[a-z][A-Za-z0-9]*(" + CONDITIONS + r")$")


def sections(path):
    sec = "0"
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            m = HEAD.match(line)
            if m:
                sec = m.group(2)
            yield n, sec, line


def main():
    ddir, odir = sys.argv[1], sys.argv[2]
    occ = []
    for fn in FILES:
        for n, sec, line in sections(os.path.join(ddir, fn)):
            for tok in TICK.findall(line):
                tok = tok.strip()
                if IDENT.match(tok):
                    occ.append((tok, fn, sec, n))
    with open(os.path.join(odir, "names.tsv"), "w") as out:
        for tok, fn, sec, n in occ:
            out.write(f"{tok}\t{fn}\t§{sec}\t{n}\n")
    idx = defaultdict(list)
    for tok, fn, sec, n in occ:
        idx[tok].append(f"{SHORT[fn]}§{sec}")
    with open(os.path.join(odir, "index.tsv"), "w") as out:
        for tok in sorted(idx, key=str.lower):
            locs = sorted(set(idx[tok]))
            kind = "code?" if CODE_RE.match(tok) else ""
            out.write(f"{tok}\t{kind}\t{len(idx[tok])}\t{', '.join(locs)}\n")
    print(len(occ), "occurrences,", len(idx), "distinct")


if __name__ == "__main__":
    main()
