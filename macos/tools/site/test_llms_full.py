"""Pins for llms_full.py — the HTML → text rules a citing model depends on."""
from pathlib import Path

import llms_full

PAGE = """<!DOCTYPE html><html><head><title>t</title><script>var x=1;</script></head><body>
<nav><a href="/">Home</a></nav>
<main class="article">
  <header class="article-head"><span class="label">// x</span><h1>Install   M1K3</h1><p class="meta">Updated</p></header>
  <div class="answer"><p><strong>Four steps.</strong> Get the <a href="https://m1k3.app/agents">app</a> &amp; go.</p></div>
  <div class="wiz-doors"><input type="radio"/><label>I'm a person</label></div>
  <h2>Get the app</h2>
  <ul><li>one</li><li>two <code>m1k3</code></li></ul>
  <div class="term"><div class="term-bar"><span></span></div><div class="term-body"><pre><span class="p">$</span> brew trust round-tower/tap
<span class="p">$</span> brew install --cask round-tower/tap/m1k3</pre></div><button class="copy-btn">copy</button></div>
  <table class="cmp"><thead><tr><th>Client</th><th>Does</th></tr></thead><tbody><tr><td>Cursor</td><td class="yes">Edits</td></tr></tbody></table>
  <div class="faq-list"><details><summary>Intel?</summary><p>No. Apple Silicon only.</p></details></div>
  <section class="page-cta"><h2>Own your AI.</h2><p>cta copy</p></section>
  <aside class="more"><a href="/privacy">more</a></aside>
</main>
<footer>© 2026</footer>
</body></html>"""


def test_page_text_keeps_content_and_drops_chrome():
    text = llms_full.page_text(PAGE)
    assert text.startswith("## Install M1K3\n")          # h1 demoted under the file's H1, whitespace collapsed
    assert "### Get the app" in text
    assert "Four steps. Get the app (https://m1k3.app/agents) & go." in text   # link keeps its absolute URL, entity decoded
    assert "- one\n\n- two m1k3" in text
    assert "```\n$ brew trust round-tower/tap\n$ brew install --cask round-tower/tap/m1k3\n```" in text  # pre keeps its lines
    assert "| Client | Does |" in text and "| Cursor | Edits |" in text
    assert "**Q: Intel?**\n\nNo. Apple Silicon only." in text
    for gone in ("Home", "var x=1", "I'm a person", "copy", "Own your AI", "cta copy", "more", "© 2026"):
        assert gone not in text, gone


def test_build_lists_sources_and_includes_install_txt_verbatim(tmp_path: Path):
    (tmp_path / "install.html").write_text(PAGE)
    (tmp_path / "install.txt").write_text("# recipe\nbrew install --cask round-tower/tap/m1k3\n")
    out = llms_full.build(tmp_path)
    assert out.startswith("# M1K3 for Mac — the full text\n")
    assert "## Source: https://m1k3.app/install\n" in out
    assert "## Source: https://m1k3.app/install.txt (verbatim)\n\n```\n# recipe\nbrew install --cask round-tower/tap/m1k3\n```" in out
    assert "## Source: https://m1k3.app/agents" not in out      # missing pages are skipped, not invented


def test_check_mode_flags_a_stale_file(tmp_path: Path, capsys):
    (tmp_path / "install.html").write_text(PAGE)
    assert llms_full.main(["--site-dir", str(tmp_path)]) == 0
    assert llms_full.main(["--site-dir", str(tmp_path), "--check"]) == 0
    (tmp_path / "install.html").write_text(PAGE.replace("Get the app", "Fetch the app"))
    assert llms_full.main(["--site-dir", str(tmp_path), "--check"]) == 1
