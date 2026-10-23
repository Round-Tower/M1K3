"""Pins for ranks.py's pure half: the search URL per platform, the rank in a result list, the
log line, the baseline pick and the movement label."""
from __future__ import annotations

import argparse
import io
import json
import urllib.error
from pathlib import Path

import pytest
import ranks


def _hit(track_id, name="App", ratings=0):
    return {"trackId": track_id, "trackName": name, "userRatingCount": ratings}


def test_ios_reads_the_search_api_and_mac_reads_the_web_store():
    # The API's macSoftware entity lists M1K3 for no term, not even "m1k3", while the Mac App Store
    # and apps.apple.com put it first (2026-10-23, the IE store's order matched result for result).
    ios = ranks.search_url("local ai", "kz", "ios", 200)
    mac = ranks.search_url("local ai", "ie", "mac", 200)
    assert ios.startswith("https://itunes.apple.com/search?")
    assert "entity=software" in ios and "country=kz" in ios and "term=local+ai" in ios and "limit=200" in ios
    assert mac == "https://apps.apple.com/ie/mac/search?term=local%20ai"


def test_each_source_reads_its_own_depth():
    assert ranks.depth("ios", 500) == 200 and ranks.depth("ios", 50) == 50
    assert ranks.depth("mac", 200) == ranks.WEB_DEPTH == 12


def test_the_search_api_caps_the_limit_at_200():
    assert "limit=200" in ranks.search_url("ai", "us", "ios", 500)


def test_rank_is_one_based_and_none_when_absent():
    results = [_hit(1), _hit(ranks.APP_ID), _hit(3)]
    assert ranks.rank_of(results, ranks.APP_ID) == 2
    assert ranks.rank_of([_hit(1)], ranks.APP_ID) is None
    assert ranks.rank_of([], ranks.APP_ID) is None


def test_a_log_line_carries_the_key_the_rank_and_who_leads():
    results = [_hit(9, "Locally AI by LM Studio", 1200), _hit(ranks.APP_ID, "M1K3")]
    line = ranks.entry("2026-10-23", "local ai", "us", "ios", results, ranks.APP_ID)
    assert line == {"date": "2026-10-23", "term": "local ai", "country": "us", "platform": "ios",
                    "rank": 2, "n": 2, "limit": 200, "leader": "Locally AI by LM Studio", "leader_ratings": 1200}


def test_an_empty_search_logs_no_leader():
    line = ranks.entry("2026-10-23", "zzz", "us", "ios", [], ranks.APP_ID)
    assert line["rank"] is None and line["n"] == 0 and line["leader"] is None


def _line(date, rank, term="local ai", country="us", platform="ios"):
    return {"date": date, "term": term, "country": country, "platform": platform, "rank": rank}


def test_the_baseline_is_the_newest_earlier_run_of_the_same_key():
    log = [_line("2026-10-20", 40), _line("2026-10-21", 36), _line("2026-10-21", 5, country="kz"),
           _line("2026-10-23", 30)]
    assert ranks.baseline(log, "local ai", "us", "ios", before="2026-10-23")["rank"] == 36


def test_vs_picks_the_newest_run_on_or_before_that_day():
    log = [_line("2026-10-20", 40), _line("2026-10-22", 36), _line("2026-10-23", 30)]
    assert ranks.baseline(log, "local ai", "us", "ios", before="2026-10-23", on_or_before="2026-10-21")["rank"] == 40
    assert ranks.baseline(log, "local ai", "us", "ios", before="2026-10-23", on_or_before="2026-10-19") is None


def test_no_earlier_run_is_no_baseline():
    assert ranks.baseline([_line("2026-10-23", 30)], "local ai", "us", "ios", before="2026-10-23") is None


def test_movement_reads_up_as_a_smaller_number():
    assert ranks.movement(30, 36) == "▲6"
    assert ranks.movement(40, 36) == "▼4"
    assert ranks.movement(36, 36) == "="


def test_movement_names_entering_and_leaving_the_list():
    assert ranks.movement(150, None, had_baseline=True) == "new"
    assert ranks.movement(None, 150, had_baseline=True) == "lost"
    assert ranks.movement(None, None, had_baseline=True) == ""
    assert ranks.movement(30, None, had_baseline=False) == ""


def test_comma_lists_split_trim_and_lowercase():
    assert ranks.split_list("us, KZ ,,in") == ["us", "kz", "in"]


def test_the_terms_file_skips_comments_and_blank_lines(tmp_path: Path):
    p = tmp_path / "terms.txt"
    p.write_text("# category\nlocal ai\n\n  offline ai  # inline note\n", encoding="utf-8")
    assert ranks.load_terms(p) == ["local ai", "offline ai"]


def test_the_tracked_terms_file_loads_and_names_no_duplicates():
    terms = ranks.load_terms(ranks.TERMS)
    assert terms and len(terms) == len(set(terms))


def test_a_same_day_tie_takes_the_last_line_written():
    log = [_line("2026-10-22", 40), _line("2026-10-22", 36)]
    assert ranks.baseline(log, "local ai", "us", "ios", before="2026-10-23")["rank"] == 36


def test_vs_today_compares_with_this_mornings_run():
    log = [_line("2026-10-30", 36)]
    assert ranks.baseline(log, "local ai", "us", "ios", before="2026-10-30", on_or_before="2026-10-30")["rank"] == 36


def test_an_empty_answer_is_never_a_baseline():
    # A throttled 200 with no results logged as "not ranked" would read as "lost", then "new".
    log = [_line("2026-10-21", 36), {**_line("2026-10-22", None), "n": 0}]
    assert ranks.baseline(log, "local ai", "us", "ios", before="2026-10-23")["rank"] == 36


def test_a_baseline_must_have_read_to_the_same_depth():
    # Also keeps the Search API's blind Mac lines (depth 200) out of the web store's (depth 12).
    log = [{**_line("2026-10-21", 36), "limit": 200}, {**_line("2026-10-22", None), "limit": 50}]
    assert ranks.baseline(log, "local ai", "us", "ios", before="2026-10-23", limit=200)["rank"] == 36
    mac = [{**_line("2026-10-21", None, platform="mac"), "limit": 200}]
    assert ranks.baseline(mac, "local ai", "us", "mac", before="2026-10-23", limit=12) is None
    # Lines from before the limit was logged were all top-200 sweeps.
    assert ranks.baseline([_line("2026-10-21", 36)], "local ai", "us", "ios", before="2026-10-23", limit=200)


def test_a_cell_shows_the_rank_and_how_it_moved():
    assert ranks.cell({"rank": 30, "n": 200}, {"rank": 36}) == "30 ▲6"
    assert ranks.cell({"rank": 30, "n": 200}, {"rank": None}) == "30 new"
    assert ranks.cell({"rank": None, "n": 200}, {"rank": 30}) == "— lost"
    assert ranks.cell({"rank": 30, "n": 200}, None) == "30 ·"
    assert ranks.cell({"rank": None, "n": 0}, None) == "?"


def test_the_log_line_records_the_depth_read():
    assert ranks.entry("2026-10-23", "ai", "us", "ios", [], ranks.APP_ID, limit=200)["limit"] == 200


def test_terms_are_lowercased_deduped_and_hashes_inside_a_term_survive(tmp_path: Path):
    p = tmp_path / "terms.txt"
    p.write_text("# head\nLocal AI\nlocal ai\nc# editor # inline\n", encoding="utf-8")
    assert ranks.load_terms(p) == ["local ai", "c# editor"]
    assert ranks.clean_terms(["  ", "Ollama", "ollama"]) == ["ollama"]


def test_a_corrupt_log_line_is_skipped_not_fatal(tmp_path: Path):
    p = tmp_path / "ranks.jsonl"
    p.write_text(json.dumps(_line("2026-10-21", 36)) + "\n{\"date\": \"2026-10-2\n" + json.dumps({"date": "x"}) + "\n",
                 encoding="utf-8")
    assert ranks.read_log(p) == [_line("2026-10-21", 36)]


def test_vs_must_be_an_iso_day():
    assert ranks.iso_day("2026-10-30") == "2026-10-30"
    for bad in ("10-30", "2026-10-3", "tomorrow"):
        with pytest.raises(argparse.ArgumentTypeError):
            ranks.iso_day(bad)


class _Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _urlopen(answers):
    calls = []

    def fake(req, timeout):
        calls.append(req.full_url)
        answer = answers[len(calls) - 1]
        if isinstance(answer, BaseException):
            raise answer
        return _Resp(answer)
    return fake, calls


def test_search_retries_a_throttle_a_timeout_and_a_non_json_page(monkeypatch):
    throttle = urllib.error.HTTPError("u", 403, "Forbidden", {}, None)
    fake, calls = _urlopen([throttle, TimeoutError(), b"<html>slow down</html>", b'{"results": [{"trackId": 1}]}'])
    monkeypatch.setattr(ranks.urllib.request, "urlopen", fake)
    monkeypatch.setattr(ranks.time, "sleep", lambda s: None)
    assert ranks.search("ai", "us", "ios", 200) == [{"trackId": 1}]
    assert len(calls) == 4


def test_search_gives_up_with_an_error_not_an_empty_list(monkeypatch):
    fake, _ = _urlopen([ConnectionResetError()] * 4)
    monkeypatch.setattr(ranks.urllib.request, "urlopen", fake)
    monkeypatch.setattr(ranks.time, "sleep", lambda s: None)
    with pytest.raises(OSError):
        ranks.search("ai", "us", "ios", 200)


def test_search_does_not_retry_a_bad_request(monkeypatch):
    fake, calls = _urlopen([urllib.error.HTTPError("u", 400, "Bad Request", {}, None)])
    monkeypatch.setattr(ranks.urllib.request, "urlopen", fake)
    with pytest.raises(urllib.error.HTTPError):
        ranks.search("ai", "zz", "ios", 200)
    assert len(calls) == 1


def _card(pos, name, track_id):
    return (f'{{"locationPosition":0,"locationType":"button","name":"Get","idType":"its_id","id":"{track_id}"}},'
            f'{{"locationPosition":{pos},"locationType":"card","name":"{name}","idType":"its_id","id":"{track_id}"}}')


# The real page's shape (2026-10-23): each result's card slot, repeated per shelf, with an in-app
# event and an editorial article interleaved, and a video card with no name first — ids that are not results and must not take a slot.
WEB_PAGE = ('<html><script type="application/json" id="serialized-server-data">[' + ",".join([
    _card(0, "", 6780230835), _card(0, "Local Offline AI Agent \\u2013 M1K3", 6780230835), _card(0, "dup", 6780230835),
    _card(1, "Canva", 897446215),
    '{"locationPosition":1,"locationType":"eventModule","name":"Hello!","idType":"its_id","id":"6815946720"}',
    _card(2, "Shapr 3D", 1091675654),
    '{"destination":{"storefront":"ie","id":"1620909697","platform":"mac","$kind":"RoutableArticlePage"}}',
]) + ']</script></html>').encode()


def test_the_web_store_page_parses_to_its_card_slots_not_every_id():
    assert ranks.web_results(WEB_PAGE.decode()) == [
        {"trackId": 6780230835, "trackName": "Local Offline AI Agent – M1K3"},
        {"trackId": 897446215, "trackName": "Canva"},
        {"trackId": 1091675654, "trackName": "Shapr 3D"}]
    assert ranks.web_results("<html>no shelf</html>") == []


def test_mac_search_reads_the_web_page(monkeypatch):
    fake, calls = _urlopen([WEB_PAGE])
    monkeypatch.setattr(ranks.urllib.request, "urlopen", fake)
    assert ranks.rank_of(ranks.search("m1k3", "ie", "mac", 200), ranks.APP_ID) == 1
    assert calls == ["https://apps.apple.com/ie/mac/search?term=m1k3"]
