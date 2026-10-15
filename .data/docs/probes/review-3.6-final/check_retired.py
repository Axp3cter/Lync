#!/usr/bin/env python3
"""Find names the rename tables retired or renamed that still appear in the five design files.

Usage: python3 -I check_retired.py <docs-dir>
Old names come from the first column of every table in reviews/v5-3.6-naming.md §2–§10 whose "New" column differs
from "keep", and from the renames of design/v5-3.6-open-naming.md (D1, D2, D5, D6, D10, D15, N2–N4, N6).
Each hit is printed with file, line and the line's text, so a reader can tell a stale name from a deliberate
mention (wire grammar fields, prose).
"""
import os
import re
import sys

FILES = ["v5.md", "v5-integrity.md", "v5-collections.md", "v5-checks.md", "v5-tooling.md"]
TICK = re.compile(r"`([^`]+)`")

EXTRA = {  # open-naming renames: old -> new
    "raysPerAxis": "samplesPerAxis", "pvs.raysPerAxis": "pvs.samplesPerAxis",
    "check.freeFormCodes": "check.minFreeFormCodes", "freeFormCodes": "minFreeFormCodes",
    "Stream": "RingCopy", "ms": "clockMilliseconds", "key": "frameKey (telemetry only)", "n": "count (atom)",
    "dt": "sinceTriggerSeconds", "stringEntries": "stringTableEntries", "stringEntriesHeld": "stringTableEntries",
    "stringBytes": "stringTableBytes", "stringDefinitions": "stringDefinitionsSent",
    "stringLiteralsHeld": "joinHoldLiteralsEncoded", "inbound.elements": "inbound.decodeUnits",
    "inboundElementsExceeded": "inboundDecodeUnitsExceeded", "joinHoldElementsExceeded": "joinHoldDecodeUnitsExceeded",
    "report.checkOwnTables": "report.runSelfCheck", "canaryValueRefused": "canaryFormatResultRefused",
    "decoyBehaviourRaised": "decoyBehaviorRaised", "decoyBehaviourYielded": "decoyBehaviorYielded",
    "depth": "depthTicks (option)", "maxMessageUnits": "worstCaseDecodeUnits",
    "maxUnreliableInstances": "worstCaseUnreliableInstances", "schemaMismatch": "buildMismatch / mismatchReceived",
    "layoutDiffers": "layoutMismatch", "unitsReceived": "decodeUnitsReceived", "joinHoldUnits": "joinHoldDecodeUnits",
    "heldUnits": "joinHoldDecodeUnits", "bucketUnits": "bucketDecodeUnits", "units": "decodeUnits",
    "limit.slack": "limit.slackSeconds", "state.budget": "state.bytesPerSecond", "state.rate": "state.ticksPerSecond",
    "runtime": "foundAtRunTime", "frameNoise": "frameNoiseFraction", "Lync.perceived": "Lync.perception",
    "perceived": "ackEveryFrame / Lync.perception", "held": "heldKeys / ackHeldSeconds", "round": "asDecoded",
    "answers": "challengeAnswer", "onReceive": "receive", "AtomLayout": "AtomFormat", "layout.": "",
}


def old_names(docs):
    out = {}
    path = os.path.join(docs, "reviews", "v5-3.6-naming.md")
    with open(path, encoding="utf-8") as f:
        lines=f.read().split("\n")
        a=next(i for i,l in enumerate(lines) if l.startswith("## 2. "))
        b=next(i for i,l in enumerate(lines) if l.startswith("## 11. "))
        for line in lines[a:b]:
            if not line.startswith("| `"):
                continue
            cols = [c.strip() for c in line.split("|")[1:-1]]
            if len(cols) < 3:
                continue
            new = cols[2] if len(cols) >= 4 else cols[1]
            if new.startswith("keep") or new == "New":
                continue
            newnames = set(x.strip() for x in TICK.findall(new))
            for t in TICK.findall(cols[0]):
                t = t.strip()
                if t in newnames: continue
                if re.match(r"^[A-Za-z][A-Za-z0-9.:()]*$", t) and t not in ("Lync.configure",):
                    out.setdefault(t, new[:60])
    out.update({k: v for k, v in EXTRA.items() if v})
    return out


def main():
    docs = sys.argv[1]
    old = old_names(docs)
    # names the tables keep under the same spelling elsewhere, or legitimately reuse (wire grammar fields)
    for fn in FILES:
        with open(os.path.join(docs, "design", fn), encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                for t in TICK.findall(line):
                    t = t.strip()
                    if t in old:
                        print(f"{fn}:{n}\t`{t}` -> {old[t]}\t{line.strip()[:150]}")


if __name__ == "__main__":
    main()
