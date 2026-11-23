#!/usr/bin/env -S uv run --script --managed-python
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""App Store in-app events for the app.m1k3 record — create a DRAFT, list, inspect.

In-app events show on iPhone and iPad only (Apple's own nomination form says
so; the Mac App Store has no event surface). They still matter for a Mac-first
app: the card surfaces in iOS search and on the Today tab, and an approved or
published event can be ATTACHED to a featuring nomination — Apple asks for
that "as early as possible".

  python3 events.py list
  python3 events.py create --spec ../../fastlane/events/waking-up/event.json --art-dir <dir> [--dry-run]
  python3 events.py create --spec ... --art-dir <dir> --event 6811192045 [--dry-run]   # resume a half-built DRAFT
  python3 events.py update --event 6811192045 --spec ... [--dry-run]   # fix a DRAFT in place
  ./events.py next <dir…|--all> [--year N] [--write]   # re-date yearly specs to the app's next look window
  ./events.py check [dir…]                              # every spec against Apple's limits + the app's windows

`next` and `check` touch local files only. A spec with `looks` (SeasonalLook raw values) is a
yearly event; `next` reads the app's own SeasonalLook.swift (compiled beside season_days.swift),
finds the next whole run of days the app wears those looks, and dates the event to it: 10:00Z on
the first day (local midnight in UTC−10) to 10:00Z on the last (local midnight in UTC+14), an hour
short of 31 days when the look runs longer, publishing as many whole days ahead as the spec did
(1 to 14). It prints the diff; `--write` saves it, and `update` is still how App Store Connect hears.
It re-dates, never re-words: copy that names the old day ("From Mar 21") is flagged.

`create` makes the DRAFT and one localization per locale in the spec's
`localizations` table (primary first), uploading the same card + details to
each — the art is textless, so one pair serves every locale. Each slot takes
ONE media: its video (`event-card-1920x1080.mp4` / `event-details-1080x1920.mp4`)
when the art dir has one, else its still; every video is checked against
Apple's table with ffprobe before anything is sent (dry run included). A failure once
the event exists names the DRAFT and the `--event` line that resumes it (a
plain re-run would POST a second event). `create --event <id>` lists the
event's localizations and creates only the missing locales, art and all; a
locale that already exists is skipped and its art is NOT checked.
`update` rewrites a DRAFT's attributes (badge, dates, purpose, deep link) and
every existing localization's copy from the spec's `localizations` table, keeping
the art already uploaded — for the draft that was created with over-cap copy and
a past start date. A locale the draft lacks is created WITHOUT art, so add missing
locales with `create --event` first. Both commands refuse a spec without a
`deepLink` URL: App Store Connect won't add an event for review without one. Neither command submits — submission stays a human click in App Store Connect
(events review in their own queue and LOCK while in review). `--dry-run`
prints every payload and touches nothing.

API gotchas (each one cost real time on the Lexy event, 2026-08-20):
- territorySchedules[].territories must list >= 1 territory EXPLICITLY; there
  is no "all" — every id is fetched from /v1/territories (paginated, ~175).
- appEventScreenshots PATCH takes {uploaded: true} ONLY; sourceFileChecksum
  belongs to appScreenshots and 409s here.
- Copy caps: name <= 30, shortDescription <= 50, longDescription <= 120.
- Media: card 1920x1080 (16:9), details 1080x1920 (9:16). Apple overlays the
  event name on the card — keep text in the art minimal.

Video, from Apple's documented create request (unrun until the first live
`create`): appEventVideoClips takes the same reserve → PUT → {uploaded: true}
steps, with its state under videoDeliveryState. Clips process after the commit,
so a clip that fails later shows only in App Store Connect; a commit that already
says FAILED bails. previewFrameTimeCode is left out because Apple publishes no
format for it; the poster is then Apple's default (assumed — confirm it in ASC's
event preview). Videos autoplay and repeat: make them seamless loops.

Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.8 (a port of the
  proven Lexy script; the M1K3 record's first event is verify-by-run).
Format: MurphySig v0.4 (https://murphysig.dev/spec)
Prior: dyslexia-ai/ios/marketing/tools/events/create_event.py (Kev +
  claude-fable-5, 2026-08-20), ported with a spec file + dry run.
Review: Kev + claude-opus-5.5, 2026-10-11 — `create` posted only the primary
  locale, so an eight-locale spec (halloween) shipped as en-US alone; it now
  creates every locale in the table and uploads the textless art to each, and
  checks every locale's caps first. Confidence 0.75 — the dry run is pinned by
  test; the multi-locale POST loop is verify-by-run (Kev's, via `!`).
Review: Kev + claude-opus-5.5, 2026-10-11 — review fold: a failure after the event
  POST stranded a DRAFT that a re-run duplicated. Every upload bail now names the
  locale and event, the byte PUT's transport errors bail instead of raising, any
  later failure prints the `--event` resume line, and `create --event` creates only
  the missing locales (existing ones skipped, art unchecked: no code here reads a
  localization's screenshots back). `localization_table` no longer needs `copy`
  when the table holds the primary. Confidence 0.75 — the loop and resume are pinned
  against a recorded fake; the live resume is still verify-by-run.
Review: Kev + claude-opus-5.5, 2026-10-12 — a PEP 723 header + exec bit, like submit.py: `./events.py`
  was "permission denied" and `uv run events.py` died on `import requests` the morning Halloween
  went in. Confidence 0.95.
Review: Kev + claude-opus-5-5, 2026-10-14 — event video: each slot uploads its .mp4 when the art
  dir has one (appEventVideoClips), else its .jpg; ffprobe checks every video against Apple's table
  (16:9 / 9:16, 1080p to 4K, 30 or 60 fps, 500 MB, silent or stereo AAC, PCM on the details page)
  before any request, and the dry run names what it would send. `upload_screenshots` is now
  `upload_media`. Review fold: the art dir must exist and only real files count (a dangling
  symlink once passed pre-flight); the size checked is the file's; a variable frame rate is caught
  by the average; a clip whose commit says FAILED bails, and create says clips process after upload.
  Confidence 0.7: the pure half and the upload steps are pinned against fakes; Apple's acceptance
  of the video POST is unrun until Kev's first `create`.
Review: Kev + claude-opus-5-5, 2026-10-14 — the first live `create` worked (eight locales, 16
  clips, all COMPLETE), but App Store Connect wouldn't add the event for review: no deep link.
  `create` and `update` now refuse a spec without a `deepLink` URL before any request; the
  Halloween spec carries m1k3://event/halloween, the scheme the iOS target registers
  (tools/ci/check_store_targets.py pins it). Confidence 0.85.
Review: Kev + claude-opus-5-5, 2026-10-14 — review fold: a non-string deepLink is refused, not an
  AttributeError, and the payload sends the stripped link; `update`'s PATCH carrying the link, and
  its creating a missing locale with no media, are pinned against the fake. Confidence 0.85.
Review: Kev + claude-opus-5-5, 2026-11-23 (Kev: events "as often as possible"; Ramadan and Nowruz drift
  every year and re-dating by hand costs an hour) — `next` and `check`. One source of truth: the dates
  come from the app's SeasonalLook.swift itself, compiled with season_days.swift (about 2 s), so no
  calendar (Umm al-Qura, Persian, Chinese later) or look precedence is restated in Python; a new kind is
  a `looks` line in its spec. SeasonalEventSpecTests is the CI guard (Linux pytest can't compile it).
  Confidence 0.85: the pure half and the CLI are pinned against fakes, the helper by one darwin test.
Review: Kev + claude-opus-5-5, 2026-11-23 (merged with Diwali + Lunar New Year) — `check` skips the two specs
  1.5 served (`SERVED_BY_1_5`): Diwali 2026 sits inside Flight Club 2026 under 1.6's order, but no one runs 1.6
  before it's over. Replaces the UTC+13 carve-out. Confidence 0.8.
"""
from __future__ import annotations

import argparse
import difflib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Collection, Iterator, Mapping
from contextlib import contextmanager
from datetime import date, datetime, time, timedelta, timezone
from fractions import Fraction
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from asc import APP_ID, bail, call, paginate

CARD_FILE = "event-card-1920x1080.jpg"  # EVENT_CARD, 16:9
DETAILS_FILE = "event-details-1080x1920.jpg"  # EVENT_DETAILS_PAGE, 9:16
CARD_VIDEO = "event-card-1920x1080.mp4"
DETAILS_VIDEO = "event-details-1080x1920.mp4"
SLOTS = (("EVENT_CARD", CARD_VIDEO, CARD_FILE), ("EVENT_DETAILS_PAGE", DETAILS_VIDEO, DETAILS_FILE))
# developer.apple.com/help/app-store-connect/reference/in-app-event-media-and-audio-specifications
VIDEO_FRAMES = {"EVENT_CARD": ((1920, 1080), (3840, 2160), (16, 9)),
                "EVENT_DETAILS_PAGE": ((1080, 1920), (2160, 3840), (9, 16))}
VIDEO_FPS = (30, 60)
MAX_MEDIA_BYTES = 500_000_000
AUDIO_RATES = ("44100", "48000")
RESOURCE = {"image": "appEventScreenshots", "video": "appEventVideoClips"}
STATE_KEY = {"image": "assetDeliveryState", "video": "videoDeliveryState"}
COPY_CAPS = (("name", 30), ("shortDescription", 50), ("longDescription", 120))
BADGES = ("CHALLENGE", "COMPETITION", "LIVE_EVENT", "MAJOR_UPDATE", "NEW_SEASON", "PREMIERE", "SPECIAL_EVENT")
PURPOSES = ("APPROPRIATE_FOR_ALL_USERS", "ATTRACT_NEW_USERS", "KEEP_ACTIVE_USERS_INFORMED", "BRING_BACK_LAPSED_USERS")


# --------------------------------------------------------------------------- #
# Pure (unit-pinned)
# --------------------------------------------------------------------------- #


def deep_link_problems(spec: dict[str, Any]) -> list[str]:
    """App Store Connect won't add an event for review without a deep link (2026-10-14): where
    Open on the card lands. Any `scheme://…` URL passes here; check_store_targets.py pins the
    custom scheme to the one the iOS target registers."""
    link = spec.get("deepLink")
    if not isinstance(link, str) or not link.strip():
        return ["no deepLink: App Store Connect won't add an event for review without one"]
    link = link.strip()
    scheme, sep, rest = link.partition("://")
    if not (scheme and sep and rest):
        return [f"deepLink {link!r} is not a URL (scheme://…)"]
    return []


def copy_problems(copy: dict[str, str]) -> list[str]:
    """Every cap the copy breaks, as 'field: n/cap' lines; empty when clean."""
    out = []
    for field, cap in COPY_CAPS:
        n = len(copy.get(field, ""))
        if n == 0:
            out.append(f"{field}: empty")
        elif n > cap:
            out.append(f"{field}: {n}/{cap}")
    return out


def event_payload(spec: dict[str, Any], territories: list[str]) -> dict[str, Any]:
    """The appEvents POST body from a spec file (see fastlane/events/*/event.json)."""
    if spec["badge"] not in BADGES:
        raise ValueError(f"badge {spec['badge']!r} not in {BADGES}")
    if spec["purpose"] not in PURPOSES:
        raise ValueError(f"purpose {spec['purpose']!r} not in {PURPOSES}")
    attrs: dict[str, Any] = {
        "referenceName": spec["referenceName"],
        "badge": spec["badge"],
        "purchaseRequirement": spec.get("purchaseRequirement", "NO_COST_ASSOCIATED"),
        "primaryLocale": spec.get("locale", "en-US"),
        "priority": spec.get("priority", "HIGH"),
        "purpose": spec["purpose"],
        "territorySchedules": [{
            "territories": territories,
            "publishStart": spec["publishStart"],
            "eventStart": spec["eventStart"],
            "eventEnd": spec["eventEnd"],
        }],
    }
    if spec.get("deepLink"):
        attrs["deepLink"] = spec["deepLink"].strip()
    return {"data": {"type": "appEvents", "attributes": attrs,
                     "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}}


def localization_payload(spec: dict[str, Any], event_id: str) -> dict[str, Any]:
    copy = {k: spec["copy"][k] for k, _ in COPY_CAPS}
    return {"data": {"type": "appEventLocalizations",
                     "attributes": {"locale": spec.get("locale", "en-US"), **copy},
                     "relationships": {"appEvent": {"data": {"type": "appEvents", "id": event_id}}}}}


def attributes_patch(spec: dict[str, Any], event_id: str, territories: list[str]) -> dict[str, Any]:
    """The appEvents PATCH body: everything but the app relationship."""
    body = event_payload(spec, territories)["data"]
    return {"data": {"type": "appEvents", "id": event_id, "attributes": body["attributes"]}}


def localization_patch(loc_id: str, copy: dict[str, str]) -> dict[str, Any]:
    return {"data": {"type": "appEventLocalizations", "id": loc_id,
                     "attributes": {k: copy[k] for k, _ in COPY_CAPS}}}


def localization_table(spec: dict[str, Any]) -> dict[str, dict[str, str]]:
    """Every locale's copy, primary first: the spec's `localizations` table, with its one
    `copy` block standing in for the primary when the table lacks it."""
    primary = spec.get("locale", "en-US")
    table = dict(spec.get("localizations") or {})
    copy = table.pop(primary, None) or spec.get("copy")
    if not copy:
        raise ValueError(f"no copy for the primary locale {primary}: add it to `localizations` or give a `copy` block")
    return {primary: copy, **table}


def event_media(names: set[str], where: Path | str = "the art dir") -> list[tuple[str, str, str]]:
    """(file, asset type, kind) per slot: the slot's video when the art dir has one, else
    its still. Apple takes one media per slot and says "consider using video"."""
    out = []
    for slot, video, still in SLOTS:
        if video in names:
            out.append((video, slot, "video"))
        elif still in names:
            out.append((still, slot, "image"))
        else:
            raise SystemExit(f"{slot}: no {video} or {still} in {where}")
    return out


def _fps(rate: str) -> Fraction:
    num, _, den = rate.partition("/")
    return Fraction(int(num), int(den or 1)) if int(den or 1) else Fraction(0)


def video_problems(info: dict[str, Any], slot: str) -> list[str]:
    """Every break of Apple's event video table in an ffprobe JSON (-show_streams -show_format)."""
    streams = info.get("streams", [])
    videos = [s for s in streams if s.get("codec_type") == "video"]
    if len(videos) != 1:
        return [f"{len(videos)} video streams, expected 1"]
    v, out = videos[0], []
    w, h = int(v["width"]), int(v["height"])
    (min_w, min_h), (max_w, max_h), (rw, rh) = VIDEO_FRAMES[slot]
    if w * rh != h * rw:
        out.append(f"{w}x{h} is not {rw}:{rh}")
    if not (min_w <= w <= max_w and min_h <= h <= max_h):
        out.append(f"{w}x{h}: outside {min_w}x{min_h} to {max_w}x{max_h}")
    fps = _fps(v.get("r_frame_rate", "0/1"))
    if fps not in VIDEO_FPS:
        out.append(f"{float(fps):.4g} fps, expected 30 or 60")
    # r_frame_rate is ffmpeg's guess at the base rate; a variable-rate file shows in the average.
    avg = _fps(v.get("avg_frame_rate", "0/1"))
    if avg and fps in VIDEO_FPS and avg not in VIDEO_FPS:
        out.append(f"average {float(avg):.4g} fps, expected 30 or 60")
    if (size := int(info.get("format", {}).get("size", 0))) > MAX_MEDIA_BYTES:
        out.append(f"{size} bytes, over 500 MB")
    audio = [s for s in streams if s.get("codec_type") == "audio"]
    if audio:
        channels = [int(a.get("channels", 0)) for a in audio]
        if channels not in ([2], [1, 1]):
            out.append(f"audio channels {channels}: one stereo track, or two mono tracks (L, R)")
        pcm_ok = slot == "EVENT_DETAILS_PAGE"
        for a in audio:
            codec = a.get("codec_name", "?")
            if not (codec == "aac" or (pcm_ok and codec.startswith("pcm_"))):
                out.append(f"audio codec {codec}: {slot} takes AAC" + (" or PCM" if pcm_ok else ""))
            if str(a.get("sample_rate")) not in AUDIO_RATES:
                out.append(f"audio at {a.get('sample_rate')} Hz, expected 44.1 or 48 kHz")
    return out


def video_summary(info: dict[str, Any]) -> str:
    v = next(s for s in info["streams"] if s.get("codec_type") == "video")
    secs = float(info.get("format", {}).get("duration", 0))
    return f"{v['width']}x{v['height']} {float(_fps(v.get('r_frame_rate', '0/1'))):.4g} fps {secs:.1f} s"


def reserve_payload(kind: str, fname: str, size: int, slot: str, loc_id: str) -> dict[str, Any]:
    """The reserve POST for one media file: appEventScreenshots or appEventVideoClips."""
    return {"data": {"type": RESOURCE[kind],
                     "attributes": {"fileName": fname, "fileSize": size, "appEventAssetType": slot},
                     "relationships": {"appEventLocalization": {"data": {"type": "appEventLocalizations", "id": loc_id}}}}}


def localization_problems(spec: dict[str, Any]) -> list[str]:
    """Cap breaks across the spec's `localizations` table, prefixed by locale."""
    out = []
    for locale, copy in spec.get("localizations", {}).items():
        out += [f"{locale}: {p}" for p in copy_problems(copy)]
    return out


# --------------------------------------------------------------------------- #
# Yearly events: `next` re-dates a spec to the app's next window, `check` holds every spec to the rules
# --------------------------------------------------------------------------- #
# A spec with `looks` (SeasonalLook raw values) is a yearly event. Its dates come from the APP: the
# looks' day map is read off SeasonalLook.swift itself (app_season_days), so nothing here knows a
# calendar. A new kind of event is its spec's `looks` line, plus the look in SeasonalLook.

MACOS = Path(__file__).resolve().parents[2]
EVENTS_DIR = MACOS / "fastlane/events"
# Every app file season_days.swift needs, compiled as-is. SeasonalLook.swift stands alone today;
# if a look ever reads a type from another file (a date table, say), list that file here too.
SEASON_SOURCES = (MACOS / "Sources/M1K3Avatar/SeasonalLook.swift",)
SEASON_HELPER = Path(__file__).resolve().with_name("season_days.swift")
EVENT_HOUR = time(10)                 # 10:00Z: local midnight in UTC−10 (start) and in UTC+14 (end)
MAX_RUN = timedelta(days=31)          # Apple: an event runs at most 31 days
CAP_MARGIN = timedelta(hours=1)       # a capped event ends an hour short of Apple's 31 days
MAX_LEAD = timedelta(days=14)         # Apple: an event publishes at most 14 days before its start
EDGE_ZONES = (("UTC-10", -10), ("UTC+14", 14))

# Built for, and served by, 1.5: before the UTC+14 edge and the 1.6 looks (Diwali 2026 sits inside Flight Club 2026,
# but no one runs 1.6 before it's over). `check` skips them; `next --write` renames them, so a re-dated spec meets
# every rule. Mirrors SeasonalEventSpecTests.servedBy15.
SERVED_BY_1_5 = frozenset({"halloween-2026", "offline-ai-flight-club-2026"})
SCAN_DAYS = 500                       # past the current event: a year, plus the longest look


def _when(stamp: str) -> datetime:
    return datetime.fromisoformat(stamp.replace("Z", "+00:00"))


def _stamp(when: datetime) -> str:
    return when.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _day_count(span: timedelta) -> str:
    return f"{span / timedelta(days=1):g}"


def look_runs(days: Mapping[date, str], lo: date, hi: date, looks: Collection[str]) -> list[tuple[date, date]]:
    """(first, last) of every run of consecutive days in lo..hi whose look is one of `looks`.
    A run that touches lo began before the scan, and one that touches hi may go on past it:
    both are dropped, so every run returned is whole."""
    runs: list[tuple[date, date]] = []
    first: date | None = None
    day = lo
    while day <= hi:
        inside = days.get(day) in looks
        if inside and first is None:
            first = day
        elif not inside and first is not None:
            runs.append((first, day - timedelta(days=1)))
            first = None
        day += timedelta(days=1)
    return [(a, b) for a, b in runs if a != lo]


def next_run(days: Mapping[date, str], lo: date, hi: date, looks: Collection[str],
             year: int | None = None) -> tuple[date, date]:
    """The first whole run, or the first that starts in `year` (2030 holds two Ramadans)."""
    for first, last in look_runs(days, lo, hi, looks):
        if year is None or first.year == year:
            return first, last
    when = f" starting in {year}" if year else ""
    raise SystemExit(f"no whole {'/'.join(sorted(looks))} run{when} between {lo} and {hi}")


def event_window(first: date, last: date) -> tuple[datetime, datetime]:
    """The event for a look worn on local days first..last: it starts at 10:00Z on the first day
    (local midnight in UTC−10) and ends at 10:00Z on the last (local midnight in UTC+14), so from
    UTC−10 to UTC+14 the card is never live on a day the app has no look; past 31 days it stops
    an hour short of Apple's cap."""
    if last <= first:
        raise ValueError(f"a look of one day ({first}) has no instant when every zone is in it")
    start = datetime.combine(first, EVENT_HOUR, tzinfo=timezone.utc)
    end = datetime.combine(last, EVENT_HOUR, tzinfo=timezone.utc)
    return start, min(end, start + MAX_RUN - CAP_MARGIN)


def next_fields(spec: dict[str, Any], first: date, last: date) -> dict[str, str]:
    """The spec's new referenceName and dates for the look's run first..last. The publish lead
    is the spec's own, in whole days, 1 to 14; the year in the name follows the start."""
    start, end = event_window(first, last)
    old_start = _when(spec["eventStart"])
    lead_days = round((old_start - _when(spec["publishStart"])) / timedelta(days=1))
    lead = timedelta(days=min(max(lead_days, 1), MAX_LEAD.days))
    name = re.sub(rf"(?<!\d){old_start.year}(?!\d)", str(start.year), spec["referenceName"])
    return {"referenceName": name, "publishStart": _stamp(start - lead),
            "eventStart": _stamp(start), "eventEnd": _stamp(end)}


def rewrite_dates(text: str, fields: Mapping[str, str]) -> str:
    """`text` with each field's value replaced in place, every other byte kept: the diff a
    re-date leaves is the changed lines and nothing else."""
    for key, value in fields.items():
        pattern = re.compile(rf'("{re.escape(key)}"\s*:\s*)"(?:[^"\\]|\\.)*"')
        found = len(pattern.findall(text))
        if found != 1:
            raise ValueError(f'{key}: expected one "{key}" in the spec, found {found}')
        quoted = json.dumps(value, ensure_ascii=False)
        text = pattern.sub(lambda m, q=quoted: m.group(1) + q, text, count=1)
    return text


def schedule_problems(spec: dict[str, Any]) -> list[str]:
    """Apple's limits for every spec; a yearly one (with `looks`) also keeps the 10:00Z times."""
    publish, start, end = (_when(spec[k]) for k in ("publishStart", "eventStart", "eventEnd"))
    out = []
    if publish >= start:
        out.append("publishStart is not before eventStart")
    elif start - publish > MAX_LEAD:
        out.append(f"publishes {_day_count(start - publish)} days before the start (Apple's limit is 14)")
    if end <= start:
        out.append("eventEnd is not after eventStart")
    elif end - start > MAX_RUN:
        out.append(f"runs {_day_count(end - start)} days (Apple's limit is 31)")
    if spec.get("looks"):
        if start.time() != EVENT_HOUR:
            out.append(f"eventStart {spec['eventStart']}: a yearly event starts at 10:00Z (local midnight in UTC-10)")
        if end.time() > EVENT_HOUR:
            out.append(f"eventEnd {spec['eventEnd']}: a yearly event ends by 10:00Z (local midnight in UTC+14)")
    return out


def coverage_problems(spec: dict[str, Any], days: Mapping[date, str]) -> list[str]:
    """Every local day, in UTC−10 and UTC+14, on which the card is live and the app wears none
    of the spec's looks: the event would show a look the app doesn't have."""
    looks = set(spec["looks"])
    start, end = _when(spec["eventStart"]), _when(spec["eventEnd"])
    out = []
    for zone, hours in EDGE_ZONES:
        offset = timedelta(hours=hours)
        day, last = (start + offset).date(), (end - timedelta(seconds=1) + offset).date()
        while day <= last:
            if (look := days.get(day)) not in looks:
                out.append(f"{zone}: live on {day}, when the app shows {look or 'no look'}")
            day += timedelta(days=1)
    return out


def copy_date_notes(spec: dict[str, Any], new_first: date) -> list[str]:
    """The locales whose copy names the old start's day of the month, when the start moves to
    another day (Nowruz: "From Mar 21" in 2027, Mar 20 in 2028). `next` re-dates, never re-words."""
    old = _when(spec["eventStart"]).date()
    if (old.month, old.day) == (new_first.month, new_first.day):
        return []
    token = re.compile(rf"(?<!\d){old.day}(?!\d)")
    return [locale for locale, copy in localization_table(spec).items()
            if any(token.search(str(v)) for v in copy.values())]


def search_range(spec: dict[str, Any], year: int | None) -> tuple[date, date]:
    """Where `next` looks: after the current event (its run is cut at lo, so never chosen), or
    across `year` with room for a run that crosses into the next one."""
    if year is not None:
        return date(year - 1, 12, 31), date(year + 1, 3, 31)
    lo = _when(spec["eventEnd"]).date()
    return lo, lo + timedelta(days=SCAN_DAYS)


# --------------------------------------------------------------------------- #
# Live
# --------------------------------------------------------------------------- #


def all_territories() -> list[str]:
    return [t["id"] for t in paginate("/v1/territories?limit=200")]


def existing_localizations(event_id: str) -> dict[str, str]:
    """locale -> appEventLocalizations id, for every locale the event already has."""
    return {l["attributes"]["locale"]: l["id"] for l in paginate(f"/v1/appEvents/{event_id}/localizations?limit=50")}


def put_bytes(op: dict[str, Any], blob: bytes) -> dict[str, Any] | None:
    """PUT one upload operation's slice of `blob`. None when it landed, else an error in
    `call`'s `{'_error', '_body'}` shape — a timeout included, never a bare traceback."""
    import requests  # lazy

    headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
    chunk = blob[op["offset"]:op["offset"] + op["length"]]
    try:
        r = requests.request(op["method"], op["url"], headers=headers, data=chunk, timeout=300)
    except requests.RequestException as exc:
        return {"_error": "transport", "_body": str(exc)[:400]}
    return {"_error": r.status_code, "_body": r.text[:400]} if r.status_code >= 400 else None


def probe(path: Path) -> dict[str, Any]:
    """ffprobe's JSON for one file. ffmpeg is required: no video goes up unchecked."""
    exe = shutil.which("ffprobe")
    if not exe:
        raise SystemExit("ffprobe not found: event video is checked before upload (brew install ffmpeg)")
    try:
        r = subprocess.run([exe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
                           capture_output=True, text=True, check=False, timeout=120)
    except subprocess.TimeoutExpired:
        raise SystemExit(f"ffprobe {path.name}: no answer in 120 s") from None
    if r.returncode:
        raise SystemExit(f"ffprobe {path.name}: {r.stderr.strip()[:300]}")
    return json.loads(r.stdout)


def art_names(art_dir: Path) -> set[str]:
    """Real files only: a directory or a dangling symlink never stands in for art."""
    return {p.name for p in art_dir.iterdir() if p.is_file()}


def checked_media(art_dir: Path) -> list[tuple[str, str, str]]:
    """The slot media, with every video probed against Apple's table; refuses on any break,
    before a single request."""
    if not art_dir.is_dir():
        raise SystemExit(f"art dir not found: {art_dir}")
    media = event_media(art_names(art_dir), art_dir)
    problems = []
    for fname, slot, kind in media:
        if kind != "video":
            continue
        path = art_dir / fname
        info = probe(path)
        info.setdefault("format", {})["size"] = str(path.stat().st_size)   # the bytes that go up
        if found := video_problems(info, slot):
            problems += [f"{fname}: {p}" for p in found]
        else:
            print(f"{fname}: {video_summary(info)}")
    if problems:
        raise SystemExit("event video breaks Apple's spec: " + "; ".join(problems))
    return media


def upload_media(event_id: str, locale: str, loc_id: str, art_dir: Path) -> None:
    where = (f"for {locale} of event {event_id} (localization {loc_id} exists without its full art; "
             "a resume skips it, so add the art in App Store Connect or delete that localization first)")
    for fname, asset_type, kind in event_media(art_names(art_dir), art_dir):
        blob = (art_dir / fname).read_bytes()
        resource = RESOURCE[kind]
        reserved = call("POST", f"/v1/{resource}", json=reserve_payload(kind, fname, len(blob), asset_type, loc_id))
        if "_error" in reserved:
            bail(f"reserve {asset_type} {where}", reserved)
        media_id = reserved["data"]["id"]
        for op in reserved["data"]["attributes"]["uploadOperations"]:
            if err := put_bytes(op, blob):
                bail(f"upload bytes {asset_type} {where}", err)
        done = call("PATCH", f"/v1/{resource}/{media_id}", json={"data": {
            "type": resource, "id": media_id, "attributes": {"uploaded": True}}})
        if "_error" in done:
            bail(f"commit {asset_type} {where}", done)
        state = done["data"]["attributes"].get(STATE_KEY[kind], {}).get("state")
        if state == "FAILED":
            bail(f"commit {asset_type} {where}", done)
        print(f"{locale} {asset_type}: {kind} uploaded ({len(blob)} bytes) -> {state}")


@contextmanager
def draft_guard(event_id: str, spec_path: Path, art_dir: Path) -> Iterator[None]:
    """Once the event exists, any failure says how to resume or clear the DRAFT: a plain
    re-run would POST a second event beside it."""
    hint = (f"event {event_id} exists as a DRAFT — resume with `events.py create --spec {spec_path} "
            f"--art-dir {art_dir} --event {event_id}`, or delete it in App Store Connect")
    try:
        yield
    except SystemExit as exc:
        raise SystemExit(f"{exc.code}\n{hint}") from None
    except BaseException:
        print(hint, file=sys.stderr)
        raise


def post_event(spec: dict[str, Any]) -> str:
    """POST the DRAFT and return its id. A bail here leaves nothing behind."""
    territories = all_territories()
    print(f"territories: {len(territories)}")
    ev = call("POST", "/v1/appEvents", json=event_payload(spec, territories))
    if "_error" in ev:
        bail("create appEvent", ev)
    print("event created:", ev["data"]["id"], ev["data"]["attributes"].get("eventState"))
    return ev["data"]["id"]


def fill_locales(spec: dict[str, Any], table: dict[str, dict[str, str]], art_dir: Path,
                 event_id: str, existing: dict[str, str]) -> None:
    """One localization per locale the event lacks, primary first, each with the same
    textless card + details. A locale that exists is skipped and its art isn't checked:
    no code here reads a localization's media back, so that shape is unproven."""
    for locale, copy in table.items():
        if locale in existing:
            print(f"{locale}: exists ({existing[locale]}), skipped; its art is NOT checked, confirm it in App Store Connect")
            continue
        loc = call("POST", "/v1/appEventLocalizations",
                   json=localization_payload({**spec, "locale": locale, "copy": copy}, event_id))
        if "_error" in loc:
            bail(f"create localization {locale} of event {event_id}", loc)
        print(f"{locale}: localization created:", loc["data"]["id"])
        upload_media(event_id, locale, loc["data"]["id"], art_dir)


def print_dry_run(spec: dict[str, Any], table: dict[str, dict[str, str]], art_dir: Path,
                  event_id: str | None, media: list[tuple[str, str, str]]) -> int:
    if event_id is None:
        territories = ["<all ~175 from /v1/territories>"]
        print(f"territories: {len(territories)}")
        print(json.dumps(event_payload(spec, territories), indent=2))
    else:
        print(f"resume: would GET /v1/appEvents/{event_id}/localizations and create only the locales it lacks")
    for locale, copy in table.items():
        body = localization_payload({**spec, "locale": locale, "copy": copy}, event_id or "<event id>")
        print(json.dumps(body, indent=2, ensure_ascii=False))
    print("art for each new locale: " + " + ".join(f"{f} ({slot} {kind})" for f, slot, kind in media) + f" from {art_dir}")
    print("dry run: nothing sent")
    return 0


def create(spec_path: Path, art_dir: Path, dry_run: bool, event_id: str | None = None) -> int:
    """The DRAFT and every locale, or with `event_id` the locales an earlier run left out."""
    spec = json.loads(spec_path.read_text())
    if problems := deep_link_problems(spec):
        raise SystemExit("; ".join(problems))
    table = localization_table(spec)
    if problems := localization_problems({"localizations": table}):
        raise SystemExit("copy breaks caps: " + "; ".join(problems))
    for locale, copy in table.items():
        print(f"{locale:8} " + "  ".join(f"{k} {len(copy[k])}/{cap}" for k, cap in COPY_CAPS))
    media = checked_media(art_dir)
    if dry_run:
        return print_dry_run(spec, table, art_dir, event_id, media)
    resuming = event_id is not None
    if event_id is None:
        event_id = post_event(spec)
    with draft_guard(event_id, spec_path, art_dir):
        existing = existing_localizations(event_id) if resuming else {}
        fill_locales(spec, table, art_dir, event_id, existing)
    if any(kind == "video" for *_, kind in media):
        print("video clips process after upload: confirm every locale's card and details show no error "
              "in App Store Connect's event preview before you submit")
    final = call("GET", f"/v1/appEvents/{event_id}")
    print("final eventState:", final.get("data", {}).get("attributes", {}).get("eventState", "?"))
    print("event id:", event_id, "— submit for review by hand in App Store Connect")
    return 0


def update(event_id: str, spec_path: Path, dry_run: bool) -> int:
    spec = json.loads(spec_path.read_text())
    if problems := deep_link_problems(spec):
        raise SystemExit("; ".join(problems))
    table = spec.get("localizations") or {spec.get("locale", "en-US"): spec["copy"]}
    spec["localizations"] = table
    if problems := localization_problems(spec):
        raise SystemExit("copy breaks caps: " + "; ".join(problems))
    for locale, copy in table.items():
        print(f"{locale:8} " + "  ".join(f"{k} {len(copy[k])}/{cap}" for k, cap in COPY_CAPS))
    territories = ["<all ~175 from /v1/territories>"] if dry_run else all_territories()
    patch = attributes_patch(spec, event_id, territories)
    existing = {l["attributes"]["locale"]: l for l in paginate(f"/v1/appEvents/{event_id}/localizations?limit=50")}
    if dry_run:
        print(json.dumps(patch, indent=2))
        for locale, copy in table.items():
            loc = existing.get(locale)
            print(json.dumps(localization_patch(loc["id"] if loc else "<create>", copy), indent=2, ensure_ascii=False))
        print("dry run: nothing sent")
        return 0
    resp = call("PATCH", f"/v1/appEvents/{event_id}", json=patch)
    if "_error" in resp:
        bail("patch appEvent (not a DRAFT?)", resp)
    print("event:", resp["data"]["attributes"].get("referenceName"), resp["data"]["attributes"].get("badge"))
    for locale, copy in table.items():
        loc = existing.get(locale)
        if loc is None:
            created = call("POST", "/v1/appEventLocalizations", json=localization_payload(
                {**spec, "locale": locale, "copy": copy}, event_id))
            if "_error" in created:
                bail(f"create localization {locale}", created)
            print(f"{locale}: created (no art yet — upload the card + details for it)")
            continue
        done = call("PATCH", f"/v1/appEventLocalizations/{loc['id']}", json=localization_patch(loc["id"], copy))
        if "_error" in done:
            bail(f"patch localization {locale}", done)
        print(f"{locale}: {done['data']['attributes']['name']}")
    for locale in set(existing) - set(table):
        print(f"{locale}: no copy in the spec — left as is")
    print("event id:", event_id, "— submit for review by hand in App Store Connect")
    return 0


def list_events() -> int:
    events = list(paginate(f"/v1/apps/{APP_ID}/appEvents?limit=50"))
    if not events:
        print("no in-app events on the record")
        return 0
    for e in events:
        a = e["attributes"]
        sched = (a.get("territorySchedules") or [{}])[0]
        print(f"{e['id']}  {a.get('eventState'):18} {a.get('badge'):14} {a.get('referenceName')}  "
              f"{sched.get('eventStart', '?')} → {sched.get('eventEnd', '?')}")
    return 0


def app_season_days(lo: date, hi: date) -> tuple[set[str], dict[date, str]]:
    """Every look the app has, and its look on each local day lo..hi: season_days.swift compiled
    with the app's SeasonalLook.swift, so the answer is the app's own (about 2 s to compile)."""
    swiftc = shutil.which("swiftc")
    if not swiftc:
        raise SystemExit("swiftc not found: `next` and `check` read the app's own SeasonalLook.swift (install Xcode)")
    with tempfile.TemporaryDirectory(prefix="season-days-") as tmp:
        exe = Path(tmp) / "season_days"
        built = subprocess.run([swiftc, "-parse-as-library", "-module-name", "SeasonDays", str(SEASON_HELPER),
                                *map(str, SEASON_SOURCES), "-o", str(exe)],
                               capture_output=True, text=True, check=False, timeout=600)
        if built.returncode:
            raise SystemExit(f"season_days.swift did not compile with {', '.join(p.name for p in SEASON_SOURCES)}:\n"
                             f"{built.stderr.strip()[-1200:]}\n(a look that reads another app file needs that "
                             "file in events.py's SEASON_SOURCES)")
        ran = subprocess.run([str(exe), lo.isoformat(), str((hi - lo).days + 1)],
                             capture_output=True, text=True, check=False, timeout=120)
    if ran.returncode:
        raise SystemExit(f"season_days: {ran.stderr.strip()[:400]}")
    data = json.loads(ran.stdout)
    return set(data["looks"]), {date.fromisoformat(k): v for k, v in data["days"].items()}


def spec_paths(names: list[str]) -> list[Path]:
    """The named specs under EVENTS_DIR, or every one when none is named."""
    if not names:
        return sorted(EVENTS_DIR.glob("*/event.json"))
    paths = [EVENTS_DIR / name / "event.json" for name in names]
    if missing := [p.parent.name for p in paths if not p.is_file()]:
        raise SystemExit(f"no spec {', '.join(missing)} in {EVENTS_DIR}")
    return paths


def _unknown_looks(name: str, spec: dict[str, Any], known: set[str]) -> None:
    if unknown := [look for look in spec["looks"] if look not in known]:
        raise SystemExit(f"{name}: the app has no look {unknown[0]!r} (SeasonalLook has {', '.join(sorted(known))})")


def next_events(names: list[str], *, year: int | None, write: bool) -> int:
    """Propose each yearly spec's next window as a diff; `write` saves it to the spec file only."""
    yearly: list[tuple[Path, dict[str, Any]]] = []
    for path in spec_paths(names):
        spec = json.loads(path.read_text())
        if spec.get("looks"):
            yearly.append((path, spec))
        else:
            print(f"{path.parent.name}: no looks, not a yearly event, skipped")
    if not yearly:
        return 0
    ranges = {path: search_range(spec, year) for path, spec in yearly}
    known, days = app_season_days(min(lo for lo, _ in ranges.values()), max(hi for _, hi in ranges.values()))
    failed = 0
    for path, spec in yearly:
        name = path.parent.name
        _unknown_looks(name, spec, known)
        first, last = next_run(days, *ranges[path], spec["looks"], year)
        text = path.read_text()
        new_text = rewrite_dates(text, next_fields(spec, first, last))
        print(f"== {name}: the app wears {'/'.join(spec['looks'])} {first} → {last}")
        sys.stdout.writelines(difflib.unified_diff(text.splitlines(keepends=True), new_text.splitlines(keepends=True),
                                                   f"{name}/event.json", f"{name}/event.json (next)", n=0))
        new_spec = json.loads(new_text)
        if problems := schedule_problems(new_spec) + coverage_problems(new_spec, days):
            failed += 1
            print("\n".join(f"  ! {p}" for p in problems) + f"\n  {name}: not written")
            continue
        if notes := copy_date_notes(spec, first):
            old_day = _when(spec["eventStart"]).day
            print(f"  note: the copy names day {old_day} in {', '.join(notes)}, and the start moves to "
                  f"{first:%b} {first.day}: re-word it before `update` (next re-dates, never re-words)")
        if write:
            path.write_text(new_text)
            print(f"wrote {path}")
    if not write:
        print("dry run: nothing written (--write edits only these event.json files; "
              "App Store Connect changes only through `update`)")
    return 1 if failed else 0


def check_events(names: list[str]) -> int:
    """Every named spec (all by default) against Apple's limits, the yearly 10:00Z times and the
    app's own look windows; 1 when anything breaks."""
    specs = [(path, json.loads(path.read_text())) for path in spec_paths(names)]
    yearly = [spec for _, spec in specs if spec.get("looks")]
    known: set[str] = set()
    days: dict[date, str] = {}
    if yearly:
        lo = min(_when(s["eventStart"]).date() for s in yearly) - timedelta(days=1)
        hi = max(_when(s["eventEnd"]).date() for s in yearly) + timedelta(days=1)
        known, days = app_season_days(lo, hi)
    broken = 0
    for path, spec in specs:
        name = path.parent.name
        problems = deep_link_problems(spec) + localization_problems({"localizations": localization_table(spec)})
        if spec.get("referenceName") in SERVED_BY_1_5:
            print(f"{name}: {spec['referenceName']} was served by 1.5; its dates aren't checked against 1.6")
        elif spec.get("looks"):
            problems += schedule_problems(spec)
            _unknown_looks(name, spec, known)
            problems += coverage_problems(spec, days)
        for problem in problems:
            print(f"{name}: {problem}")
        broken += bool(problems)
    if broken:
        print(f"{broken} of {len(specs)} specs break a rule")
        return 1
    print(f"{len(specs)} specs, no problems")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    c = sub.add_parser("create")
    c.add_argument("--spec", required=True, type=Path, help="event.json (see fastlane/events/)")
    c.add_argument("--art-dir", required=True, type=Path,
                   help=f"holds {CARD_VIDEO} or {CARD_FILE}, and {DETAILS_VIDEO} or {DETAILS_FILE}")
    c.add_argument("--event", help="resume: the appEvents id of a DRAFT an earlier create left half-built")
    c.add_argument("--dry-run", action="store_true")
    u = sub.add_parser("update")
    u.add_argument("--event", required=True, help="appEvents id of a DRAFT")
    u.add_argument("--spec", required=True, type=Path)
    u.add_argument("--dry-run", action="store_true")
    n = sub.add_parser("next", help="re-date yearly specs to the app's next look window (local files only)")
    n.add_argument("names", nargs="*", help="spec folders under fastlane/events (christmas, ramadan, …)")
    n.add_argument("--all", action="store_true", help="every spec with `looks`")
    n.add_argument("--year", type=int, help="the run that starts in this year (default: the one after the spec's)")
    n.add_argument("--write", action="store_true", help="save the new dates into the event.json files")
    k = sub.add_parser("check", help="hold specs to Apple's limits and the app's look windows")
    k.add_argument("names", nargs="*", help="spec folders (default: every one)")
    args = ap.parse_args()
    if args.cmd == "list":
        return list_events()
    if args.cmd == "next":
        if bool(args.names) == args.all:
            raise SystemExit("next: name a spec or pass --all (not both)")
        return next_events(args.names, year=args.year, write=args.write)
    if args.cmd == "check":
        return check_events(args.names)
    if args.cmd == "update":
        return update(args.event, args.spec, args.dry_run)
    return create(args.spec, args.art_dir, args.dry_run, args.event)


if __name__ == "__main__":
    sys.exit(main())
