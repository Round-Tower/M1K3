import io

import hn_watch as w


def test_flatten_strips_tags_entities_and_newlines():
    s = "<p>Why <i>FSL</i> &amp; not MIT?</p>\n<p>Asking   for a friend.</p>"
    assert w.flatten(s) == "Why FSL & not MIT? Asking for a friend."


def test_flatten_cuts_with_ellipsis():
    assert w.flatten("a" * 400, limit=10) == "aaaaaaaaa…"
    assert w.flatten(None) == ""


def fake_fetch_factory(hits, item, reddit=None):
    def fetch(url):
        if url.startswith(w.HN_SEARCH):
            return {"hits": hits}
        if url.startswith("https://hn.algolia.com/api/v1/items/"):
            return item
        if url.endswith(".json?limit=500&raw_json=1"):
            return reddit
        raise AssertionError(url)
    return fetch


def test_hn_comments_sorted_oldest_first():
    hits = [
        {"objectID": "2", "author": "b", "created_at_i": 20, "comment_text": "<p>second</p>"},
        {"objectID": "1", "author": "a", "created_at_i": 10, "comment_text": "first"},
    ]
    cs = w.hn_comments(99, fake_fetch_factory(hits, {}))
    assert [c.id for c in cs] == ["1", "2"]
    assert cs[1].text == "second"
    assert cs[0].url.endswith("item?id=1")


def test_hn_story_counts_nested_children():
    item = {"points": 41, "children": [{"children": [{"children": []}]}, {"children": []}]}
    assert w.hn_story(99, fake_fetch_factory([], item)) == (41, 3)


def test_reddit_walks_replies_and_skips_more_stubs():
    thread = [
        {"kind": "Listing", "data": {"children": [{"kind": "t3", "data": {}}]}},
        {"kind": "Listing", "data": {"children": [
            {"kind": "t1", "data": {"id": "x", "author": "ann", "created_utc": 5, "body": "top **q**",
                                    "permalink": "/r/macapps/comments/abc/x/",
                                    "replies": {"kind": "Listing", "data": {"children": [
                                        {"kind": "t1", "data": {"id": "y", "author": "bob", "created_utc": 7,
                                                                "body": "reply", "permalink": "/p/y", "replies": ""}},
                                        {"kind": "more", "data": {}},
                                    ]}}}},
        ]}},
    ]
    cs = w.reddit_comments("https://www.reddit.com/r/macapps/comments/abc/title/?utm=1",
                           fake_fetch_factory([], {}, thread))
    assert [(c.id, c.author) for c in cs] == [("x", "u/ann"), ("y", "u/bob")]
    assert cs[0].url == "https://www.reddit.com/r/macapps/comments/abc/x/"


def test_reddit_json_url_drops_query_and_adds_json():
    assert w.reddit_json_url("https://www.reddit.com/r/a/comments/b/c/?x=1") == \
        "https://www.reddit.com/r/a/comments/b/c.json?limit=500&raw_json=1"


def test_run_prints_only_new_comments_after_first_pass_unless_backfill():
    hits = [{"objectID": "1", "author": "a", "created_at_i": 10, "comment_text": "old"}]
    item = {"points": 1, "children": [{"children": []}]}
    calls = {"n": 0}

    def fetch(url):
        if url.startswith(w.HN_SEARCH):
            return {"hits": hits + ([{"objectID": "2", "author": "b", "created_at_i": 20,
                                      "comment_text": "new"}] if calls["n"] > 0 else [])}
        calls["n"] += 1
        return item

    out = io.StringIO()
    sleeps = []

    def sleep(s):
        sleeps.append(s)
        if len(sleeps) >= 2:
            raise SystemExit  # end the loop after two polls

    try:
        w.run(99, [], 30, once=False, backfill=False, fetch=fetch, out=out, sleep=sleep)
    except SystemExit:
        pass
    lines = out.getvalue().splitlines()
    assert any("story: 1 points · 1 comments" in l for l in lines)
    assert not any(" old" in l for l in lines)          # present before the watch began: not printed
    assert sum(" new" in l for l in lines) == 1         # printed once, not on every poll
    assert sleeps == [30, 30]


def test_run_backfill_prints_existing_and_survives_fetch_errors():
    def fetch(url):
        if url.startswith(w.HN_SEARCH):
            return {"hits": [{"objectID": "1", "author": "a", "created_at_i": 10, "comment_text": "old"}]}
        raise ConnectionError("boom")

    out = io.StringIO()
    w.run(99, [], 30, once=True, backfill=True, fetch=fetch, out=out, sleep=lambda s: None)
    text = out.getvalue()
    assert " old" in text
    assert "fetch failed: ConnectionError: boom" in text
