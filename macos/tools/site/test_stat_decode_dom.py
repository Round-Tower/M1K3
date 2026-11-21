"""The homepage stat decode never turns DOM text back into HTML.

CodeQL #57 (js/xss-through-dom): decodeNum's settle() read the stat's `data-num` attribute
(or its textContent) and wrote it back through innerHTML to wrap each 0 in a `.z` span. The
source is author-written today, so nothing was exploitable, but the pattern is one edit away
from an XSS the moment the value comes from anywhere else. settle() now builds the spans with
createElement / createTextNode, and this test keeps it that way.

Signed: Kev + claude-opus-5.5, 2026-11-21, Confidence 0.85. Prior: none (new file).
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[3]
HOME = ROOT / "site/index.html"


def _decode_num_body() -> str:
    text = HOME.read_text(encoding="utf-8")
    start = text.index("function decodeNum(el)")
    # The function ends at the first line that closes it at its own four-space indent.
    end = re.compile(r"^    }\s*$", re.MULTILINE).search(text, start).end()
    return text[start:end]


def _code_only(js: str) -> str:
    return re.sub(r"/\*.*?\*/", "", js, flags=re.DOTALL)


def test_decode_num_never_writes_innerhtml():
    assert "innerHTML" not in _code_only(_decode_num_body())


def test_decode_num_still_wraps_zeros_in_z_spans():
    body = _code_only(_decode_num_body())
    assert "createElement('span')" in body
    assert "className = 'z'" in body
    assert "createTextNode" in body
