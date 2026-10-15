"""Print members of Roblox API dump classes: kind, signature, security, tags, capabilities, thread safety.

Usage: python3 -I dump_members.py <dump.json> Class[.Member] ...
"""
import json
import sys

dump = json.load(open(sys.argv[1]))
classes = {c["Name"]: c for c in dump["Classes"]}


def describe(cls, m):
    kind = m["MemberType"]
    sec = m.get("Security")
    if isinstance(sec, dict):
        sec = "read " + sec.get("Read", "?") + ", write " + sec.get("Write", "?")
    params = ", ".join(p["Name"] + ": " + p["Type"]["Name"] for p in m.get("Parameters", []))
    ret = m.get("ReturnType") or m.get("ValueType") or {}
    if isinstance(ret, list):
        ret = {"Name": ", ".join(r["Name"] for r in ret)}
    sig = m["Name"] + ("(" + params + ")" if kind in ("Function", "Event", "Callback") else "")
    print(f"{cls}.{sig}: {ret.get('Name', '')} | {kind} | security {sec} | tags {m.get('Tags', [])} "
          f"| caps {m.get('Capabilities', [])} | thread {m.get('ThreadSafety')}")


for arg in sys.argv[2:]:
    name, _, member = arg.partition(".")
    c = classes[name]
    print(f"== {name} < {c.get('Superclass')} tags {c.get('Tags', [])}")
    for m in c["Members"]:
        if not member or m["Name"] == member:
            describe(name, m)
