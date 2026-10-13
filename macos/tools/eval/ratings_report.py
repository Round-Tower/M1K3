#!/usr/bin/env python3
"""Read the answer ratings you exported from the phone (or the Mac) and say what they show.

    tools/eval/ratings_report.py                         # the newest export in ~/Downloads
    tools/eval/ratings_report.py ratings.jsonl           # or a file you name
    tools/eval/ratings_report.py ratings.jsonl --out r.md

On the phone: Settings ▸ Answer ratings ▸ Export ratings (JSONL), then AirDrop it
to the Mac (it lands in ~/Downloads) or save it to Files. One JSON object per rated
answer, in AnswerFeedbackExport's shape: verdict, brain, question, answer, tools
used, the note.

The report is markdown:
- the totals and the date range;
- each brain's rate, worst first;
- the bad answers where no tool fired (the usual tell: it should have searched);
- every note on a bad answer, newest first.

Notes are what make a miss fixable. `feedback_to_fixtures.py --jsonl <file>` turns
the noted misses into eval fixture drafts.

Signed: Kev + claude-opus-5-5, 2026-10-13, Confidence 0.85 (pure helpers pinned in
test_ratings_report.py; parsing reuses feedback_to_fixtures). Prior: none (new file).
"""

from __future__ import annotations

import argparse
import pathlib
import sys
from collections import Counter
from dataclasses import dataclass

import feedback_to_fixtures as f2f

DOWNLOADS = pathlib.Path.home() / "Downloads"
EXPORT_GLOB = "m1k3-answer-ratings*.jsonl"


@dataclass(frozen=True)
class Summary:
    total: int
    good: int
    bad: int
    first: str
    last: str


def summarise(rows: list[f2f.FeedbackRow]) -> Summary:
    dates = sorted(r.rated_at for r in rows if r.rated_at)
    good = sum(r.verdict == "good" for r in rows)
    return Summary(len(rows), good, len(rows) - good, dates[0] if dates else "", dates[-1] if dates else "")


def by_brain(rows: list[f2f.FeedbackRow]) -> list[tuple[str, int, int, int]]:
    """(brain, rated, good, bad), the worst bad rate first, then the most rated."""
    rated, bad = Counter(), Counter()
    for r in rows:
        name = r.brain or "unknown"
        rated[name] += 1
        bad[name] += r.verdict == "bad"
    table = [(name, rated[name], rated[name] - bad[name], bad[name]) for name in rated]
    return sorted(table, key=lambda t: (-t[3] / t[1], -t[1], t[0]))


def bad_without_tools(rows: list[f2f.FeedbackRow]) -> list[f2f.FeedbackRow]:
    """Bad answers where no tool fired, newest first: often it should have searched."""
    misses = [r for r in rows if r.verdict == "bad" and not r.tools_used]
    return sorted(misses, key=lambda r: r.rated_at, reverse=True)


def _clip(text: str, limit: int = 140) -> str:
    flat = " ".join(text.split())
    return flat if len(flat) <= limit else flat[: limit - 1] + "…"


def render(rows: list[f2f.FeedbackRow], source: str) -> str:
    if not rows:
        return f"# Answer ratings\n\nNo ratings in `{source}`.\n"
    s = summarise(rows)
    pct = lambda n: f"{round(100 * n / s.total)}%"
    out = [
        "# Answer ratings",
        "",
        f"`{source}`: {s.total} rated answers from {s.first} to {s.last}.",
        f"{s.good} good ({pct(s.good)}), {s.bad} bad ({pct(s.bad)}).",
        "",
        "## By brain",
        "",
        "| Brain | Rated | Good | Bad | Bad rate |",
        "|---|---|---|---|---|",
    ]
    out += [f"| {b} | {n} | {g} | {x} | {round(100 * x / n)}% |" for b, n, g, x in by_brain(rows)]

    silent = bad_without_tools(rows)
    out += ["", f"## Bad answers where no tool fired ({len(silent)})", ""]
    out += [f"- **{_clip(r.question, 90)}** ({r.brain}){': ' + _clip(r.comment) if r.comment else ''}"
            for r in silent] or ["None."]

    noted = sorted((r for r in rows if r.verdict == "bad" and r.comment), key=lambda r: r.rated_at, reverse=True)
    unnoted = sum(r.verdict == "bad" and not r.comment for r in rows)
    out += ["", f"## Notes on bad answers ({len(noted)})", ""]
    for r in noted:
        tools = ", ".join(r.tools_used) or "no tools"
        out.append(f"- **{_clip(r.question, 90)}**  \n  {_clip(r.comment or '')}  \n  _{r.brain} · {tools} · {r.rated_at}_")
    if not noted:
        out.append("None.")
    if unnoted:
        out += ["", f"{unnoted} bad answer{'s' if unnoted != 1 else ''} without a note. A note is what makes a miss fixable."]
    out += ["", f"Next: `tools/eval/feedback_to_fixtures.py --jsonl {source}` drafts eval fixtures from the noted misses.", ""]
    return "\n".join(out)


def newest_export(folder: pathlib.Path) -> pathlib.Path | None:
    """The most recently modified ratings export in a folder (AirDrop numbers repeats)."""
    if not folder.is_dir():
        return None
    exports = sorted(folder.glob(EXPORT_GLOB), key=lambda p: p.stat().st_mtime, reverse=True)
    return exports[0] if exports else None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("jsonl", nargs="?", help=f"an export (default: the newest {EXPORT_GLOB} in ~/Downloads)")
    ap.add_argument("--out", help="write the markdown report here instead of stdout")
    args = ap.parse_args(argv)
    path = pathlib.Path(args.jsonl) if args.jsonl else newest_export(DOWNLOADS)
    if path is None or not path.is_file():
        print(f"No ratings export found ({args.jsonl or f'~/Downloads/{EXPORT_GLOB}'}). On the phone: "
              "Settings ▸ Answer ratings ▸ Export ratings (JSONL), then AirDrop it here.", file=sys.stderr)
        return 1
    report = render(f2f.rows_from_jsonl(path.read_text(encoding="utf-8")), source=str(path))
    if args.out:
        pathlib.Path(args.out).write_text(report, encoding="utf-8")
        print(f"wrote {args.out}")
    else:
        print(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
