"""Pins for metrics.py's pure half: the sales TSV Apple returns, the product-type
classes, the day window, the analytics report pick, and the repo snapshot line."""
from __future__ import annotations

import datetime as dt
import gzip

import metrics

HEADER = ("Provider\tProvider Country\tSKU\tDeveloper\tTitle\tVersion\tProduct Type Identifier\tUnits\t"
          "Developer Proceeds\tBegin Date\tEnd Date\tCustomer Currency\tCountry Code\tCurrency of Proceeds\t"
          "Apple Identifier\tCustomer Price\tPromo Code\tParent Identifier\tSubscription\tPeriod\tCategory\t"
          "CMB\tDevice\tSupported Platforms\tProceeds Reason\tPreserved Pricing\tClient\tOrder Type")


def _row(ptype, units, country="IE", device="Desktop", title="M1K3", version="1.1.1", apple_id="6780230835"):
    cols = ["APPLE", "US", "app.m1k3", "Round Tower", title, version, ptype, str(units), "0", "10/19/2026",
            "10/19/2026", "EUR", country, "EUR", apple_id, "0", "", "", "", "", "Productivity", "",
            device, "macOS", "", "", "", ""]
    return "\t".join(cols)


def _gz(text):
    return gzip.compress(text.encode())


def test_a_gzipped_sales_report_parses_to_rows():
    rows = metrics.parse_sales(_gz(HEADER + "\n" + _row("1F", 3) + "\n" + _row("7F", 12) + "\n"))
    assert [r["Product Type Identifier"] for r in rows] == ["1F", "7F"]
    assert rows[0]["Units"] == "3"


def test_an_empty_day_is_no_rows_not_an_error():
    # Apple answers 404 "no report for this date" on a day with nothing; the caller maps that to b"".
    assert metrics.parse_sales(b"") == []
    assert metrics.parse_sales(_gz(HEADER + "\n")) == []


def test_product_types_sort_into_downloads_updates_and_other():
    assert metrics.product_class("1F") == "download"   # Mac app
    assert metrics.product_class("1") == "download"    # iPhone
    assert metrics.product_class("1T") == "download"   # iPad
    assert metrics.product_class("F1") == "download"   # Mac, universal purchase
    assert metrics.product_class("7F") == "update"
    assert metrics.product_class("7") == "update"
    assert metrics.product_class("7T") == "update"
    assert metrics.product_class("3F") == "download"   # redownload counts as a download (that user has it)
    assert metrics.product_class("IA1") == "other"     # an in-app purchase, which M1K3 has none of


def test_a_day_summary_totals_units_by_class_and_platform():
    rows = metrics.parse_sales(_gz("\n".join([
        HEADER, _row("1F", 3), _row("1F", 2, country="US"), _row("7F", 12), _row("1", 1, device="iPhone"),
        _row("7", 4, device="iPhone")])))
    day = metrics.summarise(rows)
    assert day["download"] == 6 and day["update"] == 16 and day["other"] == 0
    assert day["by_platform"] == {"Desktop": {"download": 5, "update": 12}, "iPhone": {"download": 1, "update": 4}}
    assert day["by_country"] == {"IE": 4, "US": 2}   # downloads only; updates say nothing about reach


def test_the_report_is_vendor_wide_so_other_apps_rows_are_dropped():
    # The first live run (2026-10-20) counted 6,282 "updates" in 14 days: Round Tower's other apps
    # share the vendor number, and M1K3 iOS is not even on the store yet.
    rows = metrics.parse_sales(_gz("\n".join([
        HEADER, _row("1F", 3), _row("1", 40, device="iPhone", title="Lexy", apple_id="1234567890"),
        _row("7", 900, device="iPhone", title="Lexy", apple_id="1234567890")])))
    day = metrics.summarise(rows, app_id="6780230835")
    assert day["download"] == 3 and day["update"] == 0
    assert "iPhone" not in day["by_platform"]


def test_the_window_is_the_last_n_full_days_apple_can_have():
    # Daily reports land around 05:00 PT for the previous day; "today" is never asked for.
    days = metrics.report_days(dt.date(2026, 10, 20), 3)
    assert days == [dt.date(2026, 10, 17), dt.date(2026, 10, 18), dt.date(2026, 10, 19)]


def test_the_analytics_report_is_picked_by_name_case_insensitively():
    reports = [{"id": "r1", "attributes": {"name": "App Store Discovery and Engagement", "category": "APP_STORE_ENGAGEMENT"}},
               {"id": "r2", "attributes": {"name": "App Downloads", "category": "APP_USAGE"}}]
    assert metrics.pick_report(reports, "app downloads")["id"] == "r2"
    assert metrics.pick_report(reports, "nothing") is None


def test_a_repo_snapshot_line_is_one_dated_json_object():
    line = metrics.snapshot_line(dt.date(2026, 10, 20), {"stars": 5, "forks": 0, "dmg_downloads": 109,
                                                         "views": 131, "views_uniques": 34})
    assert line.startswith('{"date": "2026-10-20"') and line.endswith("\n")
    assert '"dmg_downloads": 109' in line


def test_release_downloads_count_only_dmg_assets_and_name_each_release():
    releases = [{"tag_name": "2026.10.20", "assets": [{"name": "M1K3.dmg", "download_count": 60},
                                                      {"name": "M1K3.dmg.sha256", "download_count": 9}]},
                {"tag_name": "2026.10.19", "assets": [{"name": "M1K3.dmg", "download_count": 49}]}]
    assert metrics.dmg_downloads(releases) == (109, {"2026.10.20": 60, "2026.10.19": 49})


def test_bots_are_called_out_when_clones_dwarf_views():
    assert metrics.clone_note(clones=7202, views=131) == "clones are mostly CI and bots (7,202 clones vs 131 views)"
    assert metrics.clone_note(clones=40, views=131) == ""


# ── pre-push fold (2026-10-20 review) ────────────────────────────────────────

def test_product_types_are_an_explicit_table_not_letter_stripping():
    for odd in ("1E", "FI1", "1-B", "1FT", "T1", "", None):
        assert metrics.product_class(odd) == "other", odd
    assert metrics.product_class(" 1f ") == "download"
    assert metrics.product_class("F7") == "update"
    assert metrics.product_class("3T") == "download"


def test_short_rows_blank_units_and_refunds_do_not_crash():
    short = HEADER + "\n" + "APPLE\tUS\tapp.m1k3\n"              # DictReader fills the rest with None
    assert metrics.summarise(metrics.parse_sales(_gz(short)))["download"] == 0
    rows = metrics.parse_sales(_gz("\n".join([HEADER, _row("1F", ""), _row("1F", -2), _row("1F", 5)])))
    assert metrics.summarise(rows)["download"] == 3


def test_a_report_without_the_app_column_fails_loudly_instead_of_counting_zero():
    import pytest
    with pytest.raises(SystemExit, match="Apple Identifier"):
        metrics.parse_sales(_gz("Provider\tUnits\nAPPLE\t3\n"))


def test_a_non_gzip_body_fails_with_the_body_shown_and_a_bom_is_fine():
    import pytest
    with pytest.raises(SystemExit, match="not gzip"):
        metrics.parse_sales(b'{"errors": [...]}')
    rows = metrics.parse_sales(gzip.compress(("﻿" + HEADER + "\n" + _row("1F", 1)).encode()))
    assert rows[0]["Provider"] == "APPLE"


def test_a_404_day_is_none_which_parses_to_no_rows():
    assert metrics.parse_sales(None) == []


def test_the_window_is_pacific_not_local():
    # 03:00 in Ireland on the 20th is still the 19th in Cupertino: Apple has not landed the 19th yet.
    now = dt.datetime(2026, 10, 20, 3, 0, tzinfo=dt.timezone.utc)
    assert metrics.pacific_today(now) == dt.date(2026, 10, 19)
    assert metrics.report_days(metrics.pacific_today(now), 1) == [dt.date(2026, 10, 18)]
    assert metrics.report_days(dt.date(2026, 10, 20), 0) == []


def test_gh_paginate_output_is_decoded_document_by_document():
    one = metrics.parse_paginated('{"count": 7, "uniques": 3}')
    assert one == {"count": 7, "uniques": 3}
    assert metrics.parse_paginated('[{"a": 1}]') == [{"a": 1}]
    assert metrics.parse_paginated('[{"a": 1}]\n[{"a": 2}]') == [{"a": 1}, {"a": 2}]
    assert metrics.parse_paginated('[{"a": 1}][{"a": 2}]') == [{"a": 1}, {"a": 2}]
    assert metrics.parse_paginated('{"a": 1}{"a": 2}') == [{"a": 1}, {"a": 2}]
    import pytest
    with pytest.raises(SystemExit, match="nothing"):
        metrics.parse_paginated("  \n")


def test_drafts_and_null_counts_are_skipped_in_dmg_downloads():
    releases = [{"tag_name": "draft", "draft": True, "assets": [{"name": "M1K3.dmg", "download_count": 99}]},
                {"tag_name": "2026.10.20", "assets": [{"name": "M1K3.dmg", "download_count": None}]},
                {"tag_name": "2026.10.19", "assets": [{"name": "M1K3.dmg", "download_count": 4}]}]
    assert metrics.dmg_downloads(releases) == (4, {"2026.10.19": 4})


def test_the_snapshot_keeps_one_line_per_date():
    old = '{"date": "2026-10-19", "stars": 4}\n{"date": "2026-10-20", "stars": 5}\n'
    new = metrics.snapshot_line(dt.date(2026, 10, 20), {"stars": 6})
    merged = metrics.merge_snapshot(old, new)
    assert merged == '{"date": "2026-10-19", "stars": 4}\n{"date": "2026-10-20", "stars": 6}\n'
    assert metrics.merge_snapshot("", new) == new


def test_segment_files_are_safe_names_with_an_index_so_they_never_overwrite():
    assert metrics.segment_filename("App Store Discovery and Engagement", "2026-10-19", 0) == \
        "App-Store-Discovery-and-Engagement-2026-10-19-00.csv"
    assert metrics.segment_filename("a/b", "", 3) == "a-b-undated-03.csv"
