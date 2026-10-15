"""List side-effect-free property reads on always-present client services, by read security.

Candidates for the caller probe's identity member (v5-integrity.md section 4): a read that fails at
game-script identity and succeeds at higher identities. Usage: python3 -I probe_members.py <dump.json>
"""
import json
import sys

dump = json.load(open(sys.argv[1]))
classes = {c["Name"]: c for c in dump["Classes"]}
SERVICES = ["DataModel", "Players", "RunService", "ScriptContext", "Workspace", "UserInputService",
            "StarterGui", "GuiService", "Stats", "LogService", "HttpService"]
for name in SERVICES:
    for m in classes[name]["Members"]:
        if m["MemberType"] != "Property":
            continue
        sec = m.get("Security", {})
        read = sec.get("Read") if isinstance(sec, dict) else sec
        if read and read != "None":
            caps = m.get("Capabilities")
            print(f"{name}.{m['Name']}: read {read}; thread {m.get('ThreadSafety')}; "
                  f"tags {m.get('Tags', [])}; caps {caps}")
