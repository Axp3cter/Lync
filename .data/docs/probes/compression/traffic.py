"""Traffic models for the Lync v5 compression study.

Four models, each producing one server->client frame per tick for ONE recipient:

  shooter  30 players, recipient sees 29; position, look yaw/pitch, hp, anim, weapon,
           flags; shot events. 20/30/60 Hz.
  tycoon   ~150 slow records per plot (ids, levels, big money counters, progress
           timers) plus purchase/notification events with strings. 10 Hz.
  racing   12 cars, recipient sees 11; position, smallest-three rotation, velocity,
           steer/throttle/brake/rpm/gear/flags. 60 Hz.
  mmo      400 entities in a 1000x1000 area; recipient sees those within 280 studs
           (~70-110); position, yaw, anim, hp; enter/leave by relevancy. 20 Hz.

Motion is random every frame (accelerations, turns, jumps, flicks), never constant.

A Frame has:
  rows   : {entity id: tuple of quantised ints in schema order}
  floats : {entity id: tuple of raw floats (for f32 baselines)}, same order as `float_fields`
  events : list of (event kind, [(value, bits), ...])
  strings: list of (context, string) emitted this frame (for the string study)
  entered, left : ids that entered/left relevancy this frame
"""
import math
import random

# Field spec: (name, kind, bits, extra)
#   kind 'q'  quantised scalar: extra = (lo, step)
#   kind 'a'  wrapping angle in radians: extra = None (bits = resolution)
#   kind 'u'  unsigned int
#   kind 'e'  enum / small int
#   kind 'b'  bool


class Frame:
    __slots__ = ("rows", "floats", "events", "strings", "entered", "left", "t", "changed")

    def __init__(self, t):
        self.t = t
        self.rows = {}
        self.floats = {}
        self.events = []
        self.strings = []
        self.entered = []
        self.left = []
        self.changed = None


def q(v, lo, step, bits):
    x = int(round((v - lo) / step))
    return 0 if x < 0 else (1 << bits) - 1 if x >= (1 << bits) else x


def qa(theta, bits):
    return int(round(theta / (2 * math.pi) * (1 << bits))) & ((1 << bits) - 1)


def smallest_three(qx, qy, qz, qw, bits):
    comps = [qx, qy, qz, qw]
    idx = max(range(4), key=lambda i: abs(comps[i]))
    if comps[idx] < 0:
        comps = [-c for c in comps]
    rest = [comps[i] for i in range(4) if i != idx]
    lim = 1 / math.sqrt(2)
    scale = ((1 << bits) - 1) / (2 * lim)
    return idx, [max(0, min((1 << bits) - 1, int(round((c + lim) * scale)))) for c in rest]


def euler_to_quat(yaw, pitch, roll):
    cy, sy = math.cos(yaw / 2), math.sin(yaw / 2)
    cp, sp = math.cos(pitch / 2), math.sin(pitch / 2)
    cr, sr = math.cos(roll / 2), math.sin(roll / 2)
    # yaw about Y (Roblox up), pitch about X, roll about Z: q = qy * qx * qz
    w = cy * cp * cr + sy * sp * sr
    x = cy * sp * cr + sy * cp * sr
    y = sy * cp * cr - cy * sp * sr
    z = cy * cp * sr - sy * sp * cr
    return x, y, z, w


NAMES = ["Builderman", "xX_Sniper_Xx", "NoobMaster69", "KittyCat2011", "ProGamerTom", "Shadow_Wolf",
         "PizzaLover", "DragonSlayer", "Ninja_Kid", "BloxyQueen", "TurboTaco", "QuietStorm",
         "LuckyClover", "IronFist77", "SkyRunner", "PixelPanda", "MoonWalker", "CaptainCrunch",
         "FrostByte", "LavaLord", "Zippy", "Gl1tch", "MegaMind", "SunnyDay", "RocketRaccoon",
         "BananaBoss", "SilentNight", "CoolCat", "EpicEagle", "TinyTitan"]

ITEMS = ["Sword_of_Flames", "Health_Potion", "Mana_Potion", "Iron_Shield", "Golden_Apple",
         "Wooden_Bow", "Arrow", "Dragon_Scale", "Ancient_Rune", "Teleport_Scroll", "Conveyor",
         "Dropper_T1", "Dropper_T2", "Dropper_T3", "Upgrader", "Furnace", "Wall", "Door",
         "Window", "Lamp", "Rebirth_Token", "Gem", "Coin_Pack_Small", "Coin_Pack_Large"] + \
        [f"Item_{i:03d}" for i in range(176)]

NPC_NAMES = ["Goblin", "Goblin Archer", "Wolf", "Bandit", "Skeleton", "Slime", "Guard",
             "Merchant", "Villager", "Orc Brute", "Spider", "Bat", "Fire Imp", "Golem"]


def zipf_choice(rng, seq, s=1.1):
    w = [1 / (i + 1) ** s for i in range(len(seq))]
    return rng.choices(seq, w)[0]


# ---------------------------------------------------------------------------
# Shooter
# ---------------------------------------------------------------------------

class Shooter:
    name = "shooter"
    # positions: 1/32 stud; x,z in [-1024,1024), y in [-512,1536)
    schema = [
        ("x", "q", 16, (-1024.0, 1 / 32)), ("y", "q", 16, (-512.0, 1 / 32)), ("z", "q", 16, (-1024.0, 1 / 32)),
        ("yaw", "a", 12, None), ("pitch", "q", 8, (-math.pi / 2, math.pi / 255)),
        ("hp", "u", 7, None), ("anim", "e", 3, None), ("weapon", "e", 4, None),
        ("crouch", "b", 1, None), ("sprint", "b", 1, None), ("ads", "b", 1, None), ("reload", "b", 1, None),
    ]
    id_bits = 5
    float_fields = ("x", "y", "z", "yaw", "pitch")

    def __init__(self, hz=60, players=30, seed=1):
        self.rng = random.Random(seed)
        self.dt = 1 / hz
        self.hz = hz
        r = self.rng
        self.p = []
        for i in range(players):
            self.p.append(dict(x=r.uniform(-300, 300), y=r.choice([0.0, 0.0, 12.0, 30.0]), z=r.uniform(-300, 300),
                               ground=0.0, vy=0.0, head=r.uniform(0, 6.283), speed=16.0, mode=1,
                               yaw=r.uniform(0, 6.283), yawv=0.0, pitch=0.0, hp=100, anim=1, weapon=r.randrange(6),
                               crouch=False, sprint=False, ads=False, reload=0.0, firing=False))
        self.t = 0
        self.me = 0

    def step(self):
        r, dt = self.rng, self.dt
        f = Frame(self.t)
        for i, p in enumerate(self.p):
            # movement mode changes ~ every 2 s
            if r.random() < dt * 0.5:
                p["mode"] = r.choices([0, 1, 2], [0.15, 0.55, 0.30])[0]
            p["sprint"] = p["mode"] == 2
            if r.random() < dt * 0.3:
                p["crouch"] = not p["crouch"]
            target = [0.0, 16.0, 24.0][p["mode"]] * (0.5 if p["crouch"] else 1.0)
            p["speed"] += (target - p["speed"]) * min(1, dt * 8) + r.gauss(0, 0.5)
            # heading: strafing jitter every frame plus turns
            p["head"] += r.gauss(0, 2.5) * dt + (r.uniform(-2.5, 2.5) if r.random() < dt * 1.0 else 0)
            p["x"] += math.cos(p["head"]) * p["speed"] * dt
            p["z"] += math.sin(p["head"]) * p["speed"] * dt
            p["x"] = max(-1000, min(1000, p["x"]))
            p["z"] = max(-1000, min(1000, p["z"]))
            # jumping / gravity (Roblox default gravity 196.2, jump power 50)
            if p["y"] <= p["ground"] + 1e-6 and r.random() < dt * 0.4:
                p["vy"] = 50.0
            p["vy"] -= 196.2 * dt
            p["y"] += p["vy"] * dt
            if p["y"] < p["ground"]:
                p["y"], p["vy"] = p["ground"], 0.0
            # aim: noisy tracking plus occasional flicks
            p["yawv"] += r.gauss(0, 6.0) * dt * 10 - p["yawv"] * dt * 4
            if r.random() < dt * 0.4:
                p["yawv"] += r.choice([-1, 1]) * r.uniform(6, 14)
            p["yaw"] = (p["yaw"] + p["yawv"] * dt) % (2 * math.pi)
            p["pitch"] = max(-1.5, min(1.5, p["pitch"] + r.gauss(0, 0.6) * dt * 5))
            p["anim"] = 0 if p["speed"] < 1 else (2 if p["vy"] != 0 else (3 if p["sprint"] else 1))
            p["ads"] = (r.random() < 0.5) if r.random() < dt * 0.7 else p["ads"]
            if r.random() < dt * 0.2:
                p["weapon"] = r.randrange(6)
            if p["reload"] > 0:
                p["reload"] -= dt
            elif r.random() < dt * 0.15:
                p["reload"] = 2.0
            if r.random() < dt * 0.5:
                p["firing"] = r.random() < 0.35
            if r.random() < dt * 0.6:
                p["hp"] = max(0, p["hp"] - r.randrange(5, 40))
            if p["hp"] == 0 and r.random() < dt * 0.3:
                p["hp"] = 100
            # shots: 10 rounds/s while firing
            if p["firing"] and r.random() < 10 * dt:
                tgt = r.randrange(len(self.p)) if r.random() < 0.3 else 31
                ev = [(i, 5), (q(p["x"], -1024, 1 / 32, 16), 16), (q(p["y"] + 4.5, -512, 1 / 32, 16), 16),
                      (q(p["z"], -1024, 1 / 32, 16), 16),
                      (qa(p["yaw"], 12), 12), (q(p["pitch"], -math.pi / 2, math.pi / 255, 8), 8),
                      (tgt, 5), (p["weapon"], 4)]
                f.events.append(("shot", ev))
                if tgt != 31 and r.random() < 0.08:
                    f.events.append(("kill", [(i, 5), (tgt, 5), (p["weapon"], 4)]))
                    f.strings.append(("killfeed", NAMES[i] + " eliminated " + NAMES[tgt]))
            if i == self.me:
                continue
            f.rows[i] = (q(p["x"], -1024, 1 / 32, 16), q(p["y"], -512, 1 / 32, 16), q(p["z"], -1024, 1 / 32, 16),
                         qa(p["yaw"], 12), q(p["pitch"], -math.pi / 2, math.pi / 255, 8), p["hp"], p["anim"],
                         p["weapon"], int(p["crouch"]), int(p["sprint"]), int(p["ads"]), int(p["reload"] > 0))
            f.floats[i] = (p["x"], p["y"], p["z"], p["yaw"], p["pitch"])
        self.t += 1
        return f


# ---------------------------------------------------------------------------
# Tycoon / simulator
# ---------------------------------------------------------------------------

class Tycoon:
    name = "tycoon"
    schema = [
        ("kind", "e", 5, None), ("level", "u", 8, None), ("value", "u", 40, None),
        ("progress", "u", 8, None), ("owner", "e", 3, None), ("active", "b", 1, None), ("boosted", "b", 1, None),
    ]
    id_bits = 10
    float_fields = ("value",)

    def __init__(self, hz=10, records=150, seed=2):
        self.rng = random.Random(seed)
        self.hz = hz
        self.dt = 1 / hz
        r = self.rng
        self.recs = {}
        for i in range(records):
            self._spawn(i)
        self.next_id = records
        self.money = 12_500
        self.t = 0

    def _spawn(self, i):
        r = self.rng
        self.recs[i] = dict(kind=r.randrange(32), level=r.randint(1, 20), value=r.randint(0, 5_000_000),
                            rate=r.choice([0, 0, 1, 5, 25, 100, 1000]), progress=r.randrange(256),
                            pspeed=r.choice([0, 0, 1, 3, 8]), owner=r.randrange(8),
                            active=r.random() < 0.8, boosted=False, label=zipf_choice(r, ITEMS))

    def step(self):
        r = self.rng
        f = Frame(self.t)
        changed = set()
        for i, rec in self.recs.items():
            if rec["active"] and rec["rate"] and r.random() < 0.3:
                rec["value"] += rec["rate"] * rec["level"] * r.randint(1, 3)
                changed.add(i)
            if rec["pspeed"]:
                rec["progress"] = (rec["progress"] + rec["pspeed"]) % 256
                changed.add(i)
            if r.random() < 0.002:
                rec["level"] = min(255, rec["level"] + 1)
                changed.add(i)
                f.strings.append(("notify", f"{rec['label']} upgraded to level {rec['level']}!"))
            if r.random() < 0.003:
                rec["boosted"] = not rec["boosted"]
                changed.add(i)
            if r.random() < 0.001:
                rec["active"] = not rec["active"]
                changed.add(i)
        if r.random() < 0.05:
            i = self.next_id
            self.next_id += 1
            self._spawn(i)
            f.entered.append(i)
            changed.add(i)
            f.strings.append(("label", self.recs[i]["label"]))
        if r.random() < 0.08:
            item = zipf_choice(r, ITEMS)
            price = r.choice([100, 250, 1000, 5000, 25000, 100000])
            self.money = max(0, self.money - price)
            f.events.append(("purchase", [(ITEMS.index(item), 8), (price, 24)]))
            f.strings.append(("purchase", item))
        if r.random() < 0.03:
            who = r.choice(NAMES)
            f.strings.append(("chat", who + ": " + r.choice(["lol", "gg", "anyone trade?", "how do i rebirth",
                                                               "nice base", "brb", "selling Dragon_Scale"])))
        self.money += r.randint(0, 400)
        f.events.append(("money", [(self.money, 40)]))
        for i, rec in self.recs.items():
            f.rows[i] = (rec["kind"], rec["level"], rec["value"], rec["progress"], rec["owner"],
                         int(rec["active"]), int(rec["boosted"]))
            f.floats[i] = (float(rec["value"]),)
        f.changed = changed
        self.t += 1
        return f



# ---------------------------------------------------------------------------
# Racing
# ---------------------------------------------------------------------------

class Racing:
    name = "racing"
    schema = [
        ("x", "q", 19, (-4096.0, 1 / 64)), ("y", "q", 16, (-256.0, 1 / 64)), ("z", "q", 19, (-4096.0, 1 / 64)),
        ("qi", "e", 2, None), ("qa", "u", 10, None), ("qb", "u", 10, None), ("qc", "u", 10, None),
        ("vx", "q", 14, (-512.0, 1 / 16)), ("vy", "q", 14, (-512.0, 1 / 16)), ("vz", "q", 14, (-512.0, 1 / 16)),
        ("steer", "q", 8, (-1.0, 2 / 255)), ("throttle", "u", 8, None), ("brake", "u", 8, None),
        ("rpm", "u", 14, None), ("gear", "e", 3, None), ("boost", "b", 1, None), ("drift", "b", 1, None),
    ]
    id_bits = 4
    float_fields = ("x", "y", "z", "qx", "qy", "qz", "qw", "vx", "vy", "vz")

    def __init__(self, hz=60, cars=12, seed=3):
        self.rng = random.Random(seed)
        self.hz = hz
        self.dt = 1 / hz
        r = self.rng
        self.c = []
        for i in range(cars):
            self.c.append(dict(s=r.uniform(0, 1), speed=r.uniform(80, 120), lane=r.uniform(-12, 12),
                               steer=0.0, throttle=200, brake=0, gear=3, rpm=4000, boost=False, drift=False,
                               bump=0.0, roll=0.0, pitch=0.0, prev=None))
        self.t = 0
        self.L = 6000.0  # track length (studs)

    def track(self, s):
        a = 2 * math.pi * s
        x = 1500 * math.cos(a) + 400 * math.cos(3 * a) + 120 * math.sin(7 * a)
        z = 1100 * math.sin(a) + 300 * math.sin(2 * a)
        y = 30 * math.sin(4 * a) + 8 * math.sin(11 * a)
        return x, y, z

    def step(self):
        r, dt = self.rng, self.dt
        f = Frame(self.t)
        for i, c in enumerate(self.c):
            acc = r.gauss(0, 30) + (40 if c["throttle"] > 128 else -20)
            if r.random() < dt * 0.3:
                c["boost"] = not c["boost"]
            if c["boost"]:
                acc += 60
            c["speed"] = max(30, min(300, c["speed"] + acc * dt))
            c["throttle"] = max(0, min(255, c["throttle"] + int(r.gauss(0, 25))))
            c["brake"] = max(0, min(255, int(c["brake"] * 0.8 + (r.random() < dt * 0.5) * 255)))
            c["lane"] = max(-15, min(15, c["lane"] + r.gauss(0, 6) * dt))
            c["steer"] = max(-1, min(1, c["steer"] * 0.9 + r.gauss(0, 0.15)))
            c["drift"] = abs(c["steer"]) > 0.7
            c["rpm"] = max(800, min(9000, int(c["rpm"] + r.gauss(0, 150))))
            if r.random() < dt * 0.5:
                c["gear"] = max(1, min(6, c["gear"] + r.choice([-1, 1])))
            if r.random() < dt * 0.05:  # collision: speed and lane jolt
                c["speed"] *= 0.6
                c["lane"] += r.uniform(-6, 6)
            c["s"] = (c["s"] + c["speed"] * dt / self.L) % 1.0
            x, y, z = self.track(c["s"])
            x2, y2, z2 = self.track((c["s"] + 1e-4) % 1.0)
            hx, hz_ = x2 - x, z2 - z
            n = math.hypot(hx, hz_)
            hx, hz_ = hx / n, hz_ / n
            x += -hz_ * c["lane"]
            z += hx * c["lane"]
            c["bump"] += r.gauss(0, 2.0) * dt
            c["bump"] *= 0.95
            y += 2.0 + c["bump"]
            yaw = math.atan2(hx, hz_) + c["steer"] * 0.15 * (2 if c["drift"] else 1)
            c["pitch"] = 0.9 * c["pitch"] + r.gauss(0, 0.01) + (y2 - y + 2.0) * 0.0
            c["roll"] = 0.9 * c["roll"] + r.gauss(0, 0.01) + c["steer"] * 0.01
            qx_, qy_, qz_, qw_ = euler_to_quat(yaw, c["pitch"], c["roll"])
            idx, comps = smallest_three(qx_, qy_, qz_, qw_, 10)
            if c["prev"] is None:
                vx = vy = vz = 0.0
            else:
                vx, vy, vz = ((x - c["prev"][0]) / dt, (y - c["prev"][1]) / dt, (z - c["prev"][2]) / dt)
            c["prev"] = (x, y, z)
            if i == 0:
                continue
            f.rows[i] = (q(x, -4096, 1 / 64, 19), q(y, -256, 1 / 64, 16), q(z, -4096, 1 / 64, 19), idx, *comps,
                         q(vx, -512, 1 / 16, 14), q(vy, -512, 1 / 16, 14), q(vz, -512, 1 / 16, 14),
                         q(c["steer"], -1, 2 / 255, 8), c["throttle"], c["brake"], c["rpm"], c["gear"],
                         int(c["boost"]), int(c["drift"]))
            f.floats[i] = (x, y, z, qx_, qy_, qz_, qw_, vx, vy, vz)
        self.t += 1
        return f


# ---------------------------------------------------------------------------
# MMO crowd with relevancy
# ---------------------------------------------------------------------------

class MMO:
    name = "mmo"
    schema = [
        ("x", "q", 18, (-8192.0, 1 / 16)), ("y", "q", 14, (-512.0, 1 / 16)), ("z", "q", 18, (-8192.0, 1 / 16)),
        ("yaw", "a", 8, None), ("anim", "e", 4, None), ("hp", "u", 16, None), ("combat", "b", 1, None),
    ]
    id_bits = 10
    float_fields = ("x", "y", "z", "yaw")

    def __init__(self, hz=20, n=400, radius=280.0, seed=4):
        self.rng = random.Random(seed)
        self.hz = hz
        self.dt = 1 / hz
        self.radius = radius
        r = self.rng
        self.e = []
        for i in range(n):
            kind = r.choices(["idle", "wander", "player"], [0.5, 0.35, 0.15])[0]
            self.e.append(dict(kind=kind, x=r.uniform(-500, 500), y=r.uniform(0, 20), z=r.uniform(-500, 500),
                               head=r.uniform(0, 6.283), speed=0.0, yaw=r.uniform(0, 6.283), anim=0,
                               hp=r.randint(100, 5000), maxhp=0, combat=False,
                               name=r.choice(NAMES) if kind == "player" else r.choice(NPC_NAMES)))
            self.e[-1]["maxhp"] = self.e[-1]["hp"]
        self.me = next(i for i, e in enumerate(self.e) if e["kind"] == "player")
        self.visible = set()
        self.t = 0

    def step(self):
        r, dt = self.rng, self.dt
        f = Frame(self.t)
        for e in self.e:
            k = e["kind"]
            if k == "idle":
                e["speed"] = 0.0
                if r.random() < dt * 0.2:
                    e["yaw"] = (e["yaw"] + r.uniform(-1, 1)) % (2 * math.pi)
            else:
                top = 12.0 if k == "wander" else 24.0
                if r.random() < dt * (0.3 if k == "wander" else 0.8):
                    e["head"] += r.uniform(-2, 2)
                if r.random() < dt * 0.2:
                    e["speed"] = 0.0 if e["speed"] > 0 and r.random() < 0.3 else top * r.uniform(0.6, 1.0)
                e["head"] += r.gauss(0, 1.0) * dt
                e["x"] = max(-500, min(500, e["x"] + math.cos(e["head"]) * e["speed"] * dt))
                e["z"] = max(-500, min(500, e["z"] + math.sin(e["head"]) * e["speed"] * dt))
                e["y"] = max(0.0, e["y"] + r.gauss(0, 0.3) * dt)
                if e["speed"] > 0:
                    e["yaw"] = e["head"] % (2 * math.pi)
            e["anim"] = 0 if e["speed"] == 0 else (1 if e["speed"] < 14 else 2)
            if r.random() < dt * 0.05:
                e["combat"] = not e["combat"]
            if e["combat"] and r.random() < dt * 2:
                e["hp"] = max(0, e["hp"] - r.randint(10, 300))
                if e["hp"] == 0:
                    e["hp"] = e["maxhp"]
        me = self.e[self.me]
        vis = set()
        for i, e in enumerate(self.e):
            if i == self.me:
                continue
            d = math.hypot(e["x"] - me["x"], e["z"] - me["z"])
            if d < self.radius or (i in self.visible and d < self.radius * 1.1):
                vis.add(i)
        f.entered = sorted(vis - self.visible)
        f.left = sorted(self.visible - vis)
        for i in f.entered:
            f.strings.append(("name", self.e[i]["name"]))
        self.visible = vis
        for i in sorted(vis):
            e = self.e[i]
            f.rows[i] = (q(e["x"], -8192, 1 / 16, 18), q(e["y"], -512, 1 / 16, 14), q(e["z"], -8192, 1 / 16, 18),
                         qa(e["yaw"], 8), e["anim"], e["hp"], int(e["combat"]))
            f.floats[i] = (e["x"], e["y"], e["z"], e["yaw"])
        self.t += 1
        return f


MODELS = {"shooter": Shooter, "tycoon": Tycoon, "racing": Racing, "mmo": MMO}


def run(model, frames, **kw):
    m = MODELS[model](**kw)
    return m, [m.step() for _ in range(frames)]


if __name__ == "__main__":
    for name in MODELS:
        m, fs = run(name, 200)
        nrows = sum(len(f.rows) for f in fs) / len(fs)
        nev = sum(len(f.events) for f in fs) / len(fs)
        print(f"{name:8s} hz={m.hz:3d} rows/frame={nrows:6.1f} events/frame={nev:5.2f} "
              f"entered/frame={sum(len(f.entered) for f in fs)/len(fs):.2f}")
