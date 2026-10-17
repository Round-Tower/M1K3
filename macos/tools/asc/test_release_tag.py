"""Pins release_tag.py: the only door into an Xcode Cloud build since 2026-10-17.

Signed: Kev + claude-opus-5-5, 2026-10-17, Confidence 0.85. Prior: none (new file).
"""

from __future__ import annotations

import datetime as dt

import release_tag as rt

PROJECT = """
settings:
  base:
    MARKETING_VERSION: "1.1.0"
    CURRENT_PROJECT_VERSION: "1"
"""


def test_the_tag_names_the_version_day_and_commit():
    sha = "07b1cabe36d1eb79a2ce629743a1e8c79765b398"
    assert rt.tag_name("1.1.0", dt.date(2026, 10, 17), sha) == "release-1.1.0-20261017-07b1cabe"


def test_every_tag_starts_with_the_prefix_xcode_cloud_listens_for():
    assert rt.tag_name("2.0.0", dt.date(2027, 1, 2), "abcdef0123").startswith(rt.PREFIX)
    assert rt.PREFIX == "release"


def test_the_marketing_version_is_read_from_project_yml():
    assert rt.marketing_version(PROJECT) == "1.1.0"
    assert rt.marketing_version("name: M1K3\n") is None


def test_a_green_commit_on_master_with_no_tag_is_cut():
    assert rt.plan(on_master=True, ci="success", existing=[], why=None) == (True, 0, "")


def test_a_commit_off_master_is_refused_whatever_the_reason():
    ok, code, why = rt.plan(on_master=False, ci="success", existing=[], why="hotfix")
    assert (ok, code) == (False, 3)
    assert "master" in why


def test_ci_that_is_not_green_is_refused_unless_a_reason_is_given():
    for ci in ["failure", "in_progress", None]:
        ok, code, _ = rt.plan(on_master=True, ci=ci, existing=[], why=None)
        assert (ok, code) == (False, 4)
    assert rt.plan(on_master=True, ci="failure", existing=[], why="CI flake, rerun green locally")[0]


def test_a_commit_that_already_has_a_release_tag_is_not_tagged_twice():
    ok, code, why = rt.plan(on_master=True, ci="success", existing=["release-1.1.0-20261017-07b1cabe"], why=None)
    assert (ok, code) == (False, 0)
    assert "release-1.1.0-20261017-07b1cabe" in why


LS_REMOTE = """\
1111111111111111111111111111111111111111\trefs/tags/release-1.1.0-20261017-07b1cabe
07b1cabe36d1eb79a2ce629743a1e8c79765b398\trefs/tags/release-1.1.0-20261017-07b1cabe^{}
3dc0d17f00000000000000000000000000000000\trefs/tags/release-lightweight
"""


def test_remote_tags_are_matched_on_the_commit_they_peel_to():
    # An annotated tag's own object id is not the commit: only its ^{} line is.
    assert rt.release_tags_in(LS_REMOTE, "07b1cabe36d1eb79a2ce629743a1e8c79765b398") == [
        "release-1.1.0-20261017-07b1cabe"
    ]
    assert rt.release_tags_in(LS_REMOTE, "1111111111111111111111111111111111111111") == []
    # A lightweight tag has no ^{} line: its id IS the commit.
    assert rt.release_tags_in(LS_REMOTE, "3dc0d17f00000000000000000000000000000000") == ["release-lightweight"]


def test_no_remote_tags_means_none_at_any_commit():
    assert rt.release_tags_in("", "07b1cabe36d1eb79a2ce629743a1e8c79765b398") == []
