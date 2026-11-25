#!/usr/bin/env -S uv run --quiet --script
# /// script
# dependencies = ["pillow"]
# ///
"""Pre-upload spec check. Catches the silent rejections.

    python3 verify.py out/ios/en-US  --target ios
    python3 verify.py out/ipad/en-US --target ipad
    python3 verify.py out/mac/en-US  --target mac
    python3 verify.py --video preview.mov            # App Preview: size, duration, audio track
    python3 verify.py --text ../ios-launch/metadata/en-US   # name/subtitle/keywords/promo limits
    python3 verify.py out/ios/en-US --target ios --plates plates/ios   # also flag placeholder plates
    ./verify.py out/mac/en-US --target mac --approve   # after checking the contact sheet BY EYE

Plate drift: render.js writes out/<target>/<locale>/.plates.json (frame → the plates it read).
Every run fails a frame whose plate changed since the last --approve, or was never approved,
because a hand-tuned crop (focus, bands, lifts) is only right for the capture it was cut on.
2026-11-24: the 1.6 Settings panes moved under two Mac crops and "spec OK" passed both.
--approve stamps plates.lock.json with the plates this set reads. Run it only after looking.

Exit 1 on any failure. Requires Pillow (uv supplies it); ffprobe for --video.
"""
import argparse
import glob
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PLATES_ROOT = os.path.join(HERE, "plates")
LOCK = os.path.join(HERE, "plates.lock.json")

# Apple spec, Sept 2026 (App Store Connect → screenshot specifications).
TARGETS = {
    "ios":  [(1320, 2868), (2868, 1320), (1290, 2796), (2796, 1290), (1260, 2736), (2736, 1260)],  # 6.9"
    "ipad": [(2064, 2752), (2752, 2064), (2048, 2732), (2732, 2048)],                               # 13"
    "duo": [(2007, 2853), (2853, 2007)],                                                            # iPhone Duo inner
    "duo-outer": [(1398, 2034), (2034, 1398)],                                                      # iPhone Duo outer
    "mac":  [(2880, 1800), (2560, 1600), (1440, 900), (1280, 800)],                                 # 16:10
}
# App Preview sizes, from Apple's spec page (re-checked 2026-10-02): Mac previews are
# 1920x1080 landscape ONLY. The old 2880x1800 / 1920x1200 entries would pass files ASC rejects.
VIDEO = {"ios": [(886, 1920), (1920, 886)], "ipad": [(1200, 1600), (1600, 1200)], "mac": [(1920, 1080)],
         "min_s": 15.0, "max_s": 30.0, "max_bytes": 500 * 1024 * 1024}
TEXT = {"name": 30, "subtitle": 30, "keywords": 100, "promotional_text": 170, "description": 4000, "release_notes": 4000}
MAX_PER_LOCALE = 10

fails, warns = [], []


def screenshots(root, target, plates):
    from PIL import Image
    files = sorted(glob.glob(os.path.join(root, "*.png")))
    if not files:
        fails.append(f"no PNGs under {root}"); return
    if len(files) > MAX_PER_LOCALE:
        fails.append(f"{len(files)} screenshots — Apple allows {MAX_PER_LOCALE} per locale")
    for f in files:
        im = Image.open(f); rel = os.path.basename(f)
        if im.size not in TARGETS[target]:
            fails.append(f"{rel}: {im.size[0]}×{im.size[1]} not valid for {target}")
        if "A" in im.mode or im.mode == "P":
            fails.append(f"{rel}: mode {im.mode} — alpha/palette. Flatten to RGB (flatten.py)")
        if os.path.getsize(f) > 8 * 1024 * 1024:
            warns.append(f"{rel}: {os.path.getsize(f)/1e6:.1f} MB — fine, but ASC uploads are slow above ~8 MB")
    if plates:
        # A placeholder plate is a black-ish frame with a near-empty histogram tail; cheap heuristic:
        # we just check whether the plate file is still the generated stand-in (marker in tEXt would be
        # nicer, but the filename + size check below is enough to stop a shipping accident).
        for p in sorted(glob.glob(os.path.join(plates, "*.png"))):
            im = Image.open(p).convert("L")
            hist = im.histogram()
            dark = sum(hist[:24]) / (im.size[0] * im.size[1])
            # placeholders.js paints #0a0a0a, so its commonest level is 10; a real capture's black
            # is 0-2. Without this, a thin wireframe on black (the 1.2.1 iPad fox plate, 97.1%
            # near-black) read as a stand-in. (2026-10-22)
            stand_in_bg = 8 <= hist.index(max(hist)) <= 12
            if dark > 0.97 and stand_in_bg:
                fails.append(f"plate {os.path.basename(p)} looks like a placeholder ({dark:.0%} near-black) — drop a real capture in")


def drift(manifest, lock, hashes):
    """Problems for frames whose plates changed since the last look. `manifest`: frame → plate
    ids ("mac/chat.png"); `lock`: plate id → approved hash; `hashes`: plate id → current hash
    (absent when the file is missing)."""
    problems = []
    for frame in sorted(manifest):
        for plate in manifest[frame]:
            now = hashes.get(plate)
            if now is None:
                problems.append(f"{frame}: plate {plate} is missing")
            elif plate not in lock:
                problems.append(f"{frame}: plate {plate} was never checked by eye — look, then --approve")
            elif lock[plate] != now:
                problems.append(f"{frame}: plate {plate} changed since its crop was checked — look, then --approve")
    return problems


def approve(manifest, lock, hashes):
    """The lock with this set's plates stamped at their current hashes; other stamps kept."""
    out = dict(lock)
    for plates in manifest.values():
        for plate in plates:
            if plate in hashes:
                out[plate] = hashes[plate]
    return dict(sorted(out.items()))


def check_drift(root, approve_now):
    """Read root/.plates.json and the lock; stamp it when approve_now. Returns the problems."""
    path = os.path.join(root, ".plates.json")
    if not os.path.exists(path):
        return [f"{path} missing — render the set with render.js first"]
    manifest = json.load(open(path, encoding="utf-8"))
    hashes = {}
    for plate in {p for plates in manifest.values() for p in plates}:
        f = os.path.join(PLATES_ROOT, plate)
        if os.path.exists(f):
            hashes[plate] = hashlib.sha256(open(f, "rb").read()).hexdigest()[:16]
    lock = json.load(open(LOCK, encoding="utf-8")) if os.path.exists(LOCK) else {}
    if approve_now:
        lock = approve(manifest, lock, hashes)
        with open(LOCK, "w", encoding="utf-8") as fh:
            json.dump(lock, fh, indent=1)
            fh.write("\n")
    return drift(manifest, lock, hashes)


def video(path, target):
    if not os.path.exists(path):
        fails.append(f"{path}: not found"); return
    try:
        out = subprocess.check_output(["ffprobe", "-v", "error", "-show_entries",
                                       "stream=codec_type,width,height:format=duration", "-of", "json", path])
    except (OSError, subprocess.CalledProcessError) as e:
        fails.append(f"ffprobe failed: {e}"); return
    import json
    j = json.loads(out)
    streams = j.get("streams", [])
    v = [s for s in streams if s.get("codec_type") == "video"]
    a = [s for s in streams if s.get("codec_type") == "audio"]
    if not v: fails.append(f"{path}: no video stream")
    else:
        size = (v[0]["width"], v[0]["height"])
        if size not in VIDEO[target]:
            fails.append(f"{path}: {size[0]}×{size[1]} not an accepted {target} App Preview size {VIDEO[target]}")
    if not a:
        fails.append(f"{path}: no audio track — Apple rejects video-only App Previews (add silent AAC)")
    d = float(j["format"]["duration"])
    if not (VIDEO["min_s"] <= d <= VIDEO["max_s"]):
        fails.append(f"{path}: {d:.1f}s — must be 15–30s")
    if os.path.getsize(path) > VIDEO["max_bytes"]:
        fails.append(f"{path}: over 500 MB")


def text(d):
    for k, lim in TEXT.items():
        f = os.path.join(d, f"{k}.txt")
        if not os.path.exists(f): continue
        s = open(f, encoding="utf-8").read().rstrip("\n")
        n = len(s)
        (fails if n > lim else warns if n > lim * 0.95 else []).append(f"{k}.txt: {n}/{lim} chars")
        if k == "keywords" and ", " in s:
            warns.append("keywords.txt: has spaces after commas — Apple counts them; use 'a,b,c'")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?")
    ap.add_argument("--target", choices=TARGETS.keys(), default="ios")
    ap.add_argument("--plates")
    ap.add_argument("--video")
    ap.add_argument("--text")
    ap.add_argument("--approve", action="store_true", help="stamp plates.lock.json after checking the set by eye")
    a = ap.parse_args()
    if a.root:
        screenshots(a.root, a.target, a.plates)
        fails.extend(check_drift(a.root, a.approve))
    if a.video: video(a.video, a.target)
    if a.text: text(a.text)
    for w in warns: print(f"  ~ {w}")
    for f in fails: print(f"  ✘ {f}")
    print("✔ spec OK" if not fails else f"✘ {len(fails)} problem(s)")
    sys.exit(1 if fails else 0)
