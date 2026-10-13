"""CI runs `swift test --disable-xctest` (#596) because the package's tests are
all Swift Testing. A package test that imported XCTest would then never run and
nothing would say so, so this fails first. (UITests/ are Xcode-project targets,
outside the package, and run through their own test plans.)

Signed: Kev + claude-opus-5-5, 2026-10-13, Confidence 0.9. Prior: none (new file).
"""
import pathlib
import re

TESTS = pathlib.Path(__file__).resolve().parents[2] / "Tests"
XCTEST = re.compile(r"^\s*(@testable\s+)?import\s+XCTest\b", re.MULTILINE)


def importers(root: pathlib.Path) -> list[str]:
    return sorted(str(p.relative_to(root)) for p in root.rglob("*.swift")
                  if XCTEST.search(p.read_text(encoding="utf-8")))


def test_no_package_test_imports_xctest():
    assert any(TESTS.rglob("*.swift")), f"no Swift tests under {TESTS}"
    found = importers(TESTS)
    assert not found, f"CI runs swift test --disable-xctest, so these would never run: {found}"


def test_the_scan_catches_an_xctest_import(tmp_path):
    (tmp_path / "A.swift").write_text("import Foundation\n@testable import XCTest\n")
    (tmp_path / "B.swift").write_text("import Testing\n// import XCTest is only a comment here\n")
    assert importers(tmp_path) == ["A.swift"]
