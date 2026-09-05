#!/usr/bin/env python3
"""Turn Kev's thumbs-down feedback into draft eval fixtures.

    ./feedback_to_fixtures.py                      # reads the live container DB
    ./feedback_to_fixtures.py --jsonl export.jsonl # or a File ▸ Export feedback file
    ./feedback_to_fixtures.py --out drafts.swift

Every bad verdict WITH a comment becomes a `ChatEvalFixture` stub, ready to
paste into `Sources/M1K3Eval/ChatEvalFixture.swift` and curate: the prompt is
the real question, the comment rides along as the rubric, the kind is a guess
(marked as such) and the expectation is a TODO — a dislike says an answer was
wrong, it cannot say what right looks like, and a fixture that pretends
otherwise is a fake metric. The value is the plumbing: the miss is in front
of whoever curates, with the question and the tools that fired, seconds after
it happened, instead of lost in a transcript.

The first real row (2026-09-04, "fetch the web site m1k3.app…", tools:
open_link, comment: "we didn't pick it up") became `tool-read-site`.

Signed: Kev + claude-fable-5.1, 2026-09-04, Confidence 0.85 (pure helpers
tested; the SQLite read mirrors AnswerFeedbackExport's columns). Prior: Unknown
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import sqlite3
import sys
from dataclasses import dataclass

CONTAINER_DB = os.path.expanduser(
    "~/Library/Containers/app.m1k3/Data/Library/Application Support/M1K3/chat-history.sqlite"
)

TOOL_WORDS = ("search", "web", "fetch", "open", "link", "browser", "page", "site", "tool", "look up", "lookup")
GENERATIVE_LEADS = ("write", "create", "code", "make", "compose", "draft", "build", "generate")


@dataclass(frozen=True)
class FeedbackRow:
    message_id: str
    verdict: str  # "good" | "bad"
    rated_at: str
    brain: str
    question: str
    answer: str
    tools_used: tuple[str, ...]
    comment: str | None


def guess_kind(question: str, comment: str | None, tools_used: tuple[str, ...]) -> str:
    """A guess, never a verdict: the stub says so beside it."""
    lead = question.strip().lower()
    if any(lead.startswith(w) for w in GENERATIVE_LEADS):
        return "codeGen"
    haystack = f"{question} {comment or ''}".lower()
    if tools_used or any(w in haystack for w in TOOL_WORDS):
        return "toolUse"
    return "openChat"


def swift_string(text: str) -> str:
    """A one-line Swift string literal: escape backslashes and quotes, fold newlines."""
    folded = " ".join(text.split())
    return '"' + folded.replace("\\", "\\\\").replace('"', '\\"') + '"'


def fixture_id(row: FeedbackRow) -> str:
    return "feedback-" + row.message_id.lower().replace("-", "")[:8]


def render_fixture(row: FeedbackRow) -> str:
    kind = guess_kind(row.question, row.comment, row.tools_used)
    tools = ", ".join(row.tools_used) if row.tools_used else "none"
    comment = " ".join((row.comment or "").split())
    answer_head = " ".join(row.answer.split())[:200]
    expectation = (
        '.init(mustCallTool: "TODO")' if kind == "toolUse" else ".init(mustContainAny: [\"TODO\"])"
    )
    return "\n".join(
        [
            f"        // Feedback {row.rated_at} ({row.brain}, tools: {tools}) — Kev: \"{comment}\"",
            f"        // Answer as rated: \"{answer_head}\"",
            "        .init(",
            f"            id: {swift_string(fixture_id(row))}, kind: .{kind}, // kind GUESSED — curate",
            f"            prompt: {swift_string(row.question)},",
            f"            expectation: {expectation} // the comment above is the rubric — curate",
            "        ),",
        ]
    )


def render(rows: list[FeedbackRow]) -> str:
    drafts = [render_fixture(r) for r in rows if r.verdict == "bad" and (r.comment or "").strip()]
    if not drafts:
        return "// no bad verdicts with a comment — nothing to draft\n"
    header = f"// {len(drafts)} draft fixture(s) from feedback — paste into ChatEvalFixture.swift and curate\n"
    return header + "\n".join(drafts) + "\n"


def rows_from_jsonl(text: str) -> list[FeedbackRow]:
    rows = []
    for line in text.splitlines():
        if not line.strip():
            continue
        o = json.loads(line)
        rows.append(
            FeedbackRow(
                message_id=o["message_id"],
                verdict=o["verdict"],
                rated_at=o.get("rated_at", ""),
                brain=o.get("brain", ""),
                question=o["question"],
                answer=o.get("answer", ""),
                tools_used=tuple(o.get("tools_used", [])),
                comment=o.get("comment"),
            )
        )
    return rows


def rows_from_sqlite(path: str) -> list[FeedbackRow]:
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        cur = db.execute(
            "select message_id, verdict, created_at, brain, question, answer, tools_used, comment "
            "from message_feedback order by created_at desc"
        )
        rows = []
        for mid, verdict, created, brain, question, answer, tools, comment in cur:
            stamp = _dt.datetime.fromtimestamp(created)  # Unix epoch — what recordFeedback writes
            rows.append(
                FeedbackRow(
                    message_id=mid,
                    verdict="good" if verdict == 1 else "bad",
                    rated_at=stamp.strftime("%Y-%m-%d %H:%M"),
                    brain=brain,
                    question=question,
                    answer=answer,
                    tools_used=tuple(json.loads(tools or "[]")),
                    comment=comment,
                )
            )
        return rows
    finally:
        db.close()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--jsonl", help="an AnswerFeedbackExport file (File ▸ Export feedback)")
    ap.add_argument("--sqlite", default=CONTAINER_DB, help="the chat-history database (default: the live container)")
    ap.add_argument("--out", help="write the Swift drafts here instead of stdout")
    args = ap.parse_args(argv)
    if args.jsonl:
        with open(args.jsonl, encoding="utf-8") as f:
            rows = rows_from_jsonl(f.read())
    else:
        if not os.path.exists(args.sqlite):
            print(f"no database at {args.sqlite}", file=sys.stderr)
            return 2
        rows = rows_from_sqlite(args.sqlite)
    text = render(rows)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"wrote {args.out}")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
