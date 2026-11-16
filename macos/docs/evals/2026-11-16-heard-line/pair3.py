import json, sys, collections
def load(path):
    d = json.load(open(path)); out = collections.defaultdict(dict)
    for run in d["runs"]:
        for s in run["scores"]:
            ok = all(c["outcome"] != "fail" for c in s["checks"] if c["name"] != "responsive")
            out[run["brainID"]].setdefault(s["fixtureID"], []).append(ok)
    return out
prefix = sys.argv[1]
arms = {a: load(f"{prefix}-{a}.json") for a in ("off", "on", "v2")}
for brain in arms["off"]:
    print(f"\n== {brain}   (passes of 2: off / v1 / v2)")
    groups = collections.defaultdict(lambda: collections.Counter())
    for f in sorted(arms["off"][brain]):
        r = {a: sum(arms[a][brain].get(f, [])) for a in arms}
        g = "guard" if "guard" in f else "holdout" if "holdout" in f else "idiom" if "idiom" in f else "garble"
        for a in r: groups[g][a] += r[a]
        flag = "" if r["off"] == r["on"] == r["v2"] else "  *"
        print(f"  {f:28} {r['off']} / {r['on']} / {r['v2']}{flag}")
    for g, c in groups.items():
        print(f"  [{g}] off {c['off']}  v1 {c['on']}  v2 {c['v2']}")
    for a in ("on", "v2"):
        gain = sum(max(0, sum(arms[a][brain][f]) - sum(arms["off"][brain][f])) for f in arms["off"][brain])
        loss = sum(max(0, sum(arms["off"][brain][f]) - sum(arms[a][brain][f])) for f in arms["off"][brain])
        print(f"  {a} vs off: +{gain} -{loss}")
