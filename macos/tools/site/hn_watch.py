#!/usr/bin/env python3
"""Watch a Show HN thread (and optionally Reddit threads) and print each new comment once.

  hn_watch.py 12345678                         the HN item id, polled every 30 s
  hn_watch.py 12345678 --reddit https://www.reddit.com/r/macapps/comments/abc123/...  (repeatable)
  hn_watch.py 12345678 --interval 20 --once    one pass, then exit (a smoke test)
  hn_watch.py 12345678 --backfill               print the comments already there first, then watch

One line per comment, flushed as it lands, so a Monitor can turn each into a notification:

  HN   12:41  someuser     Why FSL and not MIT? ...
  RD   12:43  u/someone    Does it run on an M1 Air with 8 GB? ...

and a status line whenever the HN story's points or comment count changes:

  HN   12:45  — story: 41 points · 17 comments

No keys: HN via Algolia's public search API, Reddit via the thread's public .json. Both are
polite about rate (30 s default; Reddit asks for a descriptive User-Agent, which we send).

Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.75 (the parsing and the loop are pinned
by tests against canned payloads; neither API has been watched through a live launch thread yet).
"""
from __future__ import annotations

import argparse
import html
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from collections.abc import Callable, Iterable
from dataclasses import dataclass

USER_AGENT = "m1k3-launch-watch/0.1 (round-tower.ie; a one-person indie studio reading its own thread)"
HN_SEARCH = "https://hn.algolia.com/api/v1/search_by_date"
HN_ITEM = "https://hn.algolia.com/api/v1/items/{id}"

Fetch = Callable[[str], dict | list]


@dataclass(frozen=True)
class Comment:
    source: str      # "HN" or "RD"
    id: str
    author: str
    created: int     # unix seconds
    text: str        # one line, tags stripped, whitespace collapsed
    url: str


def flatten(text: str | None, limit: int = 320) -> str:
    """HTML or Markdown → one plain line, cut at `limit` with an ellipsis."""
    if not text:
        return ""
    t = re.sub(r"<[^>]+>", " ", text)
    t = html.unescape(t)
    t = re.sub(r"\s+", " ", t).strip()
    return t if len(t) <= limit else t[: limit - 1].rstrip() + "…"


def fetch_json(url: str) -> dict | list:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8"))


# ---- Hacker News (Algolia) --------------------------------------------------------------

def hn_comments(item_id: int, fetch: Fetch = fetch_json) -> list[Comment]:
    q = urllib.parse.urlencode({"tags": f"comment,story_{item_id}", "hitsPerPage": 200})
    data = fetch(f"{HN_SEARCH}?{q}")
    out = []
    for hit in data.get("hits", []):
        out.append(Comment(
            source="HN",
            id=str(hit.get("objectID")),
            author=hit.get("author") or "?",
            created=int(hit.get("created_at_i") or 0),
            text=flatten(hit.get("comment_text")),
            url=f"https://news.ycombinator.com/item?id={hit.get('objectID')}",
        ))
    return sorted(out, key=lambda c: c.created)


def hn_story(item_id: int, fetch: Fetch = fetch_json) -> tuple[int, int]:
    """(points, comment count) for the story, from Algolia's item endpoint."""
    data = fetch(HN_ITEM.format(id=item_id))
    points = int(data.get("points") or 0)

    def count(node: dict) -> int:
        return sum(1 + count(child) for child in node.get("children", []) or [])

    return points, count(data)


# ---- Reddit (public JSON) ----------------------------------------------------------------

def reddit_json_url(thread_url: str) -> str:
    base = thread_url.split("?", 1)[0].rstrip("/")
    return base + ".json?limit=500&raw_json=1"


def reddit_comments(thread_url: str, fetch: Fetch = fetch_json) -> list[Comment]:
    data = fetch(reddit_json_url(thread_url))
    if not isinstance(data, list) or len(data) < 2:
        return []
    out: list[Comment] = []

    def walk(listing: dict) -> None:
        for child in (listing.get("data", {}).get("children") or []):
            if child.get("kind") != "t1":
                continue
            d = child.get("data", {})
            out.append(Comment(
                source="RD",
                id=str(d.get("id")),
                author="u/" + (d.get("author") or "?"),
                created=int(d.get("created_utc") or 0),
                text=flatten(d.get("body")),
                url="https://www.reddit.com" + (d.get("permalink") or ""),
            ))
            replies = d.get("replies")
            if isinstance(replies, dict):
                walk(replies)

    walk(data[1])
    return sorted(out, key=lambda c: c.created)


# ---- the loop ----------------------------------------------------------------------------

def fmt(c: Comment) -> str:
    clock = time.strftime("%H:%M", time.localtime(c.created)) if c.created else "--:--"
    return f"{c.source:<4} {clock}  {c.author:<14} {c.text}"


def new_comments(seen: set[str], comments: Iterable[Comment]) -> list[Comment]:
    fresh = [c for c in comments if (c.source, c.id) not in seen]
    for c in fresh:
        seen.add((c.source, c.id))
    return fresh


def run(item_id: int, reddit: list[str], interval: int, once: bool, backfill: bool,
        fetch: Fetch = fetch_json, out=sys.stdout, sleep: Callable[[float], None] = time.sleep) -> None:
    seen: set = set()
    last_story: tuple[int, int] | None = None
    first = True
    while True:
        try:
            batch = hn_comments(item_id, fetch)
            for url in reddit:
                batch += reddit_comments(url, fetch)
            fresh = new_comments(seen, sorted(batch, key=lambda c: c.created))
            if first and not backfill:
                fresh = []       # mark everything present as seen, print only what lands from now
            for c in fresh:
                print(fmt(c), file=out, flush=True)
            story = hn_story(item_id, fetch)
            if story != last_story:
                print(f"HN   {time.strftime('%H:%M')}  — story: {story[0]} points · {story[1]} comments",
                      file=out, flush=True)
                last_story = story
        except Exception as e:  # noqa: BLE001 — any fetch or parse failure must not kill a three-hour watch
            print(f"--   {time.strftime('%H:%M')}  fetch failed: {e.__class__.__name__}: {e}", file=out, flush=True)
        first = False
        if once:
            return
        sleep(interval)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("item_id", type=int, help="the HN item id (the number in news.ycombinator.com/item?id=)")
    p.add_argument("--reddit", action="append", default=[], help="a Reddit thread URL to watch too (repeatable)")
    p.add_argument("--interval", type=int, default=30, help="seconds between polls (default 30)")
    p.add_argument("--once", action="store_true", help="one pass, then exit")
    p.add_argument("--backfill", action="store_true", help="print the comments already there before watching")
    a = p.parse_args(argv)
    run(a.item_id, a.reddit, a.interval, a.once, a.backfill)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:  # `| head` closed the pipe: that's the reader's choice, not an error
        sys.exit(0)
