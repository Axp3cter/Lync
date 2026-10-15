"""Build-time scale test for weave.py: N synthetic client scripts (the fixture Weapon script plus filler game code)
in one dump. Usage: python3 -I buildtime.py FIXTURE_JSON N OUT_JSON"""
import json, sys
fx = json.load(open(sys.argv[1]))
weapon = next(x for x in fx if x["path"].endswith("Weapon"))
filler = "\n".join(f"local function f{k}(x) local t = {{}} for i = 1, x do t[i] = i * {k} end return #t end" for k in range(60))
out = [x for x in fx if not x["path"].endswith("Weapon")]
for i in range(int(sys.argv[2])):
    out.append(dict(weapon, path=f"StarterPlayer.StarterPlayerScripts.Client.Weapon{i}", source=weapon["source"].replace("return {", filler + "\nreturn {")))
json.dump(out, open(sys.argv[3], "w"))
print(sum(len(x["source"]) for x in out), "bytes of source in", len(out), "scripts")
