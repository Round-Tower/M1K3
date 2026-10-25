"""Unit tests for the pure helpers in check_claims."""

import check_claims as m

# --- added_lines: only what the branch adds, with its new line number ------- #

DIFF = """\
diff --git a/macos/Sources/M1K3Chat/Foo.swift b/macos/Sources/M1K3Chat/Foo.swift
index 1111111..2222222 100644
--- a/macos/Sources/M1K3Chat/Foo.swift
+++ b/macos/Sources/M1K3Chat/Foo.swift
@@ -10,0 +11,2 @@ struct Foo {
+// logs `turn first token:` off the first chunk
+let x = 1
@@ -40 +42 @@ struct Foo {
-// old line
+// new line
diff --git a/macos/docs/evals/run.txt b/macos/docs/evals/run.txt
new file mode 100644
--- /dev/null
+++ b/macos/docs/evals/run.txt
@@ -0,0 +1 @@
+`ghost.py` in an eval artifact
diff --git a/gone.md b/gone.md
deleted file mode 100644
--- a/gone.md
+++ /dev/null
@@ -1 +0,0 @@
-`whatever.py`
"""


def test_added_lines_keeps_new_line_numbers_and_skips_removals_and_deletions():
    got = m.added_lines(DIFF)
    assert got == [
        ("macos/Sources/M1K3Chat/Foo.swift", 11, "// logs `turn first token:` off the first chunk"),
        ("macos/Sources/M1K3Chat/Foo.swift", 12, "let x = 1"),
        ("macos/Sources/M1K3Chat/Foo.swift", 42, "// new line"),
        ("macos/docs/evals/run.txt", 1, "`ghost.py` in an eval artifact"),
    ]


def test_checked_file_skips_eval_artifacts_and_data():
    assert m.checked_file("macos/Sources/M1K3Chat/Foo.swift")
    assert m.checked_file("macos/docs/LONG_CONTEXT_AND_SPEED_DESIGN.md")
    assert m.checked_file("macos/tools/ci/pr_watch.py")
    assert not m.checked_file("macos/docs/evals/2026-10-25-picker-lil-cold.json")
    assert not m.checked_file("macos/docs/evals/notes.md")
    assert not m.checked_file("macos/Resources/knowledge.json")


def test_checked_file_skips_tests_whose_strings_are_fixtures():
    assert not m.checked_file("macos/tools/ci/test_check_claims.py")
    assert not m.checked_file("macos/Tests/M1K3ChatTests/PostToolAnswerTests.swift")
    assert m.checked_file("macos/tools/ci/latest_check.py")


# --- extract_claims: the three shapes, and what is NOT a claim -------------- #

def test_extracts_a_log_marker():
    assert m.extract_claims("logs `turn first token:` off its first chunk") == [
        m.Claim("marker", "turn first token:")
    ]


def test_extracts_paths_with_known_extensions_and_strips_line_suffixes():
    line = "see `tools/ci/pr_watch.py:120`, `TurnPhaseTimeline.swift` and `macos/docs/`"
    assert m.extract_claims(line) == [
        m.Claim("path", "tools/ci/pr_watch.py"),
        m.Claim("path", "TurnPhaseTimeline.swift"),
        m.Claim("path", "macos/docs/"),
    ]


def test_extracts_camelcase_argv_flags_by_name():
    line = "behind `-postToolAnswer use` and `-pickerPrewarm YES`"
    assert m.extract_claims(line) == [
        m.Claim("flag", "postToolAnswer"),
        m.Claim("flag", "pickerPrewarm"),
    ]


def test_ignores_what_is_not_checkable():
    line = (
        "`--no-verify` `-U0` `origin/master` `https://m1k3.app/x.html` `Foo.<T>.swift` "
        "`*.swift` `$HOME/x.py` `gh pr diff` `Signed:` `Review:` `x:` `.synthesise`"
    )
    assert m.extract_claims(line) == []


def test_skip_marker_silences_a_line():
    assert m.extract_claims("replaced `marketing/rank_check.py` (claims: skip)") == []


# --- resolution ------------------------------------------------------------- #

TRACKED = {
    "macos/Sources/M1K3Chat/TurnPhaseTimeline.swift",
    "macos/tools/ci/pr_watch.py",
    "macos/docs/MODULE_MAP.md",
}


def test_path_resolves_exact_suffix_basename_and_directory():
    assert m.path_resolves("macos/tools/ci/pr_watch.py", TRACKED)
    assert m.path_resolves("tools/ci/pr_watch.py", TRACKED)  # relative to macos/
    assert m.path_resolves("TurnPhaseTimeline.swift", TRACKED)  # basename
    assert m.path_resolves("macos/docs/", TRACKED)  # a directory
    assert not m.path_resolves("marketing/rank_check.py", TRACKED)
    assert not m.path_resolves("ci/pr_watch2.py", TRACKED)
    assert not m.path_resolves("i/pr_watch.py", TRACKED)  # suffix must align on a slash


def test_marker_counts_only_inside_a_string_on_a_code_line():
    swift = "macos/Sources/M1K3Chat/TurnPhaseTimeline.swift"
    assert m.marker_in_code(swift, '        var line = "turn first token: \\(ms)ms"', "turn first token:")
    assert m.marker_in_code(swift, 'log("\\(id) turn first token: \\(ms)")', "turn first token:")
    assert not m.marker_in_code(swift, "// logs `turn first token:` off its chunk", "turn first token:")
    assert not m.marker_in_code(swift, "  /// turn first token: is logged", "turn first token:")
    assert not m.marker_in_code("x.py", '    # print("turn first token:")', "turn first token:")
    assert not m.marker_in_code("x.md", 'a "turn first token:" line', "turn first token:")
    assert not m.marker_in_code(swift, "let turnFirstToken = 1", "turn first token:")


def test_flag_counts_only_as_an_exact_string_literal_on_a_code_line():
    swift = "macos/Sources/M1K3Chat/PostToolAnswer.swift"
    assert m.flag_in_code(swift, 'guard let raw = arguments["postToolAnswer"] as? String', "postToolAnswer")
    assert m.flag_in_code(swift, 'public static let key = "-pickerPrewarm"', "pickerPrewarm")
    assert not m.flag_in_code(swift, 'let k = "pickerPrewarmPrefix"', "pickerPrewarm")
    assert not m.flag_in_code(swift, '// set "postToolAnswer" to use', "postToolAnswer")


def test_findings_names_each_unresolved_claim_with_its_location():
    added = [
        ("macos/Sources/A.swift", 3, "// logs `turn first token:` and `ghost marker:`"),
        ("macos/docs/X.md", 9, "see `tools/ci/pr_watch.py` and `marketing/rank_check.py`"),
        ("macos/docs/evals/r.md", 1, "`nowhere.py`"),
    ]
    code_hits = {m.Claim("marker", "turn first token:")}
    got = m.findings(added, TRACKED, lambda c: c in code_hits)
    assert got == [
        ("macos/Sources/A.swift", 3, m.Claim("marker", "ghost marker:")),
        ("macos/docs/X.md", 9, m.Claim("path", "marketing/rank_check.py")),
    ]
